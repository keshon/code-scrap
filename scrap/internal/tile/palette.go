package tile

import (
	"image/color"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/syntax"
)

// Area hues: soft pastels that read well as thin outlines on near-black.
var hues = [16][3]float32{
	{0.45, 0.85, 0.76}, // teal
	{0.68, 0.62, 0.96}, // lavender
	{0.96, 0.58, 0.52}, // salmon
	{0.74, 0.86, 0.42}, // lime
	{0.48, 0.72, 0.97}, // sky
	{0.96, 0.80, 0.42}, // gold
	{0.93, 0.56, 0.80}, // pink
	{0.97, 0.67, 0.44}, // orange
	{0.55, 0.90, 0.58}, // mint
	{0.60, 0.78, 0.92}, // steel
	{0.88, 0.70, 0.95}, // orchid
	{0.92, 0.88, 0.55}, // sand
	{0.50, 0.84, 0.92}, // cyan
	{0.95, 0.66, 0.66}, // rose
	{0.70, 0.80, 0.60}, // sage
	{0.80, 0.72, 0.62}, // tan
}

var (
	neutral = [3]float32{0.62, 0.66, 0.74}
	grey    = [3]float32{0.50, 0.52, 0.56}
)

// heatColor maps 0..1 to a perceptual cold→hot ramp (blue, teal, yellow,
// orange, red), readable as outlines on a dark background.
func heatColor(t float32) [3]float32 {
	stops := [...][3]float32{
		{0.30, 0.45, 0.85}, {0.25, 0.75, 0.75}, {0.90, 0.85, 0.35}, {0.97, 0.55, 0.25}, {0.95, 0.25, 0.30},
	}
	t = min(max(t, 0), 1) * float32(len(stops)-1)
	i := min(int(t), len(stops)-2)
	return mix(stops[i], stops[i+1], t-float32(i))
}

// BoxColor is the outline color of a node; the viewer derives the fill.
func BoxColor(m *codemap.Map, n *codemap.Node) [4]float32 {
	if m.View.Color != "" && m.View.Color != codemap.ColorArea {
		switch {
		case n.Kind == codemap.KindDir:
			return [4]float32{0.36, 0.38, 0.44, 1}
		case n.Heat < 0:
			return [4]float32{0.30, 0.31, 0.34, 1} // no value: recede
		}
		c := heatColor(n.Heat)
		if n.Kind == codemap.KindScope {
			c = mix(c, [3]float32{1, 1, 1}, 0.25)
		}
		return [4]float32{c[0], c[1], c[2], 1}
	}
	c := neutral
	if n.Hue != codemap.HueNeutral {
		c = hues[n.Hue%16]
	}
	if n.Kind != codemap.KindDir {
		f := &m.Files[n.File]
		switch {
		case f.Class.Has(codemap.ClassBinary | codemap.ClassData):
			c = grey
		case f.Class.Has(codemap.ClassVendored | codemap.ClassMinified):
			c = mix(c, grey, 0.6)
		}
	}
	if n.Kind == codemap.KindScope {
		c = mix(c, [3]float32{1, 1, 1}, 0.25)
	}
	return [4]float32{c[0], c[1], c[2], 1}
}

func mix(a, b [3]float32, t float32) [3]float32 {
	return [3]float32{a[0] + (b[0]-a[0])*t, a[1] + (b[1]-a[1])*t, a[2] + (b[2]-a[2])*t}
}

// Syntax colors, indexed by token class.
var classColors = [syntax.NumClasses]color.NRGBA{
	syntax.ClsText:    {0xc9, 0xd1, 0xd9, 0xff},
	syntax.ClsKeyword: {0x7a, 0xa2, 0xf7, 0xff},
	syntax.ClsString:  {0xe3, 0x9a, 0x7f, 0xff},
	syntax.ClsComment: {0x6e, 0x76, 0x81, 0xff},
	syntax.ClsNumber:  {0xd7, 0xa6, 0x5f, 0xff},
	syntax.ClsType:    {0x7f, 0xd1, 0xb9, 0xff},
	syntax.ClsPunct:   {0x8b, 0x94, 0x9e, 0xff},
	syntax.ClsPreproc: {0xc4, 0x9b, 0xff, 0xff},
	syntax.ClsFunc:    {0xe5, 0xc0, 0x7b, 0xff},
}
