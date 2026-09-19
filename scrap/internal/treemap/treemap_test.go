package treemap

import "testing"

// Strip keeps reading order: each item starts right of or below the one
// before it, rows fill the width, and areas match the weights.
func TestStripReadingOrder(t *testing.T) {
	ws := []float64{5, 1, 3, 2, 8, 1, 1, 4}
	r := Rect{0, 0, 2, 1}
	out := Strip(ws, r)
	total := 0.0
	for _, w := range ws {
		total += w
	}
	for i, o := range out {
		want := ws[i] / total * r.W * r.H
		if d := o.W*o.H - want; d > 1e-9 || d < -1e-9 {
			t.Errorf("item %d area %g, want %g", i, o.W*o.H, want)
		}
		if i > 0 {
			p := out[i-1]
			sameRow := o.Y == p.Y
			if sameRow && o.X < p.X+p.W-1e-9 {
				t.Errorf("item %d is not right of item %d", i, i-1)
			}
			if !sameRow && o.Y < p.Y+p.H-1e-9 {
				t.Errorf("item %d starts a row above item %d", i, i-1)
			}
		}
	}
	last := out[len(out)-1]
	if d := last.Y + last.H - (r.Y + r.H); d > 1e-9 || d < -1e-9 {
		t.Errorf("rows do not fill the height: %g", last.Y+last.H)
	}
}
