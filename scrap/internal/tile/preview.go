package tile

import (
	"image"
	"image/color"
	"math"
)

// Preview composites a full tile (boxes, code, labels) into one opaque image,
// approximating what the viewer's box shader draws. It is used for
// debugging and thumbnails; viewers draw boxes themselves.
func (r *Renderer) Preview(k Key) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, Px, Px))
	bg := color.NRGBA{0x16, 0x17, 0x1b, 0xff}
	fillRect(img, 0, 0, Px, Px, bg, 1)
	b := BoxTile(r.Map, k)
	for i := 0; i < len(b.IDs); i++ {
		v := b.Instances[i*16 : i*16+16]
		w, x, h, y := float64(v[0]), float64(v[3]), float64(v[5]), float64(v[7])
		c := color.NRGBA{uint8(v[8] * 255), uint8(v[9] * 255), uint8(v[10] * 255), 255}
		edges, kind := int(v[12]), int(v[13])
		truePx := float64(v[15]) * w * Px
		x0, y0, x1, y1 := x*Px, y*Px, (x+w)*Px, (y+h)*Px
		// small boxes: solid-ish fill; large boxes: dark fill + outline
		t := smooth(8, 80, truePx)
		if kind != 2 {
			fill := color.NRGBA{uint8(float64(c.R) * (0.55 - 0.45*t)), uint8(float64(c.G) * (0.55 - 0.45*t)), uint8(float64(c.B) * (0.55 - 0.45*t)), 255}
			fillRect(img, x0, y0, x1, y1, fill, 1)
		}
		oa := smooth(3, 8, truePx)
		if kind == 2 {
			oa *= 0.5
		}
		if edges&1 != 0 {
			fillRect(img, x0, y0, x0+1, y1, c, oa)
		}
		if edges&2 != 0 {
			fillRect(img, x0, y0, x1, y0+1, c, oa)
		}
		if edges&4 != 0 {
			fillRect(img, x1-1, y0, x1, y1, c, oa)
		}
		if edges&8 != 0 {
			fillRect(img, x0, y1-1, x1, y1, c, oa)
		}
	}
	if code := r.Code(k); code != nil {
		for i := 0; i < len(code.Pix); i += 4 {
			a := float64(code.Pix[i+3]) / 255
			if a == 0 {
				continue
			}
			for j := 0; j < 3; j++ {
				img.Pix[i+j] = uint8(float64(code.Pix[i+j]) + float64(img.Pix[i+j])*(1-a))
			}
		}
	}
	white := color.NRGBA{0xee, 0xee, 0xee, 0xff}
	pill := color.NRGBA{0x10, 0x10, 0x12, 0xff}
	for _, l := range b.Labels {
		x, y := float64(l.X)*Px, float64(l.Y)*Px
		if x < -Px || y < -Px || x > Px || y > Px {
			continue
		}
		size := 11
		if l.Kind == 2 {
			size = max(8, min(11, int(float64(l.H)*Px*0.8)))
		}
		cw := float64(size) * 0.6
		maxChars := int(float64(l.W)*Px/cw) - 1
		text := []rune(l.Text)
		if maxChars < 3 {
			continue
		}
		if len(text) > maxChars {
			text = append(text[:maxChars-1], '…')
		}
		fillRect(img, x+2, y+1, x+4+float64(len(text))*cw+2, y+float64(size)+4, pill, 0.85)
		for i, ru := range text {
			if g := r.Glyphs.Get(size, ru); g != nil {
				drawMask(img, g, int(math.Round(x+4+float64(i)*cw)), int(y)+size+1, white)
			}
		}
	}
	return img
}

func smooth(e0, e1, x float64) float64 {
	t := min(max((x-e0)/(e1-e0), 0), 1)
	return t * t * (3 - 2*t)
}
