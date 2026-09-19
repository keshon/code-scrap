package codemap

import (
	"bytes"
	"cmp"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	ignore "github.com/sabhiram/go-gitignore"

	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// Progress receives indexing progress. It may be called from many goroutines.
type Progress func(phase string, done, total int)

// Options control what gets indexed and how.
type Options struct {
	SortByName bool    // stable alphabetical placement instead of largest-first
	Precise    bool    // run the tree-sitter pass (slower, exact scopes)
	NoGit      bool    // ignore git and walk the file system
	CharAspect float64 // glyph width / line height of the text font (0 = default)
	Progress   Progress
}

// Directories never worth mapping when walking without git.
var skipDirs = map[string]bool{
	".git": true, ".hg": true, ".svn": true, ".godot": true, ".import": true, ".scrap": true,
	"node_modules": true, "__pycache__": true, ".idea": true, ".vs": true, ".vscode": true,
	".cache": true, ".gradle": true, ".next": true, ".nuxt": true,
}

// Files above this size are mapped by size only (no text, no scopes).
const maxTextBytes = 64 << 20

// Average line length above which a file is treated as minified/generated.
const minifiedLineLen = 300

type tnode struct {
	name     string
	children map[string]*tnode
	file     int // index into raw files; -1 for dirs
	weight   float64
}

func (t *tnode) isDir() bool { return t.file < 0 }

type rawFile struct {
	path    string
	abs     string
	lang    *syntax.Lang
	class   FileClass
	size    int64
	lines   int32
	precise bool
	scopes  []syntax.Scope
	decls   []syntax.Decl
	imports []string
	calls   [][]string // per scope: distinct callee names inside it
}

// Build indexes the tree at root and lays it out.
func Build(root string, opt Options) (*Map, error) {
	t0 := time.Now()
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(abs); err != nil {
		return nil, err
	}
	progress := opt.Progress
	if progress == nil {
		progress = func(string, int, int) {}
	}

	var paths []string
	if !opt.NoGit {
		paths = gitFiles(abs)
	}
	if paths == nil {
		paths = walkFiles(abs, progress)
	}
	slices.Sort(paths)
	progress("walk", len(paths), len(paths))

	files := make([]rawFile, len(paths))
	for i, p := range paths {
		files[i] = rawFile{path: p, abs: filepath.Join(abs, filepath.FromSlash(p)), lang: syntax.For(path.Base(p))}
	}

	// read + tokenize + find scopes in parallel, largest files first so
	// the slow tail starts early
	order := make([]int, len(files))
	for i := range order {
		order[i] = i
	}
	sizes := make([]int64, len(files))
	for i := range files {
		if st, err := os.Stat(files[i].abs); err == nil && st.Mode().IsRegular() {
			sizes[i] = st.Size()
		} else {
			sizes[i] = -1
		}
	}
	slices.SortFunc(order, func(a, b int) int { return cmp.Compare(sizes[b], sizes[a]) })

	var done atomic.Int64
	jobs := make(chan int, 256)
	var wg sync.WaitGroup
	for w := 0; w < runtime.NumCPU(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				files[i].size = sizes[i]
				analyze(&files[i], opt.Precise)
				if d := done.Add(1); d%500 == 0 {
					progress("parse", int(d), len(files))
				}
			}
		}()
	}
	for _, i := range order {
		if sizes[i] >= 0 {
			jobs <- i
		}
	}
	close(jobs)
	wg.Wait()
	progress("parse", len(files), len(files))

	top := &tnode{name: filepath.Base(abs), file: -1}
	for i := range files {
		if sizes[i] < 0 {
			continue
		}
		top.insert(strings.Split(files[i].path, "/"), i)
	}

	m := assemble(abs, top, files, opt)
	imports := map[int32][]string{}
	for i := range m.Files {
		f := &m.Files[i]
		if spec := files[f.raw].imports; len(spec) > 0 {
			imports[f.Node] = spec
		}
	}
	m.buildDeps(imports)
	m.Stats.Imports = m.Deps.Edges
	m.sortByName = opt.SortByName
	m.charAspect = opt.CharAspect
	if m.charAspect <= 0 {
		m.charAspect = DefaultCharAspect
	}
	m.Stats.IndexMs = time.Since(t0).Milliseconds()
	t1 := time.Now()
	m.layout()
	m.heat()
	m.Stats.LayoutMs = time.Since(t1).Milliseconds()
	return m, nil
}

