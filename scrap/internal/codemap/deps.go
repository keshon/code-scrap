package codemap

import (
	"bytes"
	"cmp"
	"encoding/json"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// Deps is the file dependency graph: who imports whom. Targets are file
// nodes, or directory nodes for languages that import packages (Go).
// Dep is one end of an import relation: the node at the other end, the
// line of the import statement in the importing file, and — when the
// imported name could be traced — the declaration it names.
type Dep struct {
	Node int32 // Out: what is imported · In: who imports
	Line int32 // line of the import statement in the importing file
	Sym  int32 // scope node declaring the imported name, -1 when it has no box
	At   int32 // line of that declaration in the imported file, -1 unknown
}

type Deps struct {
	Out   [][]Dep // by node id: nodes this file imports
	In    [][]Dep // by node id: files importing this node
	Edges int

	Specs      int            // import specifiers seen
	ViaBarrel  int            // edges traced through JS/TS re-exports to the declaring file
	External   int            // bare specifiers of packages outside the repo
	Unresolved map[string]int // repo-looking specifiers that matched nothing (sample)
}

// Import extraction — syntax-level rules per language, run in the fast pass.
var (
	reJSFrom    = regexp.MustCompile(`(?:^|[^\w$.])(?:import|export)\s[^'"` + "`" + `;]*?\bfrom\s*['"]([^'"\n]+)['"]`)
	reJSSide    = regexp.MustCompile(`(?m)^\s*import\s*['"]([^'"\n]+)['"]`)
	reJSCall    = regexp.MustCompile(`\b(?:require|import)\s*\(\s*['"]([^'"\n]+)['"]\s*\)`)
	reGoBlock   = regexp.MustCompile(`(?s)\bimport\s*\((.*?)\)`)
	reGoOne     = regexp.MustCompile(`(?m)^\s*import\s+(?:[\w.]+\s+)?"([^"]+)"`)
	reQuoted    = regexp.MustCompile(`"([^"]+)"`)
	rePyFrom    = regexp.MustCompile(`(?m)^\s*from\s+(\.*[\w.]*)\s+import\b`)
	rePyImport  = regexp.MustCompile(`(?m)^\s*import\s+([\w.]+(?:\s*,\s*[\w.]+)*)`)
	reCInclude  = regexp.MustCompile(`(?m)^\s*#\s*(?:include|import)\s*"([^"]+)"`)
	reGDLoad    = regexp.MustCompile(`\b(?:preload|load)\s*\(\s*"(res://[^"]+)"`)
	reGDExtends = regexp.MustCompile(`(?m)^\s*extends\s+"(res://[^"]+)"`)
	reCSS       = regexp.MustCompile(`@(?:import|use|forward)\s+(?:url\()?['"]([^'"]+)['"]`)
)

// Import is one import specifier and the 0-based line it is written on, so
// a relation can point at the statement rather than at the whole file.
type Import struct {
	Spec string
	Line int32
}

func extractImports(langName string, src []byte) []Import {
	var out []Import
	lines := lineIndex(src)
	// off is where the match starts in src; for matches inside a block the
	// caller passes the block's own offset
	all := func(re *regexp.Regexp, b []byte, off int) {
		for _, m := range re.FindAllSubmatchIndex(b, -1) {
			if m[2] < 0 {
				continue
			}
			out = append(out, Import{string(b[m[2]:m[3]]), lineAt(lines, off+m[2])})
		}
	}
	switch langName {
	case "JavaScript/TypeScript":
		all(reJSFrom, src, 0)
		all(reJSSide, src, 0)
		all(reJSCall, src, 0)
	case "Go":
		for _, blk := range reGoBlock.FindAllSubmatchIndex(src, -1) {
			all(reQuoted, src[blk[2]:blk[3]], blk[2])
		}
		all(reGoOne, src, 0)
	case "Python":
		all(rePyFrom, src, 0)
		for _, m := range rePyImport.FindAllSubmatchIndex(src, -1) {
			line := lineAt(lines, m[2])
			for _, p := range strings.Split(string(src[m[2]:m[3]]), ",") {
				out = append(out, Import{strings.TrimSpace(p), line})
			}
		}
	case "C/C++":
		all(reCInclude, src, 0)
	case "GDScript":
		all(reGDLoad, src, 0)
		all(reGDExtends, src, 0)
	case "CSS":
		all(reCSS, src, 0)
	}
	slices.SortFunc(out, func(a, b Import) int { return cmp.Or(cmp.Compare(a.Spec, b.Spec), cmp.Compare(a.Line, b.Line)) })
	return slices.CompactFunc(out, func(a, b Import) bool { return a.Spec == b.Spec })
}

// lineIndex lists the offset just past each newline, so a byte offset can
// be turned into a line number by binary search.
func lineIndex(src []byte) []int {
	out := []int{0}
	for i, c := range src {
		if c == '\n' {
			out = append(out, i+1)
		}
	}
	return out
}

func lineAt(index []int, off int) int32 {
	i, ok := slices.BinarySearch(index, off)
	if ok {
		return int32(i)
	}
	return int32(max(i-1, 0))
}

// resolver maps import specifiers to map nodes.
type resolver struct {
	m       *Map
	files   map[string]int32 // path → file node
	dirs    map[string]int32 // path → dir node (every prefix of a collapsed chain)
	aliases []alias          // tsconfig/jsconfig paths
	baseURL string           // tsconfig baseUrl, repo-relative ("" = none)
	goMods  []goMod
	godot   []string // directories holding a project.godot

	js     map[int32]*jsModule // by file node
	jsMemo map[jsKey]int32
}

type alias struct {
	pattern string   // "@client/*" or "yougile-model"
	targets []string // repo-relative, may contain one "*"
}

type goMod struct {
	module, dir string
}

var jsExts = []string{".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte", ".json", ".scss", ".css"}

func (m *Map) buildDeps(imports map[int32][]Import, js map[int32]*jsModule) {
	r := &resolver{m: m, files: map[string]int32{}, dirs: map[string]int32{}, js: js, jsMemo: map[jsKey]int32{}}
	for i := range m.Files {
		f := &m.Files[i]
		r.files[f.Path] = f.Node
		switch path.Base(f.Path) {
		case "go.mod":
			r.readGoMod(f)
		case "project.godot":
			r.godot = append(r.godot, path.Dir(f.Path))
		}
	}
	for i := range m.Nodes {
		if m.Nodes[i].Kind == KindDir && i > 0 {
			p := m.Path(int32(i))
			// a collapsed chain "a/b/c" also answers for "a" and "a/b"
			for q := p; q != "." && q != ""; q = path.Dir(q) {
				if _, ok := r.dirs[q]; !ok {
					r.dirs[q] = int32(i)
				}
			}
		}
	}
	r.readTSConfig()

	d := Deps{Out: make([][]Dep, len(m.Nodes)), In: make([][]Dep, len(m.Nodes)), Unresolved: map[string]int{}}
	for from, specs := range imports {
		f := &m.Files[m.Nodes[from].File]
		seen := map[int32]bool{}
		for _, imp := range specs {
			spec := imp.Spec
			d.Specs++
			to := r.resolve(f, spec)
			if to < 0 {
				if r.looksLocal(spec) {
					if len(d.Unresolved) < 200 {
						d.Unresolved[f.Path+" → "+spec]++
					}
				} else {
					d.External++
				}
				continue
			}
			for _, t := range r.jsTargets(from, to, spec) {
				if t == from || seen[t] {
					continue
				}
				seen[t] = true
				sym, at := r.importedSymbol(from, t, spec)
				d.Out[from] = append(d.Out[from], Dep{Node: t, Line: imp.Line, Sym: sym, At: at})
				d.In[t] = append(d.In[t], Dep{Node: from, Line: imp.Line, Sym: sym, At: at})
				d.Edges++
				if t != to {
					d.ViaBarrel++
				}
			}
		}
	}
	m.Deps = &d
}

func (r *resolver) resolve(f *File, spec string) int32 {
	dir := path.Dir(f.Path)
	switch f.Lang.Name {
	case "JavaScript/TypeScript", "CSS":
		if strings.HasPrefix(spec, ".") {
			return r.tryJS(path.Join(dir, spec), f.Lang.Name == "CSS")
		}
		for _, a := range r.aliases {
			if rest, ok := matchAlias(a.pattern, spec); ok {
				for _, t := range a.targets {
					if id := r.tryJS(strings.Replace(t, "*", rest, 1), false); id >= 0 {
						return id
					}
				}
			}
		}
		if r.baseURL != "" {
			return r.tryJS(path.Join(r.baseURL, spec), false)
		}
	case "Go":
		for _, g := range r.goMods {
			if spec == g.module || strings.HasPrefix(spec, g.module+"/") {
				if id, ok := r.dirs[path.Join(g.dir, strings.TrimPrefix(spec, g.module))]; ok {
					return id
				}
			}
		}
	case "Python":
		return r.tryPython(dir, spec)
	case "C/C++":
		for _, p := range []string{path.Join(dir, spec), spec, path.Join("include", spec), path.Join("src", spec)} {
			if id, ok := r.files[p]; ok {
				return id
			}
		}
	case "GDScript":
		rel := strings.TrimPrefix(spec, "res://")
		for _, g := range r.godot {
			if g == "." || strings.HasPrefix(f.Path, g+"/") {
				if id, ok := r.files[path.Join(g, rel)]; ok {
					return id
				}
			}
		}
	}
	return -1
}

// looksLocal tells whether an unresolved specifier was meant to point into
// the repository (relative, aliased, or under baseUrl) rather than at a
// third-party package.
func (r *resolver) looksLocal(spec string) bool {
	if strings.HasPrefix(spec, ".") || strings.HasPrefix(spec, "res://") {
		return true
	}
	for _, a := range r.aliases {
		if _, ok := matchAlias(a.pattern, spec); ok {
			return true
		}
	}
	return false
}

func matchAlias(pattern, spec string) (string, bool) {
	i := strings.IndexByte(pattern, '*')
	if i < 0 {
		return "", pattern == spec
	}
	pre, suf := pattern[:i], pattern[i+1:]
	if len(spec) >= len(pre)+len(suf) && strings.HasPrefix(spec, pre) && strings.HasSuffix(spec, suf) {
		return spec[len(pre) : len(spec)-len(suf)], true
	}
	return "", false
}

// tryJS resolves a path the way bundlers do: exact, + extension, /index.
func (r *resolver) tryJS(p string, scss bool) int32 {
	p = path.Clean(p)
	if id, ok := r.files[p]; ok {
		return id
	}
	for _, e := range jsExts {
		if id, ok := r.files[p+e]; ok {
			return id
		}
	}
	if scss { // Sass partials: _name.scss
		d, b := path.Split(p)
		for _, e := range []string{".scss", ".sass", ""} {
			if id, ok := r.files[d+"_"+b+e]; ok {
				return id
			}
		}
	}
	for _, e := range jsExts {
		if id, ok := r.files[p+"/index"+e]; ok {
			return id
		}
	}
	return -1
}

func (r *resolver) tryPython(dir, spec string) int32 {
	base := ""
	if strings.HasPrefix(spec, ".") {
		base = dir
		for strings.HasPrefix(spec, "..") {
			base = path.Dir(base)
			spec = spec[1:]
		}
		spec = strings.TrimPrefix(spec, ".")
	}
	rel := strings.ReplaceAll(spec, ".", "/")
	roots := []string{base}
	if base == "" {
		roots = []string{"", "src", "lib"}
	}
	for _, root := range roots {
		p := path.Join(root, rel)
		for _, c := range []string{p + ".py", p + "/__init__.py"} {
			if id, ok := r.files[c]; ok {
				return id
			}
		}
		if id, ok := r.dirs[p]; ok && rel != "" {
			return id
		}
	}
	return -1
}

func (r *resolver) readGoMod(f *File) {
	b, err := os.ReadFile(f.Abs)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		if mod, ok := strings.CutPrefix(strings.TrimSpace(line), "module "); ok {
			r.goMods = append(r.goMods, goMod{module: strings.Trim(strings.TrimSpace(mod), `"`), dir: path.Dir(f.Path)})
			return
		}
	}
}

