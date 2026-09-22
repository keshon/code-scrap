package codemap

import (
	"cmp"
	"slices"
	"strings"
)

// The architecture view answers "how is this built", which the treemap and
// the city cannot: a handful of blocks with names, the flow between them,
// and the landmarks everything leans on. It is the cluster graph, lifted:
// every file relation becomes a relation between the clusters holding its
// ends, clusters are laid out in layers along the direction imports point,
// and clusters that lean on each other are gathered into a few groups.

type Arch struct {
	Groups []ArchGroup `json:"groups"`
	Nodes  []ArchNode  `json:"nodes"` // one per cluster, biggest first
	Edges  []ArchEdge  `json:"edges"`
	Hubs   []ArchHub   `json:"hubs"`   // landmark files, most depended on first
	Layers int         `json:"layers"` // columns: 0 = nothing depends on it
	Rows   int         `json:"rows"`   // tallest layer
	Files  ArchCounts  `json:"files"`
}

type ArchCounts struct {
	Clustered   int `json:"clustered"`
	Unclustered int `json:"unclustered"`
	Hubs        int `json:"hubs"`
}

type ArchGroup struct {
	ID       int32   `json:"id"`
	Name     string  `json:"name"`
	Clusters []int32 `json:"clusters"`
	Files    int     `json:"files"`
}

type ArchNode struct {
	Cluster  int32   `json:"cluster"` // index in Clustering.Clusters
	Name     string  `json:"name"`
	Group    int32   `json:"group"`
	Hue      uint8   `json:"hue"`
	Files    int     `json:"files"`
	Lines    int64   `json:"lines"`
	Home     int32   `json:"home"` // the folder most of it lives in
	HomePath string  `json:"homePath"`
	Level    float64 `json:"level"` // 0 = entry point, 1 = what everything leans on
	Layer    int     `json:"layer"` // that level, bucketed into columns
	Row      int     `json:"row"`   // order within the layer
}

// ArchEdge is directed: From uses To. CoChange is symmetric and repeated on
// both directions' edges.
type ArchEdge struct {
	From     int32   `json:"from"`
	To       int32   `json:"to"`
	Imports  float64 `json:"imports"`
	Calls    float64 `json:"calls"`
	CoChange float64 `json:"cochange"`
	Weight   float64 `json:"weight"` // what the layout and the line width use
}

// ArchHub is a file most of the code depends on: a landmark, in no cluster.
type ArchHub struct {
	Node      int32  `json:"node"` // file node id
	Path      string `json:"path"`
	Importers int    `json:"importers"`
}

type ArchOptions struct {
	Groups                     int     // at most this many groups
	MinEdge                    float64 // lifted edges lighter than this are dropped
	MaxHubs                    int     // landmarks reported
	CallWeight, CoChangeWeight float64 // how much calls and co-change count next to imports
}

// archColumns is how many columns the levels are bucketed into.
const archColumns = 5

// archKey is one directed cluster pair.
type archKey struct{ a, b int32 }

var DefaultArchOptions = ArchOptions{Groups: 8, MinEdge: 1, MaxHubs: 12, CallWeight: 0.5, CoChangeWeight: 0.5}