func (t *tnode) insert(parts []string, file int) {
	if t.children == nil {
		t.children = map[string]*tnode{}
	}
	if len(parts) == 1 {
		t.children[parts[0]] = &tnode{name: parts[0], file: file}
		return
	}
	c := t.children[parts[0]]
	if c == nil {
		c = &tnode{name: parts[0], file: -1}
		t.children[parts[0]] = c
	}
	c.insert(parts[1:], file)
}

// gitFiles lists tracked and untracked-but-not-ignored files. It returns nil
// when root is not inside a git work tree.
func gitFiles(root string) []string {
	cmd := exec.Command("git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	var paths []string
	seen := map[string]bool{}
	for _, p := range bytes.Split(out, []byte{0}) {
		if len(p) == 0 {
			continue
		}
		s := string(p)
		if !seen[s] { // deleted-but-tracked files may repeat; dedupe
			seen[s] = true
			paths = append(paths, s)
		}
	}
	if paths == nil {
		paths = []string{}
	}
	return paths
}

type ignoreLayer struct {
	base string // repo-relative dir holding the .gitignore
	gi   *ignore.GitIgnore
}

func walkFiles(root string, progress Progress) []string {
	var out []string
	var walk func(rel string, layers []ignoreLayer)
	walk = func(rel string, layers []ignoreLayer) {
		full := filepath.Join(root, filepath.FromSlash(rel))
		if gi, err := ignore.CompileIgnoreFile(filepath.Join(full, ".gitignore")); err == nil {
			layers = append(layers[:len(layers):len(layers)], ignoreLayer{rel, gi})
		}
		entries, err := os.ReadDir(full)
		if err != nil {
			return
		}
		for _, e := range entries {
			name := e.Name()
			childRel := path.Join(rel, name)
			if e.IsDir() {
				if !skipDirs[name] && !ignored(layers, childRel, true) {
					walk(childRel, layers)
				}
				continue
			}
			if e.Type().IsRegular() && !ignored(layers, childRel, false) {
				out = append(out, childRel)
				if len(out)%2000 == 0 {
					progress("walk", len(out), 0)
				}
			}
		}
	}
	walk("", nil)
	return out
}

func ignored(layers []ignoreLayer, rel string, dir bool) bool {
	for _, l := range layers {
		p := rel
		if l.base != "" {
			p = strings.TrimPrefix(rel, l.base+"/")
		}
		if dir {
			p += "/"
		}
		if l.gi.MatchesPath(p) {
			return true
		}
	}
	return false
}

func analyze(f *rawFile, precise bool) {
	f.class = Classify(f.path, f.lang)
	if f.class&(ClassSecret|ClassAsset) != 0 || f.size > maxTextBytes {
		f.class |= ClassBinary
		return
	}
	src, err := os.ReadFile(f.abs)
	if err != nil {
		f.class |= ClassBinary
		return
	}
	if bytes.IndexByte(src[:min(len(src), 8000)], 0) >= 0 {
		f.class |= ClassBinary
		return
	}
	lines := syntax.SplitLines(src)
	f.lines = int32(len(lines))
	if len(lines) > 0 && len(src)/len(lines) > minifiedLineLen {
		f.class |= ClassMinified
	}
	if f.lang.Data || f.class.Has(ClassMinified) {
		return
	}
	f.imports = extractImports(f.lang.Name, src)
	var scan syntax.Scan
	syntax.Tokenize(lines, f.lang, false, &scan)
	f.scopes, f.decls = syntax.FindScopes(lines, f.lang, &scan)
	defer func() { f.calls = callsPerScope(f.scopes, scan.Calls) }()
	if precise {
		// Tree-sitter spans are exact, but tags queries skip some definition
		// shapes (e.g. `const Foo = () => …`), so keep the heuristic's
		// declarations that the precise outline didn't name.
		if s, d, ok := syntax.PreciseScopes(f.path, src, lines, &scan); ok {
			f.decls = mergeDecls(d, s, f.decls)
			f.scopes, f.precise = s, true
		}
	}
}

// callsPerScope gives each scope the distinct names called directly inside
// it (not in nested scopes), dropping the scope's own definition line.
func callsPerScope(scopes []syntax.Scope, calls []syntax.Call) [][]string {
	if len(scopes) == 0 || len(calls) == 0 {
		return nil
	}
	out := make([][]string, len(scopes))
	seen := make([]map[string]bool, len(scopes))
	for _, c := range calls {
		best := -1
		for i := range scopes {
			s := &scopes[i]
			if c.Line >= s.Start && c.Line <= s.End && (best < 0 || s.Depth > scopes[best].Depth) {
				best = i
			}
		}
		if best < 0 || (c.Line == scopes[best].Start && c.Name == scopes[best].Name) {
			continue
		}
		if seen[best] == nil {
			seen[best] = map[string]bool{}
		}
		if !seen[best][c.Name] {
			seen[best][c.Name] = true
			out[best] = append(out[best], strings.Clone(c.Name)) // don't pin the file's text
		}
	}
	return out
}

func mergeDecls(precise []syntax.Decl, scopes []syntax.Scope, heuristic []syntax.Decl) []syntax.Decl {
	type key struct {
		name string
		line int32
	}
	seen := map[key]bool{}
	for _, d := range precise {
		seen[key{d.Name, d.Line}] = true
	}
	for _, s := range scopes {
		seen[key{s.Name, s.Start}] = true
	}
	for _, d := range heuristic {
		if !seen[key{d.Name, d.Line}] {
			precise = append(precise, d)
		}
	}
	return precise
}

// fileWeight is the area budget of a file in line-equivalents.
func fileWeight(f *rawFile) float64 {
	if f.class&ClassBinary != 0 {
		return min(max(float64(f.size)/2048, 1), 200)
	}
	return max(float64(f.lines), float64(f.size)/80, 1)
}

func computeWeights(n *tnode, files []rawFile) float64 {
	if !n.isDir() {
		n.weight = fileWeight(&files[n.file])
		return n.weight
	}
	n.weight = 0
	for _, c := range n.children {
		n.weight += computeWeights(c, files)
	}
	return n.weight
}

// collapse merges chains of single-child directories: a/b/c → "a/b/c".
func collapse(n *tnode, isRoot bool) {
	for !isRoot && n.isDir() && len(n.children) == 1 {
		var c *tnode
		for _, v := range n.children {
			c = v
		}
		if !c.isDir() {
			break
		}
		n.name += "/" + c.name
		n.children = c.children
	}
	for _, c := range n.children {
		collapse(c, false)
	}
}

func assemble(abs string, top *tnode, raw []rawFile, opt Options) *Map {
	computeWeights(top, raw)
	collapse(top, true)
	m := &Map{Root: abs, Callers: map[string][]int32{}}
	m.Files = make([]File, 0, len(raw))

	var add func(t *tnode, parent int32, depth uint8) int32
	add = func(t *tnode, parent int32, depth uint8) int32 {
		id := int32(len(m.Nodes))
		m.Nodes = append(m.Nodes, Node{Name: t.name, Parent: parent, Depth: depth, File: -1, Weight: t.weight, BaseWeight: t.weight})
		if !t.isDir() {
			rf := &raw[t.file]
			fi := int32(len(m.Files))
			m.Files = append(m.Files, File{
				Node: id, Path: rf.path, Abs: rf.abs, Lang: rf.lang, Class: rf.class,
				Lines: rf.lines, Bytes: rf.size, Precise: rf.precise, raw: int32(t.file),
			})
			n := &m.Nodes[id]
			n.Kind, n.File, n.Lines, n.Bytes = KindFile, fi, int64(rf.lines), rf.size
			m.Stats.Files++
			m.Stats.Lines += int64(rf.lines)
			m.Stats.Bytes += rf.size
			if rf.precise {
				m.Stats.PreciseFiles++
			}
			m.addScopes(id, fi, rf, depth)
			m.Nodes[id].End = int32(len(m.Nodes))
			return id
		}
		m.Stats.Dirs++
		kids := make([]*tnode, 0, len(t.children))
		for _, c := range t.children {
			kids = append(kids, c)
		}
		if opt.SortByName {
			slices.SortFunc(kids, func(a, b *tnode) int { return cmp.Compare(a.name, b.name) })
		} else {
			slices.SortFunc(kids, func(a, b *tnode) int {
				if c := cmp.Compare(b.weight, a.weight); c != 0 {
					return c
				}
				return cmp.Compare(a.name, b.name)
			})
		}
		ch := make([]int32, 0, len(kids))
		var lines, size int64
		for _, k := range kids {
			cid := add(k, id, depth+1)
			ch = append(ch, cid)
			lines += m.Nodes[cid].Lines
			size += m.Nodes[cid].Bytes
		}
		n := &m.Nodes[id]
		n.Children, n.Lines, n.Bytes = ch, lines, size
		n.End = int32(len(m.Nodes))
		return id
	}
	add(top, -1, 0)
	m.assignHues()
	slices.SortFunc(m.Symbols, func(a, b Symbol) int {
		if c := cmp.Compare(a.Lower, b.Lower); c != 0 {
			return c
		}
		if c := cmp.Compare(m.Files[a.File].Path, m.Files[b.File].Path); c != 0 {
			return c
		}
		return cmp.Compare(a.Line, b.Line)
	})
	m.Stats.Symbols = len(m.Symbols)
	return m
}

// addScopes appends scope nodes (pre-order, nested by depth) under a file node.
func (m *Map) addScopes(fileNode, fi int32, rf *rawFile, depth uint8) {
	var stack []int32 // open scope per depth
	for si, s := range rf.scopes {
		for len(stack) > s.Depth {
			m.Nodes[stack[len(stack)-1]].End = int32(len(m.Nodes))
			stack = stack[:len(stack)-1]
		}
		parent := fileNode
		if len(stack) > 0 {
			parent = stack[len(stack)-1]
		}
		id := int32(len(m.Nodes))
		m.Nodes = append(m.Nodes, Node{
			Name: s.Name, Kind: KindScope, Scope: s.Kind, Parent: parent, File: fi,
			Depth: depth + 1 + uint8(len(stack)), StartLine: s.Start, EndLine: s.End,
			Lines: int64(s.End - s.Start + 1), Complexity: s.Complexity, Params: s.Params, MaxNesting: s.MaxNesting,
		})
		m.Nodes[parent].Children = append(m.Nodes[parent].Children, id)
		m.Files[fi].Scopes = append(m.Files[fi].Scopes, id)
		if si < len(rf.calls) {
			m.Nodes[id].Calls = rf.calls[si]
			for _, c := range rf.calls[si] {
				m.Callers[c] = append(m.Callers[c], id)
			}
		}
		m.Symbols = append(m.Symbols, Symbol{strings.ToLower(s.Name), s.Name, id, fi, s.Start, s.Kind})
		m.Stats.Scopes++
		m.Files[fi].MaxComplexity = max(m.Files[fi].MaxComplexity, s.Complexity)
		stack = append(stack, id)
	}
	for _, id := range stack {
		m.Nodes[id].End = int32(len(m.Nodes))
	}
	for _, d := range rf.decls {
		m.Symbols = append(m.Symbols, Symbol{strings.ToLower(d.Name), d.Name, fileNode, fi, d.Line, d.Kind})
	}
}

// HueNeutral marks nodes above the hue-assignment level.
const HueNeutral = 255

// assignHues gives each top-level area its own palette slot. With fewer than
// four top-level entries, areas are taken one level deeper so small repos
// still get color variety.
func (m *Map) assignHues() {
	level := uint8(1)
	if len(m.Nodes[0].Children) < 4 {
		level = 2
	}
	next := uint8(0)
	for i := range m.Nodes {
		n := &m.Nodes[i]
		switch {
		case n.Depth < level:
			n.Hue = HueNeutral
		case n.Depth == level:
			n.Hue = next
			next = (next + 1) % 16
		default:
			n.Hue = m.Nodes[n.Parent].Hue
		}
	}
}
