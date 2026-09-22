package codemap

import (
	"cmp"
	"math"
	"slices"
	"strings"
	"unicode"
)

// Clusters group files by how they are connected (imports, calls, changing
// together in git) rather than by folder. Hubs — files most of the code
// imports — are kept out as landmarks; tests, styles and other non-code
// files join the cluster they are most connected to.

// ColorCluster colors files by cluster (View.Color).
const ColorCluster = "cluster"

// Cluster membership for files outside every cluster.
const (
	ClusterNone int32 = -1 // unconnected, or in a group too small to count
	ClusterHub  int32 = -2 // imported by a large share of the code
)

type Clustering struct {
	Of       []int32   // by file index: cluster index, ClusterNone or ClusterHub
	Clusters []Cluster // biggest first
	Hubs     []int32   // hub file indices, most imported first

	graph *Graph // the relation graph it was built from (for Architecture)
}

type Cluster struct {
	Name  string // distinctive words of its files, "a · b · c"
	Hue   uint8  // palette slot; strongly linked clusters get different ones
	Core  int    // code files clustered by the graph
	Files int    // core plus attached files
	Lines int64
	Home  int32 // deepest directory node holding most of its files
}

type ClusterOptions struct {
	Resolution float64 // higher = more, smaller clusters (1 = modularity)
	HubShare   float64 // a file imported by this share of the code is a hub…
	HubMin     int     // …and by at least this many files
	MinSize    int     // smaller clusters are left unclustered
}

var DefaultClusterOptions = ClusterOptions{Resolution: 1, HubShare: 0.015, HubMin: 10, MinSize: 12}

// isCode tells whether a file takes part in clustering itself; other text
// files are attached to the cluster they relate to most.
func isCode(f *File) bool {
	if f.Lang == nil || f.Lang.Data || f.Class.Has(ClassBinary|ClassAsset|ClassSecret|ClassTest|ClassData|ClassVendored|ClassMinified) {
		return false
	}
	switch f.Lang.Name {
	case "Markdown", "Text", "Markup", "CSS":
		return false
	}
	return true
}