// Architecture lifts a clustering into the cluster graph.
func (m *Map) Architecture(cl *Clustering, o ArchOptions) *Arch {
	a := &Arch{Groups: []ArchGroup{}, Nodes: []ArchNode{}, Edges: []ArchEdge{}, Hubs: []ArchHub{}}
	if cl == nil || cl.graph == nil || len(cl.Clusters) == 0 {
		return a
	}
	g := cl.graph
	n := len(cl.Clusters)
	of := func(node int32) int32 { return cl.Of[g.Nodes[node].file] } // graph node → cluster

	// lift every file relation onto the clusters holding its ends
	agg := map[archKey]*ArchEdge{}
	edge := func(x, y int32) *ArchEdge {
		e := agg[archKey{x, y}]
		if e == nil {
			e = &ArchEdge{From: x, To: y}
			agg[archKey{x, y}] = e
		}
		return e
	}
	for _, e := range g.Edges {
		x, y := of(e.S), of(e.T)
		if x < 0 || y < 0 || x == y {
			continue
		}
		switch e.Kind {
		case "import":
			edge(x, y).Imports += e.W
		case "call":
			edge(x, y).Calls += float64(e.N)
		default: // co-change has no direction: count it both ways
			edge(min(x, y), max(x, y)).CoChange += e.W
			edge(max(x, y), min(x, y)).CoChange += e.W
		}
	}
	for k, e := range agg {
		e.Weight = e.Imports + o.CallWeight*e.Calls + o.CoChangeWeight*e.CoChange
		if e.Weight < o.MinEdge {
			delete(agg, k)
		}
	}

	// layers follow the direction imports point: a cluster sits one column
	// right of everything that uses it, so entry points end up on the left
	// and the code everything leans on on the right
	// for the layout, keep only the heavier direction of each pair: two
	// clusters that use each other say little about who comes first
	uses := make([][]int32, n)
	sym := map[archKey]float64{} // both directions folded together, for grouping
	for _, e := range agg {
		if e.Imports+e.Calls > 0 {
			back := agg[archKey{e.To, e.From}]
			heavier := back == nil || e.Imports+e.Calls > back.Imports+back.Calls ||
				(e.Imports+e.Calls == back.Imports+back.Calls && e.From < e.To)
			if heavier {
				uses[e.From] = append(uses[e.From], e.To)
			}
		}
		sym[archKey{min(e.From, e.To), max(e.From, e.To)}] += e.Weight
	}
	und := newWGraph(n)
	pairs := make([]archKey, 0, len(sym))
	for k := range sym {
		pairs = append(pairs, k)
	}
	slices.SortFunc(pairs, func(p, q archKey) int { return cmp.Or(cmp.Compare(p.a, q.a), cmp.Compare(p.b, q.b)) })
	for _, k := range pairs {
		und.adj[k.a] = append(und.adj[k.a], wedge{k.b, sym[k]})
		und.adj[k.b] = append(und.adj[k.b], wedge{k.a, sym[k]})
	}
	for i := range uses {
		slices.Sort(uses[i])
		uses[i] = slices.Compact(uses[i])
		slices.SortFunc(und.adj[i], func(p, q wedge) int { return cmp.Compare(p.to, q.to) })
	}
	und.finish()
	level, layer := levels(n, agg)

	// groups: the same community detection, one level up
	group := groupClusters(und, o.Groups)

	// rows: inside a layer, keep clusters of one group together, bigger first
	rows := make([]int, n)
	byLayer := map[int][]int32{}
	for c := 0; c < n; c++ {
		byLayer[layer[c]] = append(byLayer[layer[c]], int32(c))
	}
	for l, cs := range byLayer {
		slices.SortFunc(cs, func(x, y int32) int {
			return cmp.Or(cmp.Compare(group[x], group[y]), cmp.Compare(cl.Clusters[y].Files, cl.Clusters[x].Files), cmp.Compare(x, y))
		})
		for i, c := range cs {
			rows[c] = i
		}
		a.Layers = max(a.Layers, l+1)
		a.Rows = max(a.Rows, len(cs))
	}

	for c := 0; c < n; c++ {
		x := &cl.Clusters[c]
		a.Nodes = append(a.Nodes, ArchNode{
			Cluster: int32(c), Name: x.Name, Group: group[c], Hue: x.Hue,
			Files: x.Files, Lines: x.Lines, Home: x.Home, HomePath: m.Path(x.Home),
			Level: level[c], Layer: layer[c], Row: rows[c],
		})
	}
	for _, e := range agg {
		a.Edges = append(a.Edges, *e)
	}
	slices.SortFunc(a.Edges, func(p, q ArchEdge) int {
		return cmp.Or(cmp.Compare(q.Weight, p.Weight), cmp.Compare(p.From, q.From), cmp.Compare(p.To, q.To))
	})

	// groups, biggest first, named after what their clusters have in common
	members := map[int32][]int32{}
	for c, gi := range group {
		members[gi] = append(members[gi], int32(c))
	}
	for gi, cs := range members {
		files := 0
		for _, c := range cs {
			files += cl.Clusters[c].Files
		}
		a.Groups = append(a.Groups, ArchGroup{ID: gi, Name: groupName(cl, cs), Clusters: cs, Files: files})
	}
	slices.SortFunc(a.Groups, func(p, q ArchGroup) int {
		return cmp.Or(cmp.Compare(q.Files, p.Files), cmp.Compare(p.ID, q.ID))
	})

	for _, f := range cl.Hubs[:min(len(cl.Hubs), o.MaxHubs)] {
		node := m.Files[f].Node
		a.Hubs = append(a.Hubs, ArchHub{Node: node, Path: m.Files[f].Path, Importers: len(m.Deps.In[node])})
	}
	for _, k := range cl.Of {
		switch {
		case k >= 0:
			a.Files.Clustered++
		case k == ClusterHub:
			a.Files.Hubs++
		}
	}
	a.Files.Unclustered = len(g.Nodes) - a.Files.Clustered - a.Files.Hubs
	return a
}

