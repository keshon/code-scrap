package codemap

import (
	"cmp"
	"slices"
)

// Lens describes a height or color mode for the viewer: what it is called,
// what it measures and how to read it. Viewers show these instead of
// hard-coding names, so a new metric needs no viewer change.
type Lens struct {
	ID       string `json:"id"`
	Short    string `json:"short"`    // menu label
	Long     string `json:"long"`     // title in panels and the legend
	Desc     string `json:"desc"`     // one or two sentences: what it measures
	Unit     string `json:"unit"`     // legend unit ("" = none)
	High     string `json:"high"`     // what a high value means
	NeedsGit bool   `json:"needsGit"` // available once git history is loaded
}

var metricLenses = map[Metric]Lens{
	MetricLines: {Short: "Lines", Long: "Lines of code",
		Desc: "Source lines in the file.", Unit: "lines", High: "big file"},
	MetricComplexity: {Short: "Complexity", Long: "Peak cyclomatic complexity",
		Desc: "Highest cyclomatic complexity of any function in the file: how many independent paths its most tangled function has.",
		Unit: "paths", High: "hard to follow"},
	MetricFunctions: {Short: "Functions", Long: "Functions and scopes",
		Desc: "Number of functions, classes and other scopes declared in the file.", Unit: "scopes", High: "many pieces"},
	MetricChurn: {Short: "Churn", Long: "Churn (commits)",
		Desc: "Commits touching the file within the git history window.", Unit: "commits", High: "changed often", NeedsGit: true},
	MetricAge: {Short: "Recent change", Long: "Recency of last change",
		Desc: "How recently the file last changed: fresh files are high, files untouched for two years or more are low.",
		Unit: "days ago", High: "changed recently", NeedsGit: true},
	MetricAuthors: {Short: "Authors", Long: "Distinct authors",
		Desc: "People who committed to the file within the git history window.", Unit: "authors", High: "many hands", NeedsGit: true},
}

func metricLens(m Metric) Lens {
	l := metricLenses[m]
	l.ID = string(m)
	return l
}

// HeightLenses lists the height modes in menu order.
func HeightLenses() []Lens {
	out := []Lens{
		{ID: HeightDepth, Short: "Nesting", Long: "Nesting terraces",
			Desc: "Every directory level is a terrace, files stand on their folder: the city shows the tree's shape."},
		{ID: HeightFlat, Short: "Flat", Long: "Flat",
			Desc: "Low uniform buildings on thin plinths: the map as it is, with a little depth."},
	}
	for _, m := range Metrics {
		l := metricLens(m)
		l.Desc += " Taller = higher percentile."
		out = append(out, l)
	}
	return out
}

// ColorLenses lists the color modes in menu order.
func ColorLenses() []Lens {
	out := []Lens{
		{ID: ColorArea, Short: "Area", Long: "Top-level area",
			Desc: "Each top-level folder gets its own hue; tests, vendored and data files are muted."},
	}
	for _, m := range Metrics {
		l := metricLens(m)
		l.Desc += " Colored by percentile, cold (blue) to hot (red)."
		out = append(out, l)
	}
	return out
}

// Quantiles returns the metric's values at the 0, 25, 50, 75 and 100th
// percentile among files that have one, in the lens unit (the legend's
// scale), or nil when no file has a value.
func (m *Map) Quantiles(metric Metric) []float64 {
	now := m.GitTime
	var vals []float64
	for i := range m.Files {
		if v := m.Files[i].metric(metric, now); v > 0 {
			vals = append(vals, v)
		}
	}
	if len(vals) == 0 {
		return nil
	}
	slices.SortFunc(vals, cmp.Compare)
	out := make([]float64, 5)
	for i := range out {
		v := vals[min(len(vals)-1, i*(len(vals)-1)/4)]
		if metric == MetricAge {
			v = (1 - v) * 730 // recency back to days ago
		}
		out[i] = v
	}
	return out
}

// Area is a top-level area: a node that owns a hue.
type Area struct {
	Node  int32
	Name  string
	Hue   uint8
	Lines int64
}

// Areas lists the hue-owning nodes, biggest first.
func (m *Map) Areas() []Area {
	var out []Area
	for i := range m.Nodes {
		n := &m.Nodes[i]
		if n.Hue == HueNeutral || n.Parent < 0 || m.Nodes[n.Parent].Hue != HueNeutral {
			continue
		}
		out = append(out, Area{Node: int32(i), Name: n.Name, Hue: n.Hue, Lines: n.Lines})
	}
	slices.SortFunc(out, func(a, b Area) int { return cmp.Compare(b.Lines, a.Lines) })
	return out
}
