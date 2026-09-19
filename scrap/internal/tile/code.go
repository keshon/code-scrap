package tile

import (
	"image"
	"image/color"
	"math"
	"unicode/utf8"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

// Line-height thresholds in pixels.
const (
	minCodePx   = 0.35 // below: files show no line texture
	glyphCodePx = 7    // at or above: real glyphs instead of dashes
)

// Renderer produces text data for one map: GPU text blocks for the viewers,
// and raster code tiles for previews.
type Renderer struct {
	Map    *codemap.Map
	Texts  *Texts
	Glyphs *Glyphs
	Atlas  *Atlas
}

// NewRenderer creates a renderer with a text cache of the given size.
func NewRenderer(m *codemap.Map, atlas *Atlas, textCacheBytes int) *Renderer {
	return &Renderer{Map: m, Texts: NewTexts(m, textCacheBytes), Glyphs: NewGlyphs(), Atlas: atlas}
}

// Code renders the code layer of tile k as a transparent RGBA image, or
// returns nil when the tile holds no visible code.
func (r *Renderer) Code(k Key) *image.RGBA {
	m := r.Map
	tr := k.Rect()
	scale := k.Scale()
	var img *image.RGBA
	ensure := func() *image.RGBA {
		if img == nil {
			img = image.NewRGBA(image.Rect(0, 0, Px, Px))
		}
		return img
	}
	var visit func(id int32)
	visit = func(id int32) {
		n := &m.Nodes[id]
		if !n.Rect.Intersects(tr) || n.Rect.W*scale < 2 || n.Rect.H*scale < 2 {
			return
		}
		switch n.Kind {
		case codemap.KindDir:
			for _, c := range n.Children {
				visit(c)
			}
		case codemap.KindFile:
			f := &m.Files[n.File]
			if f.Rows > 0 && f.LH*scale >= minCodePx && !f.Class.Has(codemap.ClassBinary) {
				r.drawFile(ensure, f, tr, scale)
			}
		}
	}
	visit(0)
	return img
}

func (r *Renderer) drawFile(ensure func() *image.RGBA, f *codemap.File, tr codemap.Rect, scale float64) {
	src := r.Texts.Get(r.Map.Nodes[f.Node].File)
	if src == nil {
		return
	}
	lhPx := f.LH * scale
	c0 := max(0, int32(math.Floor((tr.X-f.TX)/f.Stride)))
	c1 := min(f.Cols-1, int32(math.Floor((tr.X+tr.W-f.TX)/f.Stride)))
	r0 := max(0, int32(math.Floor((tr.Y-f.TY)/f.LH)))
	r1 := min(f.Rows-1, int32(math.Floor((tr.Y+tr.H-f.TY)/f.LH)))
	if c0 > c1 || r0 > r1 {
		return
	}
	img := ensure()
	glyphMode := lhPx >= glyphCodePx
	size := int(math.Round(lhPx * 0.82))
	cwPx := f.CW * scale
	for c := c0; c <= c1; c++ {
		colX := (f.TX + float64(c)*f.Stride - tr.X) * scale
		for row := r0; row <= r1; row++ {
			line := c*f.Rows + row
			if int(line) >= len(src.Lines) {
				break
			}
			top := (f.TY + float64(row)*f.LH - tr.Y) * scale
			text := src.Lines[line]
			for _, s := range src.Segs[line] {
				if int(s.Col) >= codemap.ColChars {
					break
				}
				n := min(int(s.Len), codemap.ColChars-int(s.Col))
				col := classColors[s.Cls]
				if !glyphMode {
					x0 := colX + float64(s.Col)*cwPx
					fillRect(img, x0, top+0.2*lhPx, x0+float64(n)*cwPx, top+0.8*lhPx, col, 0.85)
					continue
				}
				baseline := int(math.Round(top + 0.78*lhPx))
				ci := int(s.Col)
				for bi := int(s.Col); bi < int(s.Col)+n && bi < len(text); {
					ru, w := utf8.DecodeRuneInString(text[bi:])
					if ru != ' ' {
						if g := r.Glyphs.Get(size, ru); g != nil {
							x := int(math.Round(colX + float64(ci)*cwPx))
							drawMask(img, g, x, baseline, col)
						}
					}
					bi += w
					ci++
				}
			}
		}
	}
}

// fillRect blends a rectangle with anti-aliased (fractional) edges.
func fillRect(img *image.RGBA, x0, y0, x1, y1 float64, c color.NRGBA, alpha float64) {
	x0, y0 = max(x0, 0), max(y0, 0)
	x1, y1 = min(x1, Px), min(y1, Px)
	if x1 <= x0 || y1 <= y0 {
		return
	}
	for py := int(y0); py < int(math.Ceil(y1)); py++ {
		cy := min(y1, float64(py+1)) - max(y0, float64(py))
		for px := int(x0); px < int(math.Ceil(x1)); px++ {
			cx := min(x1, float64(px+1)) - max(x0, float64(px))
			blend(img, px, py, c, alpha*cx*cy)
		}
	}
}

func drawMask(img *image.RGBA, g *glyph, x, y int, c color.NRGBA) {
	b := g.mask.Bounds()
	ox, oy := x+g.off.X, y+g.off.Y
	for my := 0; my < b.Dy(); my++ {
		py := oy + my
		if py < 0 || py >= Px {
			continue
		}
		for mx := 0; mx < b.Dx(); mx++ {
			px := ox + mx
			if px < 0 || px >= Px {
				continue
			}
			if a := g.mask.Pix[my*g.mask.Stride+mx]; a != 0 {
				blend(img, px, py, c, float64(a)/255)
			}
		}
	}
}

// blend composites c with coverage a over the premultiplied pixel.
func blend(img *image.RGBA, x, y int, c color.NRGBA, a float64) {
	if a <= 0 {
		return
	}
	a = min(a, 1)
	i := img.PixOffset(x, y)
	p := img.Pix[i : i+4 : i+4]
	inv := 1 - a
	p[0] = uint8(float64(c.R)*a + float64(p[0])*inv)
	p[1] = uint8(float64(c.G)*a + float64(p[1])*inv)
	p[2] = uint8(float64(c.B)*a + float64(p[2])*inv)
	p[3] = uint8(255*a + float64(p[3])*inv)
}
