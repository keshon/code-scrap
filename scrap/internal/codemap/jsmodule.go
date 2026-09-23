package codemap

import (
	"regexp"
	"slices"
	"strings"
)

// JS/TS barrels ("index.ts" files that only re-export) sit between most
// importers and the modules they really use. jsModule keeps enough of a
// file's import/export surface to follow a name through re-exports to the
// file that declares it.
type jsModule struct {
	Uses      map[string][]string // specifier → names imported from it ("*" = the whole module)
	Exports   []string            // names declared and exported here ("default" included)
	ReExports []jsReExport
}

// jsReExport is `export {Name as As} from Spec`; `export * from Spec` has
// Name "*" and no As, `export * as ns from Spec` has Name "*" and As ns.
type jsReExport struct{ Spec, Name, As string }

var (
	reJSImportClause = regexp.MustCompile(`(?:^|[^\w$.])import\s+(?:type\s+)?([^'"` + "`" + `;]*?)\s*\bfrom\s*['"]([^'"\n]+)['"]`)
	reJSExportFrom   = regexp.MustCompile(`(?:^|[^\w$.])export\s+(?:type\s+)?(\*(?:\s+as\s+([\w$]+))?|\{[^}]*\})\s*from\s*['"]([^'"\n]+)['"]`)
	reJSExportDecl   = regexp.MustCompile(`(?m)^[ \t]*export\s+(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(?:function\s*\*?|class|const|let|var|interface|type|enum|namespace|module)\s+([\w$]+)`)
	reJSExportDflt   = regexp.MustCompile(`(?m)^[ \t]*export\s+default\b`)
	reJSExportList   = regexp.MustCompile(`(?:^|[^\w$.])export\s+(?:type\s+)?\{([^}]*)\}(\s*from)?`)
	reJSNamespace    = regexp.MustCompile(`\*\s*as\s+([\w$]+)`)
)

// parseJSModule reads a JS/TS file's imports and exports at syntax level.
func parseJSModule(src []byte) *jsModule {
	js := &jsModule{Uses: map[string][]string{}}
	use := func(spec string, names ...string) {
		js.Uses[spec] = append(js.Uses[spec], names...)
	}
	for _, m := range reJSImportClause.FindAllSubmatch(src, -1) {
		clause, spec := string(m[1]), string(m[2])
		if i := strings.IndexByte(clause, '{'); i >= 0 {
			if j := strings.IndexByte(clause[i:], '}'); j >= 0 {
				for _, b := range splitBindings(clause[i+1 : i+j]) {
					use(spec, b[0])
				}
				clause = clause[:i] + clause[i+j+1:]
			}
		}
		if ns := reJSNamespace.FindStringSubmatch(clause); ns != nil {
			// import * as ns: the names are whatever ns.X the file uses
			re := regexp.MustCompile(`(?:^|[^\w$.])` + regexp.QuoteMeta(ns[1]) + `\.([\w$]+)`)
			found := false
			for _, u := range re.FindAllSubmatch(src, -1) {
				use(spec, string(u[1]))
				found = true
			}
			if !found {
				use(spec, "*")
			}
			clause = strings.Replace(clause, ns[0], "", 1)
		}
		if d := strings.Trim(strings.TrimSpace(clause), ","); strings.TrimSpace(d) != "" {
			use(spec, "default")
		}
	}
	for _, m := range reJSExportFrom.FindAllSubmatch(src, -1) {
		what, as, spec := string(m[1]), string(m[2]), string(m[3])
		if strings.HasPrefix(what, "*") {
			js.ReExports = append(js.ReExports, jsReExport{Spec: spec, Name: "*", As: as})
			use(spec, "*")
			continue
		}
		for _, b := range splitBindings(what[1 : len(what)-1]) {
			js.ReExports = append(js.ReExports, jsReExport{Spec: spec, Name: b[0], As: b[1]})
			use(spec, b[0])
		}
	}
	// side-effect imports, require() and import(): the whole module
	for _, re := range []*regexp.Regexp{reJSSide, reJSCall} {
		for _, m := range re.FindAllSubmatch(src, -1) {
			use(string(m[1]), "*")
		}
	}
	for spec, names := range js.Uses {
		slices.Sort(names)
		js.Uses[spec] = slices.Compact(names)
	}

	for _, m := range reJSExportDecl.FindAllSubmatch(src, -1) {
		js.Exports = append(js.Exports, string(m[1]))
	}
	if reJSExportDflt.Match(src) {
		js.Exports = append(js.Exports, "default")
	}
	for _, m := range reJSExportList.FindAllSubmatch(src, -1) {
		if len(m[2]) == 0 { // `export {a, b as c}` of local names
			for _, b := range splitBindings(string(m[1])) {
				js.Exports = append(js.Exports, b[1])
			}
		}
	}
	slices.Sort(js.Exports)
	js.Exports = slices.Compact(js.Exports)
	return js
}