// readTSConfig loads compilerOptions.baseUrl/paths from the root
// tsconfig.json or jsconfig.json, following "extends" chains.
func (r *resolver) readTSConfig() {
	for _, name := range []string{"tsconfig.json", "jsconfig.json"} {
		if _, ok := r.files[name]; ok {
			r.loadTSConfig(filepath.Join(r.m.Root, name), 0)
			return
		}
	}
}

func (r *resolver) loadTSConfig(abs string, depth int) {
	if depth > 5 {
		return
	}
	b, err := os.ReadFile(abs)
	if err != nil {
		return
	}
	var cfg struct {
		Extends         string `json:"extends"`
		CompilerOptions struct {
			BaseURL *string             `json:"baseUrl"`
			Paths   map[string][]string `json:"paths"`
		} `json:"compilerOptions"`
	}
	if json.Unmarshal(jsonc(b), &cfg) != nil {
		return
	}
	// parents first, so this file's settings win
	if strings.HasPrefix(cfg.Extends, ".") {
		ext := filepath.Join(filepath.Dir(abs), filepath.FromSlash(cfg.Extends))
		if filepath.Ext(ext) == "" {
			ext += ".json"
		}
		r.loadTSConfig(ext, depth+1)
	}
	rel, err := filepath.Rel(r.m.Root, filepath.Dir(abs))
	if err != nil {
		return
	}
	cfgDir := filepath.ToSlash(rel)
	base := cfgDir
	if cfg.CompilerOptions.BaseURL != nil {
		base = path.Join(cfgDir, *cfg.CompilerOptions.BaseURL)
		r.baseURL = base
	}
	if len(cfg.CompilerOptions.Paths) > 0 {
		r.aliases = r.aliases[:0]
		for pat, targets := range cfg.CompilerOptions.Paths {
			a := alias{pattern: pat}
			for _, t := range targets {
				a.targets = append(a.targets, path.Join(base, t))
			}
			r.aliases = append(r.aliases, a)
		}
		// longest patterns first, like TypeScript
		slices.SortFunc(r.aliases, func(a, b alias) int { return len(b.pattern) - len(a.pattern) })
	}
}

