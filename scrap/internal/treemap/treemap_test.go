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

func TestRowsAndColumns(t *testing.T) {
	r := Rect{0, 0, 100, 60}
	rows := Rows([]float64{3, 1}, r)
	if rows[0] != (Rect{0, 0, 100, 45}) || rows[1] != (Rect{0, 45, 100, 15}) {
		t.Errorf("rows %v", rows)
	}
	cols := Columns([]float64{1, 1}, r)
	if cols[0] != (Rect{0, 0, 50, 60}) || cols[1] != (Rect{50, 0, 50, 60}) {
		t.Errorf("columns %v", cols)
	}
	if got := Rows([]float64{0, 0}, r); got[0] != (Rect{}) {
		t.Errorf("weightless rows %v", got)
	}
}

func TestCards(t *testing.T) {
	r := Rect{0, 0, 120, 90}
	got := Cards([]float64{5, 4, 3, 2, 1, 1}, r, 0.1)
	// same card for everyone, laid out in reading order, inside r
	first := got[0]
	for i, c := range got {
		if c.W <= 0 || c.H <= 0 {
			t.Fatalf("card %d empty: %v", i, c)
		}
		if c.W != first.W || c.H != first.H {
			t.Errorf("card %d is %v, want the size of %v", i, c, first)
		}
		if c.X < r.X || c.Y < r.Y || c.X+c.W > r.X+r.W+1e-9 || c.Y+c.H > r.Y+r.H+1e-9 {
			t.Errorf("card %d outside: %v", i, c)
		}
	}
	if !(got[1].X > got[0].X && got[1].Y == got[0].Y) {
		t.Errorf("cards should read left to right: %v %v", got[0], got[1])
	}
	if got[0].X <= r.X {
		t.Error("cards should have air around them")
	}
}
