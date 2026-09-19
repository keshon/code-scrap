package codemap

import (
	"cmp"
	"slices"
)

// View selects how the map is shaped and colored. Every lens is optional;
// the zero value is the plain map (areas by size, terraces by nesting,
// colors by top-level area).
type View struct {
	Height     string `json:"height"`     // HeightDepth (default), HeightFlat, or a Metric
	Color      string `json:"color"`      // ColorArea (default) or a Metric
	Importance bool   `json:"importance"` // shrink vendored, test, generated, asset and data files
}

// Height modes besides the metrics.
const (
	HeightDepth = "depth" // every directory level is a terrace (default)
	HeightFlat  = "flat"  // thin plinths per level, low uniform buildings
	ColorArea   = "area"  // hue per top-level area (default)
)

// Metric names a per-file measure usable for height and color.
type Metric string

const (
	MetricLines      Metric = "lines"      // source lines
	MetricComplexity Metric = "complexity" // highest cyclomatic complexity of any function
	MetricFunctions  Metric = "functions"  // number of scopes
	MetricChurn      Metric = "churn"      // commits touching the file (git)
	MetricAge        Metric = "age"        // days since the last commit, fresh = high (git)
	MetricAuthors    Metric = "authors"    // distinct commit authors (git)
)

// Metrics lists the metrics in UI order.
var Metrics = []Metric{MetricLines, MetricComplexity, MetricFunctions, MetricChurn, MetricAge, MetricAuthors}

// Importance factors: how much area a file class keeps when weighting by
// importance. The core code keeps 1.
var importance = []struct {
	class  FileClass
	factor float64
}{
	{ClassMinified, 0.08}, {ClassAsset, 0.1}, {ClassVendored, 0.12}, {ClassData, 0.3}, {ClassTest, 0.35},
}

func importanceFactor(c FileClass) float64 {
	f := 1.0
	for _, i := range importance {
		if c.Has(i.class) {
			f = min(f, i.factor)
		}
	}
	return f
}

// metric returns a file's raw metric value (0 when unknown).
func (f *File) metric(m Metric, now int64) float64 {
	switch m {
	case MetricLines:
		return float64(f.Lines)
	case MetricComplexity:
		return float64(f.MaxComplexity)
	case MetricFunctions:
		return float64(len(f.Scopes))
	case MetricChurn:
		return float64(f.Commits)
	case MetricAuthors:
		return float64(f.Authors)
	case MetricAge:
		if f.LastChange == 0 {
			return 0
		}
		// recency: 1 for today, fading over two years
		days := float64(now-f.LastChange) / 86400
		return max(0, 730-days) / 730
	}
	return 0
}

// percentiles maps each file's metric to its rank in [0, 1] among files
// with a value; files without one get -1. Ranks make one hot outlier
// unable to flatten everything else.
func (m *Map) percentiles(metric Metric) []float64 {
	now := m.GitTime
	type fv struct {
		i int
		v float64
	}
	var vals []fv
	out := make([]float64, len(m.Files))
	for i := range m.Files {
		out[i] = -1
		if v := m.Files[i].metric(metric, now); v > 0 {
			vals = append(vals, fv{i, v})
		}
	}
	slices.SortFunc(vals, func(a, b fv) int { return cmp.Compare(a.v, b.v) })
	for r := 0; r < len(vals); {
		// ties share a rank
		e := r
		for e < len(vals) && vals[e].v == vals[r].v {
			e++
		}
		p := float64(e) / float64(len(vals))
		for k := r; k < e; k++ {
			out[vals[k].i] = p
		}
		r = e
	}
	return out
}

// WithView returns a copy of the map shaped by v. The copy shares
// everything that v cannot change (names, symbols, text); layout, heights
// and heat are recomputed. m itself is never modified, so tiles already
// being served from it stay consistent.
func (m *Map) WithView(v View) *Map {
	nm := *m
	nm.View = v
	nm.Nodes = slices.Clone(m.Nodes)
	nm.Files = slices.Clone(m.Files)
	for i := range nm.Nodes {
		nm.Nodes[i].Children = slices.Clone(m.Nodes[i].Children)
	}
	nm.reweigh()
	nm.layout()
	nm.heat()
	return &nm
}

// reweigh recomputes areas from each file's base weight and re-sorts
// siblings (largest first) unless the map is laid out by name.
func (m *Map) reweigh() {
	for i := len(m.Nodes) - 1; i >= 0; i-- {
		n := &m.Nodes[i]
		switch n.Kind {
		case KindFile:
			n.Weight = n.BaseWeight
			if m.View.Importance {
				n.Weight *= importanceFactor(m.Files[n.File].Class)
			}
		case KindDir:
			n.Weight = 0
			for _, c := range n.Children {
				n.Weight += m.Nodes[c].Weight
			}
		}
	}
	if m.sortByName {
		return
	}
	for i := range m.Nodes {
		n := &m.Nodes[i]
		if n.Kind != KindDir {
			continue
		}
		slices.SortStableFunc(n.Children, func(a, b int32) int {
			if c := cmp.Compare(m.Nodes[b].Weight, m.Nodes[a].Weight); c != 0 {
				return c
			}
			return cmp.Compare(m.Nodes[a].Name, m.Nodes[b].Name)
		})
	}
}

// heat sets Node.Heat for the active color metric: 0..1 for files with a
// value, -1 otherwise (and for everything in area mode).
func (m *Map) heat() {
	for i := range m.Nodes {
		m.Nodes[i].Heat = -1
	}
	if m.View.Color == "" || m.View.Color == ColorArea {
		return
	}
	p := m.percentiles(Metric(m.View.Color))
	for fi := range m.Files {
		m.Nodes[m.Files[fi].Node].Heat = float32(p[fi])
		for _, s := range m.Files[fi].Scopes {
			m.Nodes[s].Heat = float32(p[fi])
		}
	}
}

// GitStat is the history of one file (see package gitlog).
type GitStat struct {
	Commits    int32
	Authors    int32
	LastChange int64
}

// WithGit returns a copy of the map with git metrics attached to its files
// (keyed by repo-relative path). now anchors the "age" metric.
func (m *Map) WithGit(stats map[string]GitStat, now int64) *Map {
	nm := *m
	nm.Files = slices.Clone(m.Files)
	for i := range nm.Files {
		f := &nm.Files[i]
		if s, ok := stats[f.Path]; ok {
			f.Commits, f.Authors, f.LastChange = s.Commits, s.Authors, s.LastChange
		}
	}
	nm.GitTime = now
	return &nm
}