// jsonc strips // and /* */ comments and trailing commas (tsconfig style).
func jsonc(b []byte) []byte {
	var out bytes.Buffer
	inStr := false
	for i := 0; i < len(b); i++ {
		c := b[i]
		if inStr {
			out.WriteByte(c)
			if c == '\\' && i+1 < len(b) {
				i++
				out.WriteByte(b[i])
			} else if c == '"' {
				inStr = false
			}
			continue
		}
		switch {
		case c == '"':
			inStr = true
			out.WriteByte(c)
		case c == '/' && i+1 < len(b) && b[i+1] == '/':
			for i < len(b) && b[i] != '\n' {
				i++
			}
			out.WriteByte('\n')
		case c == '/' && i+1 < len(b) && b[i+1] == '*':
			i += 2
			for i+1 < len(b) && !(b[i] == '*' && b[i+1] == '/') {
				i++
			}
			i++
		case c == ',':
			// drop a comma followed only by whitespace and a closing bracket
			j := i + 1
			for j < len(b) && (b[j] == ' ' || b[j] == '\t' || b[j] == '\n' || b[j] == '\r') {
				j++
			}
			if j < len(b) && (b[j] == '}' || b[j] == ']') {
				continue
			}
			out.WriteByte(c)
		default:
			out.WriteByte(c)
		}
	}
	return out.Bytes()
}