// Cluster partitions the map's files. history lists the paths each commit
// touched (nil = no co-change).
func (m *Map) Cluster(history [][]string, o ClusterOptions) *Clustering {
	g := m.Graph(history, GraphOptions{MaxFiles: 40, MinShared: 2, MaxDecls: 24})
	n := len(g.Nodes)
	code := make([]bool, n)
	nCode := 0
	for i := range g.Nodes {
		if code[i] = isCode(&m.Files[g.Nodes[i].file]); code[i] {
			nCode++
		}
	}

	// hubs: imported by a large share of the code. Weighted, so a Go
	// package import (spread over its files) doesn't make every file of a
	// popular package a hub.
	importers := make([]float64, n)
	for _, e := range g.Edges {
		if e.Kind == "import" && code[e.S] && code[e.T] {
			importers[e.T] += e.W
		}
	}
	hub := make([]bool, n)
	for i := range hub {
		hub[i] = code[i] && importers[i] >= max(float64(o.HubMin), o.HubShare*float64(nCode))
	}

	// one undirected weight per pair of files
	type pair struct{ a, b int32 }
	w := map[pair]float64{}
	for _, e := range g.Edges {
		if e.S == e.T || hub[e.S] || hub[e.T] {
			continue
		}
		var x float64
		switch e.Kind {
		case "import":
			x = e.W
		case "call":
			x = 0.5 * math.Log2(1+float64(e.N))
		default:
			x = min(e.W, 4)
		}
		w[pair{min(e.S, e.T), max(e.S, e.T)}] += x
	}
	adj := make([][]wedge, n) // all files: for attaching
	for p, x := range w {
		adj[p.a] = append(adj[p.a], wedge{p.b, x})
		adj[p.b] = append(adj[p.b], wedge{p.a, x})
	}
	for i := range adj { // map order is random: fix the order for determinism
		slices.SortFunc(adj[i], func(a, b wedge) int { return cmp.Compare(a.to, b.to) })
	}

	// cluster the connected code files
	var core []int32
	local := make([]int32, n)
	for i := range local {
		local[i] = -1
	}
	for i := range g.Nodes {
		if code[i] && !hub[i] && slices.ContainsFunc(adj[i], func(e wedge) bool { return code[e.to] }) {
			local[i] = int32(len(core))
			core = append(core, int32(i))
		}
	}
	cg := newWGraph(len(core))
	for li, gi := range core {
		for _, e := range adj[gi] {
			if lj := local[e.to]; lj >= 0 {
				cg.adj[li] = append(cg.adj[li], wedge{lj, e.w})
			}
		}
	}
	cg.finish()
	memb := splitDisconnected(cg, louvain(cg, o.Resolution))

	// order clusters by size; small ones stay unclustered
	count := map[int32]int{}
	for _, c := range memb {
		count[c]++
	}
	var ids []int32
	for c, k := range count {
		if k >= o.MinSize {
			ids = append(ids, c)
		}
	}
	slices.SortFunc(ids, func(a, b int32) int { return cmp.Or(cmp.Compare(count[b], count[a]), cmp.Compare(a, b)) })
	rank := map[int32]int32{}
	for k, c := range ids {
		rank[c] = int32(k)
	}

	label := make([]int32, n) // by graph node
	for i := range label {
		label[i] = ClusterNone
		if hub[i] {
			label[i] = ClusterHub
		}
	}
	for li, gi := range core {
		if k, ok := rank[memb[li]]; ok {
			label[gi] = k
		}
	}
	res := &Clustering{Of: make([]int32, len(m.Files)), Clusters: make([]Cluster, len(ids))}
	for k := range res.Clusters {
		res.Clusters[k].Home = -1
	}
	for i := range g.Nodes {
		if label[i] >= 0 {
			res.Clusters[label[i]].Core++
		}
	}
	// attach everything else that isn't a hub to its strongest cluster
	attached := slices.Clone(label)
	for i := range g.Nodes {
		if label[i] != ClusterNone || (code[i] && local[i] >= 0) {
			continue
		}
		score := map[int32]float64{}
		for _, e := range adj[i] {
			if c := label[e.to]; c >= 0 {
				score[c] += e.w
			}
		}
		best, bw := ClusterNone, 0.0
		for c, x := range score {
			if x > bw || (x == bw && c < best) {
				best, bw = c, x
			}
		}
		attached[i] = best
	}
	for i := range res.Of {
		res.Of[i] = ClusterNone
	}
	for i, gn := range g.Nodes {
		res.Of[gn.file] = attached[i]
		switch c := attached[i]; {
		case c >= 0:
			res.Clusters[c].Files++
			res.Clusters[c].Lines += int64(gn.Lines)
		case c == ClusterHub:
			res.Hubs = append(res.Hubs, gn.file)
		}
	}
	slices.SortFunc(res.Hubs, func(a, b int32) int {
		return cmp.Compare(importers[g.nodeOf[b]], importers[g.nodeOf[a]])
	})

	res.graph = g
	m.nameClusters(res, g, label)
	m.homeClusters(res)
	colorClusters(res, adj, label)
	return res
}

// ClusterOf returns a file's cluster membership (ClusterNone without a
// clustering).
func (m *Map) ClusterOf(file int32) int32 {
	if m.Clusters == nil || int(file) >= len(m.Clusters.Of) {
		return ClusterNone
	}
	return m.Clusters.Of[file]
}

// WithClusters returns a copy of the map carrying a clustering computed for
// it (or for a map with the same files).
func (m *Map) WithClusters(c *Clustering) *Map {
	nm := *m
	nm.Clusters = c
	return &nm
}

// --- community detection ----------------------------------------------------

type wedge struct {
	to int32
	w  float64
}

// wGraph is an undirected weighted graph; adj lists every edge in both
// directions, self holds each node's internal weight (counted both ways).
type wGraph struct {
	adj   [][]wedge
	self  []float64
	deg   []float64
	total float64 // Σ deg
}

func newWGraph(n int) *wGraph {
	return &wGraph{adj: make([][]wedge, n), self: make([]float64, n), deg: make([]float64, n)}
}

func (g *wGraph) finish() {
	g.total = 0
	for i := range g.adj {
		g.deg[i] = g.self[i]
		for _, e := range g.adj[i] {
			g.deg[i] += e.w
		}
		g.total += g.deg[i]
	}
}

// louvain returns a community per node, maximizing modularity with the
// given resolution. Nodes are visited in index order and ties keep the
// current community, so the result is deterministic.
func louvain(g *wGraph, resolution float64) []int32 {
	n := len(g.adj)
	memb := make([]int32, n)
	for i := range memb {
		memb[i] = int32(i)
	}
	if g.total == 0 {
		return memb
	}
	cur := g
	for level := 0; level < 32; level++ {
		comm, moved := localMoves(cur, resolution)
		if !moved {
			break
		}
		// renumber communities densely in first-seen order
		ren := make([]int32, len(comm))
		for i := range ren {
			ren[i] = -1
		}
		k := int32(0)
		for i, c := range comm {
			if ren[c] < 0 {
				ren[c] = k
				k++
			}
			comm[i] = ren[c]
		}
		for i := range memb {
			memb[i] = comm[memb[i]]
		}
		if int(k) == len(cur.adj) {
			break
		}
		cur = aggregate(cur, comm, int(k))
	}
	return memb
}