// splitBindings parses "a, type b, c as d" into {name, alias} pairs; the
// alias is the name when there is none.
func splitBindings(list string) [][2]string {
	var out [][2]string
	for _, part := range strings.Split(list, ",") {
		f := strings.Fields(part)
		if len(f) > 0 && f[0] == "type" && len(f) != 1 && !(len(f) == 3 && f[1] == "as") {
			f = f[1:]
		}
		switch {
		case len(f) == 1:
			out = append(out, [2]string{f[0], f[0]})
		case len(f) == 3 && f[1] == "as":
			out = append(out, [2]string{f[0], f[2]})
		}
	}
	return out
}

// exportOf follows name through re-exports from file node id to the file
// node declaring it, or -1 when it can't be traced.
func (r *resolver) exportOf(id int32, name string) int32 {
	key := jsKey{id, name}
	if t, ok := r.jsMemo[key]; ok {
		if t == jsVisiting {
			return -1 // re-export cycle
		}
		return t
	}
	r.jsMemo[key] = jsVisiting
	t := r.traceExport(id, name)
	r.jsMemo[key] = t
	return t
}

type jsKey struct {
	file int32
	name string
}

const jsVisiting = -2

func (r *resolver) traceExport(id int32, name string) int32 {
	js := r.js[id]
	if js == nil {
		return -1
	}
	if _, ok := slices.BinarySearch(js.Exports, name); ok {
		return id
	}
	f := &r.m.Files[r.m.Nodes[id].File]
	for _, re := range js.ReExports {
		if re.As != name || re.As == "" {
			continue
		}
		t := r.resolve(f, re.Spec)
		if t < 0 || re.Name == "*" { // export * as ns: the module itself
			return t
		}
		if d := r.exportOf(t, re.Name); d >= 0 {
			return d
		}
		return t
	}
	for _, re := range js.ReExports {
		if re.Name == "*" && re.As == "" {
			if t := r.resolve(f, re.Spec); t >= 0 {
				if d := r.exportOf(t, name); d >= 0 {
					return d
				}
			}
		}
	}
	return -1
}

// importedSymbol is the declaration an import names in the file it lands
// in: `import {Hub} from "yougile-model"` points at Hub itself rather than
// at the whole file. -1 when the language, the specifier or the name give
// no single answer.
func (r *resolver) importedSymbol(from, to int32, spec string) (node, line int32) {
	js := r.js[from]
	if js == nil {
		return -1, -1
	}
	node, line = -1, -1
	for _, name := range js.Uses[spec] {
		if name == "*" || name == "default" {
			continue
		}
		n, l := r.m.symbolIn(to, name)
		if l < 0 {
			continue
		}
		if line >= 0 {
			return -1, -1 // several names: the file itself is the honest answer
		}
		node, line = n, l
	}
	return node, line
}

// symbolIn finds where name is declared inside a file node: its scope node
// (-1 when the declaration has no box of its own) and its line (-1 = the
// file does not declare it).
func (m *Map) symbolIn(file int32, name string) (node, line int32) {
	lower := strings.ToLower(name)
	i, _ := slices.BinarySearchFunc(m.Symbols, lower, func(s Symbol, t string) int {
		return strings.Compare(s.Lower, t)
	})
	for ; i < len(m.Symbols) && m.Symbols[i].Lower == lower; i++ {
		s := &m.Symbols[i]
		if s.Name != name || m.Files[s.File].Node != file {
			continue
		}
		if m.Nodes[s.Node].Kind == KindScope {
			return s.Node, s.Line
		}
		return -1, s.Line
	}
	return -1, -1
}

// jsTargets resolves what file node from imports from target node to: the
// files declaring the names it uses when target re-exports them, else the
// target itself.
func (r *resolver) jsTargets(from, to int32, spec string) []int32 {
	js, tjs := r.js[from], r.js[to]
	if js == nil || tjs == nil || len(tjs.ReExports) == 0 {
		return []int32{to}
	}
	var out []int32
	for _, name := range js.Uses[spec] {
		t := int32(-1)
		if name != "*" {
			t = r.exportOf(to, name)
		}
		if t < 0 {
			t = to
		}
		if !slices.Contains(out, t) {
			out = append(out, t)
		}
	}
	if len(out) == 0 {
		out = append(out, to)
	}
	return out
}
