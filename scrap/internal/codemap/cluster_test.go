package codemap

import (
	"reflect"
	"testing"
)

func TestLouvainCliques(t *testing.T) {
	// two 4-cliques joined by one weak edge, plus a separate pair
	g := newWGraph(10)
	link := func(a, b int32, w float64) {
		g.adj[a] = append(g.adj[a], wedge{b, w})
		g.adj[b] = append(g.adj[b], wedge{a, w})
	}
	for _, q := range [][]int32{{0, 1, 2, 3}, {4, 5, 6, 7}} {
		for i := range q {
			for j := i + 1; j < len(q); j++ {
				link(q[i], q[j], 1)
			}
		}
	}
	link(3, 4, 0.1)
	link(8, 9, 1)
	g.finish()
	memb := splitDisconnected(g, louvain(g, 1))
	same := func(a, b int) bool { return memb[a] == memb[b] }
	if !same(0, 3) || !same(4, 7) || same(0, 4) || !same(8, 9) || same(8, 0) {
		t.Errorf("communities %v", memb)
	}
	if again := splitDisconnected(g, louvain(g, 1)); !reflect.DeepEqual(again, memb) {
		t.Errorf("not deterministic: %v vs %v", again, memb)
	}
}

func TestSplitWords(t *testing.T) {
	for in, want := range map[string][]string{
		"ChecklistItemStore": {"checklist", "item", "store"},
		"use-board-filters":  {"use", "board", "filter"},
		"HTTPClient":         {"http", "client"},
		"getV2Items":         {"get", "item"},
		"mobille_api":        {"mobille", "api"},
		"class":              {"class"},
	} {
		if got := splitWords(in); !reflect.DeepEqual(got, want) {
			t.Errorf("splitWords(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestClusterFixture(t *testing.T) {
	files := map[string]string{
		"hub.ts":    "export const hub = 1\n",
		"b.test.ts": "import {b1} from './billing/b1'\n",
		"README.md": "# fixture\n",
	}
	// two tight groups in their own folders; every file imports the hub
	for _, grp := range []string{"billing", "chat", "search"} {
		for i := 1; i <= 4; i++ {
			var src string
			for j := 1; j <= 4; j++ {
				if j != i {
					src += "import {" + grp[:1] + string(rune('0'+j)) + "} from './" + grp[:1] + string(rune('0'+j)) + "'\n"
				}
			}
			src += "import {hub} from '../hub'\nexport const " + grp[:1] + string(rune('0'+i)) + " = 1\nexport function " + grp + "Thing" + string(rune('0'+i)) + "() {}\n"
			files[grp+"/"+grp[:1]+string(rune('0'+i))+".ts"] = src
		}
	}
	m := buildFixture(t, files)
	c := m.Cluster(nil, ClusterOptions{Resolution: 1, HubShare: 0.5, HubMin: 3, MinSize: 3})
	of := map[string]int32{}
	for i, f := range m.Files {
		of[f.Path] = c.Of[i]
	}
	if len(c.Clusters) != 3 {
		t.Fatalf("clusters %+v", c.Clusters)
	}
	if of["hub.ts"] != ClusterHub {
		t.Errorf("hub.ts should be a hub, got %d", of["hub.ts"])
	}
	if of["billing/b1.ts"] != of["billing/b4.ts"] || of["billing/b1.ts"] == of["chat/c1.ts"] || of["chat/c1.ts"] != of["chat/c4.ts"] {
		t.Errorf("membership %v", of)
	}
	if of["b.test.ts"] != of["billing/b1.ts"] {
		t.Errorf("test should attach to its subject's cluster: %v", of)
	}
	if of["README.md"] != ClusterNone {
		t.Errorf("README should stay unclustered: %v", of)
	}
	for _, x := range c.Clusters {
		home := m.Path(x.Home)
		if (home != "billing" && home != "chat" && home != "search") || x.Name == "" || x.Files != 4+btoi(home == "billing") {
			t.Errorf("cluster %+v (home %s)", x, home)
		}
	}
	if c.Clusters[0].Hue == c.Clusters[1].Hue || c.Clusters[0].Name == c.Clusters[1].Name {
		t.Errorf("clusters should differ: %+v", c.Clusters)
	}
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}