// localMoves moves single nodes to the neighboring community with the best
// modularity gain until no move helps.
func localMoves(g *wGraph, res float64) ([]int32, bool) {
	n := len(g.adj)
	comm := make([]int32, n)
	tot := make([]float64, n)
	for i := range comm {
		comm[i] = int32(i)
		tot[i] = g.deg[i]
	}
	links := make([]float64, n) // scratch: weight from the node to each community
	var touched []int32
	movedAny := false
	for pass := 0; pass < 64; pass++ {
		moved := false
		for i := 0; i < n; i++ {
			ki := g.deg[i]
			c0 := comm[i]
			touched = touched[:0]
			for _, e := range g.adj[i] {
				if int(e.to) == i {
					continue
				}
				c := comm[e.to]
				if links[c] == 0 {
					touched = append(touched, c)
				}
				links[c] += e.w
			}
			tot[c0] -= ki
			best, bestGain := c0, links[c0]-res*tot[c0]*ki/g.total
			for _, c := range touched {
				if gain := links[c] - res*tot[c]*ki/g.total; gain > bestGain+1e-12 {
					best, bestGain = c, gain
				}
			}
			tot[best] += ki
			comm[i] = best
			for _, c := range touched {
				links[c] = 0
			}
			if best != c0 {
				moved = true
				movedAny = true
			}
		}
		if !moved {
			break
		}
	}
	return comm, movedAny
}

// aggregate collapses each community into one node.
func aggregate(g *wGraph, comm []int32, k int) *wGraph {
	ng := newWGraph(k)
	acc := make([]map[int32]float64, k)
	for i := range g.adj {
		ci := comm[i]
		ng.self[ci] += g.self[i]
		for _, e := range g.adj[i] {
			cj := comm[e.to]
			if cj == ci {
				ng.self[ci] += e.w
				continue
			}
			if acc[ci] == nil {
				acc[ci] = map[int32]float64{}
			}
			acc[ci][cj] += e.w
		}
	}
	for c, row := range acc {
		for d, w := range row {
			ng.adj[c] = append(ng.adj[c], wedge{d, w})
		}
		slices.SortFunc(ng.adj[c], func(a, b wedge) int { return cmp.Compare(a.to, b.to) })
	}
	ng.finish()
	return ng
}

// splitDisconnected gives each connected piece of a community its own id,
// the guarantee Louvain lacks and Leiden adds.
func splitDisconnected(g *wGraph, memb []int32) []int32 {
	out := make([]int32, len(memb))
	for i := range out {
		out[i] = -1
	}
	next := int32(0)
	var stack []int32
	for s := range memb {
		if out[s] >= 0 {
			continue
		}
		out[s] = next
		stack = append(stack[:0], int32(s))
		for len(stack) > 0 {
			v := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			for _, e := range g.adj[v] {
				if out[e.to] < 0 && memb[e.to] == memb[s] {
					out[e.to] = next
					stack = append(stack, e.to)
				}
			}
		}
		next++
	}
	return out
}

// --- names, homes, colors ---------------------------------------------------

// nameClusters names each cluster by the words (and word pairs) of its core
// files' paths and declarations that are most over-represented in it.
func (m *Map) nameClusters(res *Clustering, g *Graph, label []int32) {
	words := make([][]string, len(g.Nodes))
	df := map[string]int{}
	nCore := 0
	for i := range g.Nodes {
		if label[i] < 0 {
			continue
		}
		nCore++
		words[i] = fileWords(&g.Nodes[i])
		for _, t := range words[i] {
			df[t]++
		}
	}
	counts := make([]map[string]int, len(res.Clusters))
	for i := range g.Nodes {
		if c := label[i]; c >= 0 {
			if counts[c] == nil {
				counts[c] = map[string]int{}
			}
			for _, t := range words[i] {
				counts[c][t]++
			}
		}
	}
	type scored struct {
		t string
		s float64
	}
	for c := range res.Clusters {
		size := float64(res.Clusters[c].Core)
		var cand []scored
		for t, k := range counts[c] {
			share := float64(k) / size
			global := float64(df[t]) / float64(nCore)
			lift := share / global
			if k < 2 || lift < 2 || (global >= 0.08 && share < 0.6) {
				continue
			}
			s := share * math.Log(lift)
			if strings.Contains(t, " ") {
				s *= 1.3
			}
			cand = append(cand, scored{t, s})
		}
		slices.SortFunc(cand, func(a, b scored) int { return cmp.Or(cmp.Compare(b.s, a.s), cmp.Compare(a.t, b.t)) })
		var pick []string
		for _, x := range cand {
			if slices.ContainsFunc(pick, func(p string) bool { return sharesWord(p, x.t) }) {
				continue
			}
			if pick = append(pick, x.t); len(pick) == 3 {
				break
			}
		}
		res.Clusters[c].Name = strings.Join(pick, " · ")
	}
}

