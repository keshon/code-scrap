package tile

import (
	"image"
	"image/draw"
	"sync"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gomono"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// Glyphs caches rasterized Go Mono glyph masks per pixel size.
type Glyphs struct {
	font *opentype.Font

	mu    sync.RWMutex
	faces map[int]*sizedFace
}

type glyph struct {
	mask *image.Alpha
	off  image.Point // mask origin relative to the pen position on the baseline
}

type sizedFace struct {
	mu     sync.Mutex // opentype faces are not safe for concurrent use
	face   font.Face
	glyphs sync.Map // rune → *glyph
}

// NewGlyphs parses the embedded Go Mono font.
func NewGlyphs() *Glyphs {
	f, err := opentype.Parse(gomono.TTF)
	if err != nil {
		panic(err)
	}
	return &Glyphs{font: f, faces: map[int]*sizedFace{}}
}

func (g *Glyphs) face(size int) *sizedFace {
	g.mu.RLock()
	sf := g.faces[size]
	g.mu.RUnlock()
	if sf != nil {
		return sf
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if sf = g.faces[size]; sf != nil {
		return sf
	}
	face, err := opentype.NewFace(g.font, &opentype.FaceOptions{Size: float64(size), DPI: 72, Hinting: font.HintingFull})
	if err != nil {
		panic(err)
	}
	sf = &sizedFace{face: face}
	g.faces[size] = sf
	return sf
}

// Get returns the mask for r at the given pixel size (nil for blanks).
func (g *Glyphs) Get(size int, r rune) *glyph {
	sf := g.face(size)
	if v, ok := sf.glyphs.Load(r); ok {
		return v.(*glyph)
	}
	sf.mu.Lock()
	dr, mask, mp, _, ok := sf.face.Glyph(fixed.P(0, 0), r)
	var gl *glyph
	if ok && !dr.Empty() {
		a := image.NewAlpha(image.Rect(0, 0, dr.Dx(), dr.Dy()))
		draw.Draw(a, a.Bounds(), mask, mp, draw.Src)
		gl = &glyph{mask: a, off: dr.Min}
	}
	sf.mu.Unlock()
	sf.glyphs.Store(r, gl)
	return gl
}
