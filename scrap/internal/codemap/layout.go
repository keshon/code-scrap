package codemap

import (
	"math"

	"github.com/keshon/code-scrap/scrap/internal/treemap"
)

// Layout constants, relative to a box's shorter side.
const (
	padFrac    = 0.004 // inner padding
	headerFrac = 0.020 // label strip on top of dirs and files
	colGap     = 4     // chars between text columns

	// DefaultCharAspect is a monospace glyph's advance / line height with
	// IDE-like line spacing (Consolas: 0.55 em advance, 1.36 em lines).
	DefaultCharAspect = 0.405

	// WorldAspect is the repo rectangle's height/width inside the unit square.
	WorldAspect = 0.625
)

// Header returns the label strip of a dir or file box.
func Header(r Rect) Rect {
	m := r.Min()
	p := m * padFrac
	return rect(r.X+p, r.Y+p, r.W-2*p, m*headerFrac)
}

// content returns the area below the header where children or text go.
func content(r Rect) Rect {
	m := r.Min()
	p := m * padFrac
	h := m * headerFrac
	return rect(r.X+p, r.Y+p+h, r.W-2*p, max(r.H-2*p-h, 0))
}

// Elevation steps, relative to a box's shorter side. Each box stands on its
// parent: top = parent top + step. Steps scale with the box, so the city looks
// the same at every zoom level.
const (
	dirStep    = 0.035 // HeightDepth: a clear terrace per directory level
	fileStep   = 0.09
	plinthStep = 0.012 // other modes: thin plinths keep the hierarchy readable
	flatStep   = 0.03  // HeightFlat buildings, and the floor of metric ones
	metricStep = 1.4   // metric buildings rise up to this × their shorter side
)

func (m *Map) layout() {
	m.World = rect(0, 0, 1, WorldAspect)
	m.Nodes[0].Rect = m.World
	m.layoutNode(0)
	m.elevate()
}

// elevate assigns Top (parents precede children in pre-order) and then
// MaxTop (children follow parents, so walk backwards).
func (m *Map) elevate() {
	mode := m.View.Height
	if mode == "" {
		mode = HeightDepth
	}
	var pct []float64
	if mode != HeightDepth && mode != HeightFlat {
		pct = m.percentiles(Metric(mode))
	}
	for i := range m.Nodes {
		n := &m.Nodes[i]
		base := 0.0
		if n.Parent >= 0 {
			base = m.Nodes[n.Parent].Top
		}
		s := n.Rect.Min()
		switch n.Kind {
		case KindDir:
			if i > 0 {
				if mode == HeightDepth {
					n.Top = base + dirStep*s
				} else {
					n.Top = base + plinthStep*s
				}
			}
		case KindFile:
			switch {
			case pct != nil:
				v := max(pct[n.File], 0)
				n.Top = base + (flatStep+metricStep*math.Pow(v, 1.5))*s
			case mode == HeightFlat:
				n.Top = base + flatStep*s
			default:
				n.Top = base + fileStep*s
			}
		default:
			n.Top = base // scopes are drawn on the roof
		}
		n.MaxTop = n.Top
	}
	for i := len(m.Nodes) - 1; i > 0; i-- {
		p := &m.Nodes[m.Nodes[i].Parent]
		p.MaxTop = max(p.MaxTop, m.Nodes[i].MaxTop)
	}
}

func (m *Map) layoutNode(id int32) {
	n := &m.Nodes[id]
	switch n.Kind {
	case KindDir:
		inner := content(n.Rect)
		ws := make([]float64, len(n.Children))
		for i, c := range n.Children {
			ws[i] = m.Nodes[c].Weight
		}
		rects := treemap.Squarify(ws, inner)
		for i, c := range n.Children {
			m.Nodes[c].Rect = rects[i]
			m.layoutNode(c)
		}
	case KindFile:
		m.layoutText(&m.Files[n.File], content(n.Rect))
		f := &m.Files[n.File]
		for _, sid := range f.Scopes {
			s := &m.Nodes[sid]
			depthInFile := float64(s.Depth - n.Depth - 1)
			segs := f.Segments(s.StartLine, s.EndLine, depthInFile*0.5*f.CW)
			if len(segs) > 0 {
				s.Rect = bounds(segs)
			}
		}
	}
}

// layoutText flows a file's lines into columns so the text block matches the
// box's aspect ratio as closely as possible, maximizing line height.
func (m *Map) layoutText(f *File, r Rect) {
	f.Cols, f.Rows = 0, 0
	if f.Class.Has(ClassBinary) || f.Lines <= 0 || r.W <= 0 || r.H <= 0 {
		return
	}
	n := int(f.Lines)
	bestK, bestLH := 1, 0.0
	// Line height for k columns: lh = min(W / (k*C + (k-1)*gap)*aspect, H / ceil(n/k)).
	// It is unimodal in k, so scan around the continuous optimum.
	charAspect := m.charAspect
	kOpt := math.Sqrt(r.W * float64(n) / (r.H * charAspect * (ColChars + colGap)))
	lo := max(1, int(kOpt)-3)
	hi := min(n, int(kOpt)+3)
	for k := lo; k <= hi; k++ {
		rows := (n + k - 1) / k
		lh := min(r.W/(float64(k*ColChars+(k-1)*colGap)*charAspect), r.H/float64(rows))
		if lh > bestLH {
			bestK, bestLH = k, lh
		}
	}
	rows := (n + bestK - 1) / bestK
	f.Rows = int32(rows)
	f.Cols = int32((n + rows - 1) / rows)
	f.LH = bestLH
	f.CW = bestLH * charAspect
	f.Stride = float64(ColChars+colGap) * f.CW
	f.TX, f.TY = r.X, r.Y
}

func bounds(rs []Rect) Rect {
	x0, y0 := math.Inf(1), math.Inf(1)
	x1, y1 := math.Inf(-1), math.Inf(-1)
	for _, r := range rs {
		x0, y0 = min(x0, r.X), min(y0, r.Y)
		x1, y1 = max(x1, r.X+r.W), max(y1, r.Y+r.H)
	}
	return rect(x0, y0, x1-x0, y1-y0)
}