// fileWords lists the distinct words and adjacent word pairs of a file's
// directories, file name and top-level declarations.
func fileWords(n *GraphNode) []string {
	parts := strings.Split(n.Path, "/")
	stem, _, _ := strings.Cut(parts[len(parts)-1], ".")
	names := append(append([]string{stem}, parts[:len(parts)-1]...), n.Decls...)
	set := map[string]bool{}
	for _, name := range names {
		w := splitWords(name)
		for i, t := range w {
			set[t] = true
			if i > 0 {
				set[w[i-1]+" "+t] = true
			}
		}
	}
	out := make([]string, 0, len(set))
	for t := range set {
		out = append(out, t)
	}
	slices.Sort(out)
	return out
}

// splitWords splits an identifier or path segment into lower-case words of
// three letters or more, at separators and camelCase humps, singularized.
func splitWords(s string) []string {
	var out []string
	r := []rune(s)
	start := -1
	flush := func(end int) {
		if start >= 0 && end-start >= 3 {
			w := strings.ToLower(string(r[start:end]))
			if strings.TrimLeft(w, "0123456789") != "" {
				if len(w) > 4 && strings.HasSuffix(w, "s") && !strings.HasSuffix(w, "ss") {
					w = w[:len(w)-1]
				}
				out = append(out, w)
			}
		}
		start = -1
	}
	for i, c := range r {
		if !unicode.IsLetter(c) && !unicode.IsDigit(c) {
			flush(i)
			continue
		}
		if start >= 0 && unicode.IsUpper(c) {
			prevLower := !unicode.IsUpper(r[i-1])
			nextLower := i+1 < len(r) && unicode.IsLower(r[i+1])
			if prevLower || (unicode.IsUpper(r[i-1]) && nextLower) {
				flush(i)
			}
		}
		if start < 0 {
			start = i
		}
	}
	flush(len(r))
	return out
}

func sharesWord(a, b string) bool {
	for _, x := range strings.Fields(a) {
		if slices.Contains(strings.Fields(b), x) {
			return true
		}
	}
	return false
}

// homeClusters finds each cluster's home: the deepest directory holding at
// least half of its files.
func (m *Map) homeClusters(res *Clustering) {
	counts := make([]map[int32]int, len(res.Clusters))
	for fi, c := range res.Of {
		if c < 0 {
			continue
		}
		if counts[c] == nil {
			counts[c] = map[int32]int{}
		}
		for d := m.Nodes[m.Files[fi].Node].Parent; d >= 0; d = m.Nodes[d].Parent {
			counts[c][d]++
		}
	}
	for c := range res.Clusters {
		home, depth := int32(0), -1
		for d, k := range counts[c] {
			if 2*k >= res.Clusters[c].Files {
				if dd := int(m.Nodes[d].Depth); dd > depth || (dd == depth && d < home) {
					home, depth = d, dd
				}
			}
		}
		res.Clusters[c].Home = home
	}
}

// colorClusters gives clusters palette slots, biggest first, each taking the
// slot least linked to the clusters already holding it.
func colorClusters(res *Clustering, adj [][]wedge, label []int32) {
	k := len(res.Clusters)
	link := make([]map[int32]float64, k)
	for i, row := range adj {
		a := label[i]
		if a < 0 {
			continue
		}
		for _, e := range row {
			if b := label[e.to]; b >= 0 && b != a {
				if link[a] == nil {
					link[a] = map[int32]float64{}
				}
				link[a][b] += e.w
			}
		}
	}
	var used [16]int
	for c := range res.Clusters {
		var clash [16]float64
		for d, x := range link[c] {
			if int(d) < c {
				clash[res.Clusters[d].Hue] += x
			}
		}
		best := 0
		for h := 1; h < 16; h++ {
			if clash[h] < clash[best] || (clash[h] == clash[best] && used[h] < used[best]) {
				best = h
			}
		}
		res.Clusters[c].Hue = uint8(best)
		used[best]++
	}
}
