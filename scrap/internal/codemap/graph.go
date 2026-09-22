package codemap

import (
	"cmp"
	"slices"
)

// Graph is the file-level relation graph of a map, for analysis outside
// the viewer (clustering, layering). Nodes are text files; edges carry
// their kind and a weight.
type Graph struct {
	Root  string       `json:"root"`
	Nodes []GraphNode  `json:"nodes"`
	Edges []GraphEdge  `json:"edges"`
	Stats GraphStats   `json:"stats"`
	Opts  GraphOptions `json:"options"`

	nodeOf map[int32]int32 // file index → graph node
}

type GraphNode struct {
	ID      int32    `json:"id"` // index in Graph.Nodes
	Path    string   `json:"path"`
	Lang    string   `json:"lang,omitempty"`
	Lines   int32    `json:"lines"`
	Class   []string `json:"class,omitempty"` // test, data, vendored, minified
	Commits int32    `json:"commits"`         // commits in the window touching the file
	Decls   []string `json:"decls,omitempty"` // top-level scope names, capped

	file int32 // index in Map.Files
}

// GraphEdge is directed for imports and calls (S uses T) and undirected for
// co-change (S < T).
type GraphEdge struct {
	S    int32   `json:"s"`
	T    int32   `json:"t"`
	Kind string  `json:"k"` // import, call, cochange
	W    float64 `json:"w"` // import: 1 (a package import splits 1 over its files); call: resolved calls; cochange: Σ 1/(n-1) over shared commits of n files
	N    int32   `json:"n"` // import: 1; call: resolved calls; cochange: shared commits
}

type GraphStats struct {
	Imports, Calls, CoChanges int
	Commits                   int // commits read
	CommitsUsed               int // touched 2..MaxFiles graph files
	CommitsTooLarge           int // touched more than MaxFiles graph files (mass edits)
}

type GraphOptions struct {
	Since     string `json:"since"`     // git history window, for the record
	MaxFiles  int    `json:"maxFiles"`  // commits touching more graph files are skipped
	MinShared int    `json:"minShared"` // co-change pairs need this many shared commits
	MaxDecls  int    `json:"maxDecls"`  // top-level names kept per file
}

// graphClasses names the flags a graph node reports.
var graphClasses = []struct {
	name  string
	class FileClass
}{{"test", ClassTest}, {"data", ClassData}, {"vendored", ClassVendored}, {"minified", ClassMinified}}

// Graph builds the relation graph from the map's imports and resolved calls
// plus co-change over history: one entry per commit listing the
// repo-relative paths it touched.
func (m *Map) Graph(history [][]string, o GraphOptions) *Graph {
	g := &Graph{Root: m.Root, Opts: o, nodeOf: map[int32]int32{}}
	gid := make([]int32, len(m.Nodes)) // map node → graph node, -1 = none
	for i := range gid {
		gid[i] = -1
	}
	byPath := map[string]int32{}
	for i := range m.Files {
		f := &m.Files[i]
		if f.Class.Has(ClassBinary | ClassAsset | ClassSecret) {
			continue
		}
		n := GraphNode{ID: int32(len(g.Nodes)), Path: f.Path, Lines: f.Lines, file: int32(i)}
		if f.Lang != nil {
			n.Lang = f.Lang.Name
		}
		for _, c := range graphClasses {
			if f.Class.Has(c.class) {
				n.Class = append(n.Class, c.name)
			}
		}
		for _, s := range f.Scopes {
			if len(n.Decls) >= o.MaxDecls {
				break
			}
			if sn := &m.Nodes[s]; sn.Parent == f.Node && sn.Name != "" {
				n.Decls = append(n.Decls, sn.Name)
			}
		}
		gid[f.Node] = n.ID
		byPath[f.Path] = n.ID
		g.nodeOf[int32(i)] = n.ID
		g.Nodes = append(g.Nodes, n)
	}

	type pair struct{ s, t int32 }
	add := func(set map[pair]*GraphEdge, s, t int32, kind string, w float64) {
		e := set[pair{s, t}]
		if e == nil {
			e = &GraphEdge{S: s, T: t, Kind: kind}
			set[pair{s, t}] = e
		}
		e.W += w
		e.N++
	}
	flush := func(set map[pair]*GraphEdge, keep func(*GraphEdge) bool) int {
		n := 0
		for _, e := range set {
			if keep(e) {
				g.Edges = append(g.Edges, *e)
				n++
			}
		}
		return n
	}
	all := func(*GraphEdge) bool { return true }

	// imports: a directory target (Go package) spreads over its files
	imports := map[pair]*GraphEdge{}
	if d := m.Deps; d != nil {
		for from, outs := range d.Out {
			s := gid[from]
			if s < 0 {
				continue
			}
			for _, to := range outs {
				if m.Nodes[to].Kind != KindDir {
					if t := gid[to]; t >= 0 {
						add(imports, s, t, "import", 1)
					}
					continue
				}
				var files []int32
				for _, c := range m.Nodes[to].Children {
					if t := gid[c]; t >= 0 && t != s {
						files = append(files, t)
					}
				}
				for _, t := range files {
					add(imports, s, t, "import", 1/float64(len(files)))
				}
			}
		}
		for _, e := range imports {
			e.N = 1
		}
	}
	g.Stats.Imports = flush(imports, all)

	calls := map[pair]*GraphEdge{}
	for i := range m.Files {
		f := &m.Files[i]
		s := gid[f.Node]
		if s < 0 {
			continue
		}
		for _, sc := range f.Scopes {
			for _, name := range m.Nodes[sc].Calls {
				if to := m.resolveCall(sc, name); to >= 0 {
					if t := gid[m.fileOf(to)]; t >= 0 && t != s {
						add(calls, s, t, "call", 1)
					}
				}
			}
		}
	}
	g.Stats.Calls = flush(calls, all)

	co := map[pair]*GraphEdge{}
	var ids []int32
	for _, files := range history {
		g.Stats.Commits++
		ids = ids[:0]
		for _, p := range files {
			if id, ok := byPath[p]; ok {
				ids = append(ids, id)
				g.Nodes[id].Commits++
			}
		}
		if len(ids) < 2 {
			continue
		}
		if len(ids) > o.MaxFiles {
			g.Stats.CommitsTooLarge++
			continue
		}
		g.Stats.CommitsUsed++
		slices.Sort(ids)
		w := 1 / float64(len(ids)-1)
		for a := range ids {
			for b := a + 1; b < len(ids); b++ {
				add(co, ids[a], ids[b], "cochange", w)
			}
		}
	}
	g.Stats.CoChanges = flush(co, func(e *GraphEdge) bool { return int(e.N) >= o.MinShared })

	slices.SortFunc(g.Edges, func(a, b GraphEdge) int {
		return cmp.Or(cmp.Compare(a.Kind, b.Kind), cmp.Compare(a.S, b.S), cmp.Compare(a.T, b.T))
	})
	return g
}
