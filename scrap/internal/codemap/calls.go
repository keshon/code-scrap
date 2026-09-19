package codemap

import (
	"sort"
	"strings"
)

// Call resolution is syntax-level: a call "foo(" matches a definition named
// foo in the same file, else in a file the caller imports, else the only
// definition of that name anywhere. Anything more ambiguous is dropped
// rather than guessed.

// defsNamed returns the scope nodes defining exactly name.
func (m *Map) defsNamed(name string) []int32 {
	lower := strings.ToLower(name)
	i := sort.Search(len(m.Symbols), func(i int) bool { return m.Symbols[i].Lower >= lower })
	var out []int32
	for ; i < len(m.Symbols) && m.Symbols[i].Lower == lower; i++ {
		s := &m.Symbols[i]
		if s.Name == name && m.Nodes[s.Node].Kind == KindScope {
			out = append(out, s.Node)
		}
	}
	return out
}

// imports tells whether file node f imports node g's file (or its package
// directory, for languages that import directories).
func (m *Map) imports(f, g int32) bool {
	if m.Deps == nil {
		return false
	}
	gf := m.Files[m.Nodes[g].File].Node
	for _, t := range m.Deps.Out[f] {
		if t == gf || (m.Nodes[t].Kind == KindDir && gf > t && gf < m.Nodes[t].End) {
			return true
		}
	}
	return false
}

func (m *Map) fileOf(n int32) int32 { return m.Files[m.Nodes[n].File].Node }

// resolveCall picks the definition a call from scope `from` most likely
// means, or -1.
func (m *Map) resolveCall(from int32, name string) int32 {
	defs := m.defsNamed(name)
	if len(defs) == 0 {
		return -1
	}
	ff := m.fileOf(from)
	for _, d := range defs {
		if m.fileOf(d) == ff && d != from {
			return d
		}
	}
	var imported []int32
	for _, d := range defs {
		if m.imports(ff, d) {
			imported = append(imported, d)
		}
	}
	if len(imported) == 1 {
		return imported[0]
	}
	if len(defs) == 1 && defs[0] != from {
		return defs[0]
	}
	return -1
}

// CallsOf returns resolved call edges for a function scope, or for every
// scope of a file: out = what they call, in = who calls them. Edges inside
// the selection are skipped. Lists are capped at limit (totals are exact).
func (m *Map) CallsOf(id int32, limit int) (out, in []Edge, outTotal, inTotal int) {
	if id < 0 || int(id) >= len(m.Nodes) {
		return
	}
	var sources []int32
	switch n := &m.Nodes[id]; n.Kind {
	case KindScope:
		for s := id; s < n.End; s++ {
			sources = append(sources, s)
		}
	case KindFile:
		sources = m.Files[n.File].Scopes
	default:
		return // directories: too broad to be useful as a call graph
	}
	lo, hi := id, m.Nodes[id].End
	inside := func(n int32) bool { return n >= lo && n < hi }
	for _, s := range sources {
		for _, name := range m.Nodes[s].Calls {
			if t := m.resolveCall(s, name); t >= 0 && !inside(t) {
				outTotal++
				if len(out) < limit {
					out = append(out, Edge{s, t})
				}
			}
		}
		// callers: every scope calling this name that resolves back to s
		for _, c := range m.Callers[m.Nodes[s].Name] {
			if !inside(c) && m.resolveCall(c, m.Nodes[s].Name) == s {
				inTotal++
				if len(in) < limit {
					in = append(in, Edge{c, s})
				}
			}
		}
	}
	return
}
