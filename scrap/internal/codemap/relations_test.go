package codemap

import (
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
