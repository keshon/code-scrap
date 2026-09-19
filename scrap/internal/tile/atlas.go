package tile

import (
	"image"
	"image/draw"
	"math"
	"os"
	"path/filepath"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gomono"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// Atlas is a grid of monospace glyphs rendered once, for GPU text: the
// viewer draws every character of every visible file by sampling it.
// Index 0 is always blank (space); unknown runes map to '?'.
type Atlas struct {
	Font         string // font file used ("" = embedded Go Mono)
	Cols, Rows   int    // grid size in cells
	CellW, CellH int    // cell size in pixels; CellW/CellH matches the text layout's char aspect
	Runes        []rune // rune of each cell index
	Pix          []byte // L8 coverage, (Cols*CellW) × (Rows*CellH)

	index map[rune]uint16
}

// Cell geometry: 96 px lines give crisp text up to ~100 px on screen.
const (
	atlasCols  = 32
	atlasCellH = 96
)

// Font files tried in order when none is given: the coding fonts IDEs use
// on each platform. Their licenses allow local use, so they are loaded from
// the system, never bundled.
var defaultFonts = []string{
	`C:\Windows\Fonts\consola.ttf`, // Consolas — VS Code's default on Windows
	`C:\Windows\Fonts\CascadiaMono.ttf`,
	`C:\Windows\Fonts\CascadiaCode.ttf`,
	"/System/Library/Fonts/Menlo.ttc",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

func atlasRunes() []rune {
	rs := []rune{' '}
	add := func(lo, hi rune) {
		for r := lo; r <= hi; r++ {
			rs = append(rs, r)
		}
	}
	add(0x21, 0x7E)     // ASCII
	add(0xA1, 0xFF)     // Latin-1
	add(0x400, 0x45F)   // Cyrillic
	add(0x2010, 0x2027) // dashes, quotes, bullets, ellipsis
	add(0x2190, 0x2193) // arrows
	add(0x2500, 0x257F) // box drawing
	return rs
}

// LoadAtlas renders the glyph atlas from fontPath, or from the first
// available default font, falling back to the embedded Go Mono.
func LoadAtlas(fontPath string) (*Atlas, error) {
	var data []byte
	used := ""
	paths := defaultFonts
	if fontPath != "" {
		paths = []string{fontPath}
	}
	for _, p := range paths {
		if b, err := os.ReadFile(p); err == nil {
			data, used = b, p
			break
		}
	}
	if data == nil {
		data = gomono.TTF
	}
	f, err := opentype.Parse(data)
	if err != nil {
		if fontPath != "" {
			return nil, err
		}
		f, _ = opentype.Parse(gomono.TTF)
		used = ""
	}

	// Size the font so a line is CellH tall with IDE-like spacing
	// (line height ≈ 1.36 × font size), and the cell is one advance wide.
	size := float64(atlasCellH) / 1.36
	face, err := opentype.NewFace(f, &opentype.FaceOptions{Size: size, DPI: 72, Hinting: font.HintingNone})
	if err != nil {
		return nil, err
	}
	defer face.Close()
	adv, _ := face.GlyphAdvance('M')
	cellW := int(math.Ceil(float64(adv) / 64))
	m := face.Metrics()
	ascent := float64(m.Ascent) / 64
	descent := float64(m.Descent) / 64
	baseline := (float64(atlasCellH)-(ascent+descent))/2 + ascent

	runes := atlasRunes()
	a := &Atlas{Font: filepath.Base(used), Cols: atlasCols, CellW: cellW, CellH: atlasCellH, Runes: runes, index: map[rune]uint16{}}
	a.Rows = (len(runes) + atlasCols - 1) / atlasCols
	img := image.NewAlpha(image.Rect(0, 0, a.Cols*cellW, a.Rows*atlasCellH))
	for i, r := range runes {
		a.index[r] = uint16(i)
		if r == ' ' {
			continue
		}
		cx, cy := (i%atlasCols)*cellW, (i/atlasCols)*atlasCellH
		dot := fixed.P(cx, cy+int(math.Round(baseline)))
		dr, mask, mp, _, ok := face.Glyph(dot, r)
		if !ok {
			continue
		}
		clip := dr.Intersect(image.Rect(cx, cy, cx+cellW, cy+atlasCellH))
		draw.DrawMask(img, clip, image.Opaque, image.Point{}, mask, mp.Add(clip.Min.Sub(dr.Min)), draw.Over)
	}
	a.Pix = img.Pix
	return a, nil
}

// Index returns the cell of r ('?' for runes outside the atlas).
func (a *Atlas) Index(r rune) uint16 {
	if i, ok := a.index[r]; ok {
		return i
	}
	if r == '\t' {
		return 0
	}
	return a.index['?']
}

// CharAspect is the glyph cell's width / height, which the layout must use
// so text columns line up with the atlas.
func (a *Atlas) CharAspect() float64 { return float64(a.CellW) / float64(a.CellH) }