// levels place the clusters along the direction dependencies point: a
// cluster that is used a lot and uses little sits deep, one that only uses
// others sits at the entry. Levels solve the hierarchy equation of a
// directed network (MacKay et al.): L·h = in − out, where L is the
// Laplacian of the undirected weights. Unlike counting steps, it stays
// meaningful when clusters use each other in rings, as user interfaces
// always do. The answer is scaled to 0..1 (0 = entry point) and bucketed
// into columns by rank.
func levels(n int, agg map[archKey]*ArchEdge) ([]float64, []int) {
	type link struct {
		to int32
		w  float64
	}
	both := make([][]link, n)       // undirected weights, for the Laplacian
	deg := make([]float64, n)       // in + out
	imbalance := make([]float64, n) // in − out
	for k, e := range agg {
		w := e.Imports + 0.5*e.Calls // co-change says nothing about direction
		if w <= 0 {
			continue
		}
		both[k.a] = append(both[k.a], link{k.b, w})
		both[k.b] = append(both[k.b], link{k.a, w})
		deg[k.a] += w
		deg[k.b] += w
		imbalance[k.a] -= w
		imbalance[k.b] += w
	}
	for i := range both {
		slices.SortFunc(both[i], func(p, q link) int { return cmp.Compare(p.to, q.to) })
	}
	h := make([]float64, n)
	for round := 0; round < 400; round++ { // Gauss-Seidel; a few hundred is plenty at this size
		for v := 0; v < n; v++ {
			if deg[v] == 0 {
				continue
			}
			sum := imbalance[v]
			for _, u := range both[v] {
				sum += u.w * h[u.to]
			}
			h[v] = sum / deg[v]
		}
	}
	lo, hi := h[0], h[0]
	for _, x := range h {
		lo, hi = min(lo, x), max(hi, x)
	}
	out := make([]float64, n)
	span := max(hi-lo, 1e-9)
	for v, x := range h {
		out[v] = (x - lo) / span
	}
	// columns by rank, not by value: one very deep cluster would otherwise
	// squeeze everything else into a single column
	order := make([]int32, n)
	for i := range order {
		order[i] = int32(i)
	}
	slices.SortFunc(order, func(p, q int32) int { return cmp.Or(cmp.Compare(out[p], out[q]), cmp.Compare(p, q)) })
	cols := make([]int, n)
	for rank, v := range order {
		if rank > 0 && out[v] == out[order[rank-1]] {
			cols[v] = cols[order[rank-1]] // ties share a column
			continue
		}
		cols[v] = min(rank*archColumns/n, archColumns-1)
	}
	return out, cols
}

// groupClusters gathers clusters that lean on each other, lowering the
// resolution until few enough groups are left.
func groupClusters(g *wGraph, want int) []int32 {
	best := make([]int32, len(g.adj))
	for i := range best {
		best[i] = int32(i)
	}
	if want <= 0 || g.total == 0 {
		return best
	}
	for res := 600; res >= 2; res -= 10 {
		memb := splitDisconnected(g, louvain(g, float64(res)/100))
		seen := map[int32]int32{}
		for i, c := range memb {
			id, ok := seen[c]
			if !ok {
				id = int32(len(seen))
				seen[c] = id
			}
			memb[i] = id
		}
		best = memb
		if len(seen) <= want {
			break
		}
	}
	return best
}

// groupName is the words its clusters' names share, else the biggest one's.
func groupName(cl *Clustering, cs []int32) string {
	if len(cs) == 1 {
		return cl.Clusters[cs[0]].Name
	}
	weight := map[string]int{}
	for _, c := range cs {
		for _, w := range strings.Split(cl.Clusters[c].Name, " · ") {
			if w != "" {
				weight[w] += cl.Clusters[c].Files
			}
		}
	}
	words := make([]string, 0, len(weight))
	for w := range weight {
		words = append(words, w)
	}
	slices.SortFunc(words, func(a, b string) int {
		return cmp.Or(cmp.Compare(weight[b], weight[a]), cmp.Compare(a, b))
	})
	var pick []string
	for _, w := range words {
		if slices.ContainsFunc(pick, func(p string) bool { return sharesWord(p, w) }) {
			continue
		}
		if pick = append(pick, w); len(pick) == 2 {
			break
		}
	}
	return strings.Join(pick, " · ")
}
