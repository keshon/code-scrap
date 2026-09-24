package codemap

import (
	"math"

	"github.com/keshon/code-scrap/scrap/internal/treemap"
)

// Layout constants, relative to a box's shorter side.
const (
	padFrac       = 0.004 // inner padding
	headerFrac    = 0.020 // label strip on top of dirs and files
	dirHeaderFrac = 0.045 // folder header band (View.Headers) of the whole map…
	dirHeaderMax  = 0.13  // …growing up to this for small folders
	// A folder whose own band would sit right under its parent's and span
	// nearly the same width shares that band instead ("a / b / c"), so
	// chains of one dominant folder don't stack bands.
	headerMergeWidth = 0.88
	colGap           = 4    // chars between text columns
	cardGap          = 0.12 // LayoutCards: share of a card left as air

	// DefaultCharAspect is a monospace glyph's advance / line height with
	// IDE-like line spacing (Consolas: 0.55 em advance, 1.36 em lines).
	DefaultCharAspect = 0.405

	// WorldAspect is the repo rectangle's height/width inside the unit square.
	WorldAspect = 0.625
)

// headerFrac is the header height of a box of kind k with shorter side s,
// relative to s. Folder header bands take a bigger share of small folders,
// so their names become readable a level earlier while zooming in.
func (m *Map) headerFrac(k Kind, s float64) float64 {
	if k == KindDir && m.View.Headers {
		return min(dirHeaderFrac*math.Pow(WorldAspect/max(s, 1e-12), 0.25), dirHeaderMax)
	}
	return headerFrac
}

// Header returns the label strip of a dir or file node: the folder header
// band when View.Headers is on (empty for a folder merged into its
// parent's band).
func (m *Map) Header(id int32) Rect {
	n := &m.Nodes[id]
	if n.InHeader {
		return Rect{}
	}
	s := n.Rect.Min()
	if n.Kind == KindDir && m.View.Headers {
		// the band is the folder's own top edge, not a label floating
		// inside it: no gap between the band and the contour
		return rect(n.Rect.X, n.Rect.Y, n.Rect.W, s*m.headerFrac(n.Kind, s))
	}
	p := s * padFrac
	return rect(n.Rect.X+p, n.Rect.Y+p, n.Rect.W-2*p, s*m.headerFrac(n.Kind, s))
}

// HeaderName is what a folder's header band says: its own name, plus the
// names of the folders merged into it ("e2e / data / wc").
func (m *Map) HeaderName(id int32) string {
	name := m.Nodes[id].Name
	for n := &m.Nodes[id]; n.Kind == KindDir && len(n.Children) > 0; {
		c := &m.Nodes[n.Children[0]]
		if !c.InHeader {
			break
		}
		name += " / " + c.Name
		n = c
	}
	return name
}

// content returns the area below the header where children or text go.
func (m *Map) content(r Rect, k Kind) Rect {
	s := r.Min()
	p := s * padFrac
	h := s * m.headerFrac(k, s)
	if k == KindDir && m.View.Headers {
		return rect(r.X+p, r.Y+h+p, r.W-2*p, max(r.H-h-2*p, 0)) // the band starts at the very top
	}
	return rect(r.X+p, r.Y+p+h, r.W-2*p, max(r.H-2*p-h, 0))
}

// mergesIntoHeader tells whether a child laid out at r starts at the top of
// its parent's content area and spans nearly all of it: its header band
// would then sit right under the parent's, saying almost the same thing.
func mergesIntoHeader(r, inner Rect) bool {
	eps := inner.Min() * 0.02
	return r.Y <= inner.Y+eps && r.X <= inner.X+eps && r.W >= headerMergeWidth*inner.W
}

// contentOf is content for a node: a folder merged into its parent's header
// band keeps no band of its own, so its children start right at its top.
func (m *Map) contentOf(id int32) Rect {
	n := &m.Nodes[id]
	if n.InHeader {
		s := n.Rect.Min()
		p := s * padFrac
		return rect(n.Rect.X+p, n.Rect.Y+p, n.Rect.W-2*p, max(n.Rect.H-2*p, 0))
	}
	return m.content(n.Rect, n.Kind)
}

// Elevation steps, relative to a box's shorter side. Each box stands on its
// parent: top = parent top + step. Steps scale with the box, so the city looks
// the same at every zoom level.
const (
	// With View.EvenSteps every box takes its step from the map instead of
	// from its own size, so height means depth and nothing else.
	evenSide = 0.2 * WorldAspect

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
		if m.View.EvenSteps {
			s = evenSide
		}
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
		inner := m.contentOf(id)
		ws := make([]float64, len(n.Children))
		for i, c := range n.Children {
			ws[i] = m.Nodes[c].Weight
		}
		var rects []Rect
		switch m.View.Algorithm {
		case LayoutStrip:
			rects = treemap.Strip(ws, inner)
		case LayoutRows, LayoutColumns:
			// alternate direction with depth: bands within bands in one
			// direction would shred a deep tree into hairlines
			across := n.Depth%2 == 0
			if m.View.Algorithm == LayoutColumns {
				across = !across
			}
			if across {
				rects = treemap.Rows(ws, inner)
			} else {
				rects = treemap.Columns(ws, inner)
			}
		case LayoutCards:
			if m.View.CardDepth > 0 && int(n.Depth) >= m.View.CardDepth {
				rects = treemap.Squarify(ws, inner) // deeper down, proportions again
			} else {
				rects = treemap.Cards(ws, inner, cardGap)
			}
		default:
			rects = treemap.Squarify(ws, inner)
		}
		for i, c := range n.Children {
			cn := &m.Nodes[c]
			cn.Rect = rects[i]
			// merging bands hides a level, which is the opposite of what
			// KeepChains asks for
			cn.InHeader = m.View.Headers && !m.KeepChains && cn.Kind == KindDir && mergesIntoHeader(rects[i], inner)
			m.layoutNode(c)
		}
	case KindFile:
		m.layoutText(&m.Files[n.File], m.content(n.Rect, KindFile))
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
	f.Gutter = m.Gutter()
	cc := ColChars + int(f.Gutter) // characters per column, gutter included
	bestK, bestLH := 1, 0.0
	// Line height for k columns: lh = min(W / (k*C + (k-1)*gap)*aspect, H / ceil(n/k)).
	// It is unimodal in k, so scan around the continuous optimum.
	charAspect := m.charAspect
	kOpt := math.Sqrt(r.W * float64(n) / (r.H * charAspect * float64(cc+colGap)))
	lo := max(1, int(kOpt)-3)
	hi := min(n, int(kOpt)+3)
	for k := lo; k <= hi; k++ {
		rows := (n + k - 1) / k
		lh := min(r.W/(float64(k*cc+(k-1)*colGap)*charAspect), r.H/float64(rows))
		if lh > bestLH {
			bestK, bestLH = k, lh
		}
	}
	rows := (n + bestK - 1) / bestK
	f.Rows = int32(rows)
	f.Cols = int32((n + rows - 1) / rows)
	f.LH = bestLH
	f.CW = bestLH * charAspect
	f.Stride = float64(cc+colGap) * f.CW
	f.TX, f.TY = r.X, r.Y
}

// Gutter is the width, in characters, reserved left of each text column:
// room for line numbers when they are on, else a little padding so code
// and scope outlines do not touch the box edge.
func (m *Map) Gutter() int32 {
	if m.View.LineNumbers {
		return 7
	}
	return 2
}

// CodeX is the left edge of the code (after the gutter) of column c.
func (f *File) CodeX(c int32) float64 {
	return f.TX + float64(c)*f.Stride + float64(f.Gutter)*f.CW
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
