package codemap

import (
	"reflect"
	"testing"
)

// A repository shaped like a system: screens use services, services use the
// store, nothing uses the screens.
func TestArchitectureLayers(t *testing.T) {
	files := map[string]string{}
	layers := []string{"screen", "service", "store"}
	for li, dir := range layers {
		for i := 1; i <= 4; i++ {
			src := ""
			for j := 1; j <= 4; j++ { // the layer's own files hold together
				if j != i {
					src += "import {" + dir + string(rune('0'+j)) + "} from './" + string(rune('0'+j)) + "'\n"
				}
			}
			if li+1 < len(layers) { // and lean on the one below
				next := layers[li+1]
				for j := 1; j <= 2; j++ {
					src += "import {" + next + string(rune('0'+j)) + "} from '../" + next + "/" + string(rune('0'+j)) + "'\n"
				}
			}
			files[dir+"/"+string(rune('0'+i))+".ts"] = src + "export const " + dir + string(rune('0'+i)) + " = 1\n"
		}
	}
	m := buildFixture(t, files)
	cl := m.Cluster(nil, ClusterOptions{Resolution: 1, HubShare: 1, HubMin: 1000, MinSize: 3})
	a := m.Architecture(cl, DefaultArchOptions)
	if len(a.Nodes) != 3 {
		t.Fatalf("clusters: %+v", a.Nodes)
	}
	level := map[string]float64{}
	layer := map[string]int{}
	for _, n := range a.Nodes {
		level[m.Path(n.Home)] = n.Level
		layer[m.Path(n.Home)] = n.Layer
	}
	if !(level["screen"] < level["service"] && level["service"] < level["store"]) {
		t.Errorf("levels should run from the screens to the store: %v", level)
	}
	if !(layer["screen"] < layer["service"] && layer["service"] < layer["store"]) {
		t.Errorf("columns should follow the levels: %v", layer)
	}
	if a.Layers < 2 || a.Files.Clustered != 12 {
		t.Errorf("layers %d, files %+v", a.Layers, a.Files)
	}
	var lifted []string
	for _, e := range a.Edges {
		lifted = append(lifted, m.Path(a.Nodes[e.From].Home)+"→"+m.Path(a.Nodes[e.To].Home))
	}
	if want := []string{"screen→service", "service→store"}; !reflect.DeepEqual(lifted, want) {
		t.Errorf("lifted edges %v, want %v", lifted, want)
	}
	// the same map twice must give the same picture
	b := m.Architecture(cl, DefaultArchOptions)
	if !reflect.DeepEqual(a, b) {
		t.Error("architecture is not deterministic")
	}
}