// Edge is one dependency: From imports To.
// Edge is one relation between two boxes, with where to aim it: the line
// in the From file it comes from (-1 unknown) and the declaration it lands
// on at the To end (-1 unknown, aim at the whole box).
type Edge struct {
	From, To int32
	FromLine int32 // where it starts in the From file (-1 = the whole box)
	ToSym    int32 // the declaration it lands on, when that has a box of its own
	ToLine   int32 // …else its line in the To file (-1 = the whole box)
}

// DepsOf returns the edges crossing the boundary of a node's subtree:
// out = files inside importing nodes outside; in = files outside importing
// nodes inside. Each list is capped at limit (totals are exact).
func (m *Map) DepsOf(id int32, limit int) (out, in []Edge, outTotal, inTotal int) {
	if m.Deps == nil || id < 0 || int(id) >= len(m.Nodes) {
		return
	}
	lo, hi := id, m.Nodes[id].End
	inside := func(n int32) bool { return n >= lo && n < hi }
	for n := lo; n < hi; n++ {
		for _, dep := range m.Deps.Out[n] {
			if !inside(dep.Node) {
				outTotal++
				if len(out) < limit {
					out = append(out, Edge{From: n, To: dep.Node, FromLine: dep.Line, ToSym: dep.Sym, ToLine: dep.At})
				}
			}
		}
		for _, dep := range m.Deps.In[n] {
			if !inside(dep.Node) {
				inTotal++
				if len(in) < limit {
					in = append(in, Edge{From: dep.Node, To: n, FromLine: dep.Line, ToSym: dep.Sym, ToLine: dep.At})
				}
			}
		}
	}
	return
}
