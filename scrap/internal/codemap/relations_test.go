package codemap

import (
	"slices"
	"strings"
	"testing"
)

// The scrap module itself is the fixture: its imports and calls are known.
func TestRelationsOnScrap(t *testing.T) {
	m, err := Build("../..", Options{})
	if err != nil {
		t.Fatal(err)
	}
	var build, withView int32 = -1, -1
	for i, n := range m.Nodes {
		if n.Kind == KindScope && n.Name == "Build" && strings.HasSuffix(m.Path(int32(i)), "codemap/build.go") {
			build = int32(i)
		}
		if n.Kind == KindScope && n.Name == "WithView" {
			withView = int32(i)
		}
	}
	if build < 0 || withView < 0 {
		t.Fatal("fixture scopes not found")
	}

	out, _, _, _ := m.CallsOf(build, 100)
	names := map[string]bool{}
	for _, e := range out {
		names[m.Nodes[e.To].Name] = true
	}
	for _, want := range []string{"listFiles", "analyze", "assemble"} {
		if !names[want] {
			t.Errorf("Build should call %s; got %v", want, names)
		}
	}

	_, in, _, _ := m.CallsOf(withView, 100)
	callers := map[string]bool{}
	for _, e := range in {
		callers[m.Nodes[e.From].Name] = true
	}
	if !callers["rebuild"] {
		t.Errorf("WithView should be called by server.rebuild; got %v", callers)
	}

	for _, f := range m.Files {
		if strings.HasSuffix(f.Path, "internal/server/api.go") {
			deps, _, _, _ := m.DepsOf(f.Node, 100)
			targets := map[string]bool{}
			for _, e := range deps {
				targets[m.Path(e.To)] = true
			}
			if !targets["internal/codemap"] || !targets["internal/tile"] {
				t.Errorf("api.go should import codemap and tile; got %v", targets)
			}
		}
	}
}

func TestGraphOnScrap(t *testing.T) {
	m, err := Build("../..", Options{})
	if err != nil {
		t.Fatal(err)
	}
	history := [][]string{
		{"internal/codemap/graph.go", "cmd/scrap/graph.go"},
		{"internal/codemap/graph.go", "cmd/scrap/graph.go", "missing.go"},
		{"internal/codemap/graph.go", "internal/codemap/model.go", "internal/codemap/deps.go"}, // mass edit at MaxFiles 2
	}
	g := m.Graph(history, GraphOptions{MaxFiles: 2, MinShared: 2, MaxDecls: 50})
	id := map[string]int32{}
	for _, n := range g.Nodes {
		id[n.Path] = n.ID
	}
	has := func(kind, s, t string) *GraphEdge {
		for i, e := range g.Edges {
			if e.Kind == kind && e.S == id[s] && e.T == id[t] {
				return &g.Edges[i]
			}
		}
		return nil
	}
	// api.go imports package codemap: an edge to each of its files
	if e := has("import", "internal/server/api.go", "internal/codemap/graph.go"); e == nil || e.W >= 1 {
		t.Errorf("package import should spread over codemap files: %+v", e)
	}
	if has("call", "cmd/scrap/main.go", "cmd/scrap/graph.go") == nil || has("call", "cmd/scrap/graph.go", "internal/gitlog/gitlog.go") == nil {
		t.Error("main should call cmdGraph, and cmdGraph gitlog.Walk")
	}
	a, b := id["internal/codemap/graph.go"], id["cmd/scrap/graph.go"]
	e := has("cochange", "cmd/scrap/graph.go", "internal/codemap/graph.go")
	if a < b {
		e = has("cochange", "internal/codemap/graph.go", "cmd/scrap/graph.go")
	}
	if e == nil || e.N != 2 || e.W != 2 {
		t.Errorf("co-change pair: %+v", e)
	}
	if g.Stats.CommitsTooLarge != 1 || g.Stats.CommitsUsed != 2 || g.Nodes[a].Commits != 3 {
		t.Errorf("stats %+v, commits %d", g.Stats, g.Nodes[a].Commits)
	}
	if !slices.Contains(g.Nodes[a].Decls, "Graph") {
		t.Errorf("graph.go decls %v", g.Nodes[a].Decls)
	}
}
