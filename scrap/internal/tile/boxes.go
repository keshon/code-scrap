// Package tile renders the code map as a pyramid of map tiles: vector box
// tiles (instance buffers ready for a Godot MultiMesh) and raster code tiles
// (line dashes when far, glyphs when near). Viewers only stream and draw.
package tile

import (
	"math"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

// Px is the nominal edge length of a tile in pixels.
const Px = 256

// MaxZ is the deepest zoom level served.
const MaxZ = 24

// Key addresses one tile: level Z covers the unit square with 2^Z × 2^Z tiles.
type Key struct{ Z, X, Y int }

// Rect is the tile's world rectangle.
func (k Key) Rect() codemap.Rect {
	s := 1 / math.Exp2(float64(k.Z))
	return codemap.Rect{X: float64(k.X) * s, Y: float64(k.Y) * s, W: s, H: s}
}

// Scale is pixels per world unit at the tile's level.
func (k Key) Scale() float64 { return Px * math.Exp2(float64(k.Z)) }

// Label is a text label placed in tile-local units (0..1 spans the tile).
type Label struct {
	ID         int32
	Kind       uint8    // 0 dir, 1 file, 2 scope; a scope's kind (syntax.ScopeKind) in the high nibble
	Color      [3]uint8 // the box's outline color
	X, Y, W, H float32
	Top        float32 // 3D: roof height of the labelled box
	Text       string
}

// Boxes is one vector tile.
type Boxes struct {
	// Instances holds one box per Stride float32s, in Godot's MultiMesh
	// buffer layout with colors and custom data. 2D (Stride 16):
	//   [w 0 0 x   0 h 0 y   r g b a   edges kind depth trueMin/w]
	// 3D (Stride 20), for a unit cube spanning [0,1]³, map Y → world Z:
	//   [w 0 0 x   0 top 0 0   0 0 h y   r g b a   edges kind depth trueMin/w]
	// Coordinates are tile-local (0..1). "edges" is a bitmask of the box's
	// real edges inside this tile (1 left, 2 top, 4 right, 8 bottom), so
	// outlines of boxes clipped at tile borders stay seamless.
	Instances []float32
	Stride    int
	IDs       []int32
	Labels    []Label
	Blocks    []Block
	is3D      bool
}

const (
	minBoxPx         = 1.5 // smaller boxes are culled
	minLabelPx       = 22  // shorter boxes get no label
	minHeaderLabelPx = 8   // folder header bands lower than this carry no name
)

// KindHeader is the instance kind of a folder header band (2D, View.Headers).
const KindHeader = 4

// BoxTile builds the vector tile for k, flat (2D) or extruded (3D).
func BoxTile(m *codemap.Map, k Key, is3D bool) *Boxes {
	b := &Boxes{Stride: 16, is3D: is3D}
	if is3D {
		b.Stride = 20
	}
	tr := k.Rect()
	scale := k.Scale()
	var visit func(id int32)
	visit = func(id int32) {
		n := &m.Nodes[id]
		r := n.Rect
		if !r.Intersects(tr) || r.W*scale < minBoxPx || r.H*scale < minBoxPx {
			return
		}
		if id != 0 { // the root box is the canvas, not drawn…
			b.add(m, id, r, tr, scale)
		} else if m.View.Headers && !is3D {
			b.header(m, id, tr, scale) // …but it has a header band like any folder
		}
		switch n.Kind {
		case codemap.KindDir:
			for _, c := range n.Children {
				visit(c)
			}
		case codemap.KindFile:
			f := &m.Files[n.File]
			b.blocks(m, n, f, tr, scale)
			if f.LH*scale >= 1.2 {
				for _, sid := range f.Scopes {
					b.addScope(m, sid, f, tr, scale)
				}
			}
		}
	}
	visit(0)
	return b
}

func (b *Boxes) add(m *codemap.Map, id int32, r, tr codemap.Rect, scale float64) {
	n := &m.Nodes[id]
	c := BoxColor(m, n)
	b.push(r, tr, c, float32(n.Kind), float32(n.Depth), n.Top, id)
	headers := m.View.Headers && n.Kind == codemap.KindDir && !b.is3D
	if headers {
		b.header(m, id, tr, scale)
		return
	}
	if r.Min()*scale >= minLabelPx {
		h := m.Header(id)
		if b.is3D {
			// 3D labels get the whole box: folder names go on the wall that
			// faces the camera, file names on the roof (header strip or
			// middle, as the viewer is set)
			h = r
		}
		b.label(id, uint8(n.Kind), c, h, n.Top, tr, n.Name)
	}
}

// header adds a folder's header band — its own instance, so tiles cutting
// through a header still paint it whole — and its name label spanning it.
func (b *Boxes) header(m *codemap.Map, id int32, tr codemap.Rect, scale float64) {
	n := &m.Nodes[id]
	h := m.Header(id)
	if h.H*scale < 1 {
		return
	}
	c := BoxColor(m, n)
	b.push(h, tr, c, KindHeader, float32(n.Depth), n.Top, id)
	if h.H*scale >= minHeaderLabelPx {
		b.label(id, uint8(n.Kind), c, h, n.Top, tr, n.Name)
	}
}

func (b *Boxes) addScope(m *codemap.Map, sid int32, f *codemap.File, tr codemap.Rect, scale float64) {
	s := &m.Nodes[sid]
	if !s.Rect.Intersects(tr) {
		return
	}
	depthInFile := float64(s.Depth - m.Nodes[f.Node].Depth - 1)
	col := BoxColor(m, s)
	for i, seg := range f.Segments(s.StartLine, s.EndLine, depthInFile*0.5*f.CW) {
		if !seg.Intersects(tr) || seg.H*scale < minBoxPx {
			continue
		}
		// scopes: kind 2 + scope kind / 10, depth = nesting inside the file
		b.push(seg, tr, col, 2+float32(s.Scope)*0.1, float32(depthInFile), s.Top, sid)
		if i == 0 && f.LH*scale >= 6 && seg.H*scale >= 3*f.LH*scale {
			lh := codemap.Rect{X: seg.X + f.CW, Y: seg.Y - 0.55*f.LH, W: seg.W - f.CW, H: 0.9 * f.LH}
			b.label(sid, 2|uint8(s.Scope)<<4, col, lh, s.Top, tr, s.Name)
		}
	}
}

func (b *Boxes) push(r, tr codemap.Rect, c [4]float32, kind, depth float32, top float64, id int32) {
	x0, y0 := max(r.X, tr.X), max(r.Y, tr.Y)
	x1, y1 := min(r.X+r.W, tr.X+tr.W), min(r.Y+r.H, tr.Y+tr.H)
	if x1 <= x0 || y1 <= y0 {
		return
	}
	var edges float32
	if r.X >= tr.X {
		edges += 1
	}
	if r.Y >= tr.Y {
		edges += 2
	}
	if r.X+r.W <= tr.X+tr.W {
		edges += 4
	}
	if r.Y+r.H <= tr.Y+tr.H {
		edges += 8
	}
	inv := 1 / tr.W
	w := float32((x1 - x0) * inv)
	h := float32((y1 - y0) * inv)
	x := float32((x0 - tr.X) * inv)
	y := float32((y0 - tr.Y) * inv)
	trueMin := float32(r.Min() * inv)
	if b.is3D {
		b.Instances = append(b.Instances,
			w, 0, 0, x,
			0, max(float32(top*inv), 1e-6), 0, 0,
			0, 0, h, y)
	} else {
		b.Instances = append(b.Instances,
			w, 0, 0, x,
			0, h, 0, y)
	}
	b.Instances = append(b.Instances,
		c[0], c[1], c[2], c[3],
		edges, kind, depth, trueMin/w)
	b.IDs = append(b.IDs, id)
}

func (b *Boxes) label(id int32, kind uint8, c [4]float32, r codemap.Rect, top float64, tr codemap.Rect, text string) {
	inv := 1 / tr.W
	b.Labels = append(b.Labels, Label{
		ID: id, Kind: kind, Text: text, Color: [3]uint8{uint8(c[0] * 255), uint8(c[1] * 255), uint8(c[2] * 255)}, Top: float32(top * inv),
		X: float32((r.X - tr.X) * inv), Y: float32((r.Y - tr.Y) * inv),
		W: float32(r.W * inv), H: float32(r.H * inv),
	})
}
