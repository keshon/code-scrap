// Package treemap lays out weighted items as nested rectangles.
package treemap

import "math"

// Rect is an axis-aligned rectangle.
type Rect struct{ X, Y, W, H float64 }

func (r Rect) Contains(x, y float64) bool {
	return x >= r.X && y >= r.Y && x < r.X+r.W && y < r.Y+r.H
}

func (r Rect) Intersects(o Rect) bool {
	return r.X < o.X+o.W && o.X < r.X+r.W && r.Y < o.Y+o.H && o.Y < r.Y+r.H
}

// Min returns the shorter side.
func (r Rect) Min() float64 { return min(r.W, r.H) }

// Inset shrinks the rect by d on every side (never below zero size).
func (r Rect) Inset(d float64) Rect {
	d = min(d, r.W/2, r.H/2)
	return Rect{r.X + d, r.Y + d, r.W - 2*d, r.H - 2*d}
}

// Squarify lays out weights inside r using the squarified algorithm
// (Bruls, Huizing, van Wijk). Items are placed in the order given, so callers
// choose between best aspect ratios (sort by weight, descending) and stable
// placement (sort by name). Zero or negative weights get an empty rect.
func Squarify(weights []float64, r Rect) []Rect {
	out := make([]Rect, len(weights))
	total := 0.0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	if total <= 0 || r.W <= 0 || r.H <= 0 {
		return out
	}
	scale := r.W * r.H / total // area per unit weight

	idx := make([]int, 0, len(weights))
	for i, w := range weights {
		if w > 0 {
			idx = append(idx, i)
		}
	}
	free := r
	for len(idx) > 0 {
		side := free.Min()
		// grow the row while the worst aspect ratio improves
		n := 1
		sum := weights[idx[0]] * scale
		best := worst(weights, idx[:1], sum, side, scale)
		for n < len(idx) {
			s2 := sum + weights[idx[n]]*scale
			w2 := worst(weights, idx[:n+1], s2, side, scale)
			if w2 > best {
				break
			}
			n, sum, best = n+1, s2, w2
		}
		if n == len(idx) { // last row takes the remaining space exactly
			sum = free.W * free.H
		}
		thick := sum / side
		pos := 0.0
		rowSum := 0.0
		for _, i := range idx[:n] {
			rowSum += weights[i]
		}
		for _, i := range idx[:n] {
			l := side * weights[i] / rowSum
			if free.W >= free.H { // row is a vertical strip on the left
				out[i] = Rect{free.X, free.Y + pos, thick, l}
			} else { // row is a horizontal strip on top
				out[i] = Rect{free.X + pos, free.Y, l, thick}
			}
			pos += l
		}
		if free.W >= free.H {
			free = Rect{free.X + thick, free.Y, max(free.W-thick, 0), free.H}
		} else {
			free = Rect{free.X, free.Y + thick, free.W, max(free.H-thick, 0)}
		}
		idx = idx[n:]
	}
	return out
}

// Strip lays out weights inside r in reading order (Bederson's strip
// treemap): horizontal rows from top to bottom, items left to right in the
// order given. A row grows while its average aspect ratio improves. The
// result reads like text, at the cost of somewhat longer boxes than
// Squarify.
func Strip(weights []float64, r Rect) []Rect {
	out := make([]Rect, len(weights))
	total := 0.0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	if total <= 0 || r.W <= 0 || r.H <= 0 {
		return out
	}
	scale := r.W * r.H / total
	idx := make([]int, 0, len(weights))
	for i, w := range weights {
		if w > 0 {
			idx = append(idx, i)
		}
	}
	avg := func(row []int, sum float64) float64 {
		h := sum / r.W
		a := 0.0
		for _, i := range row {
			w := weights[i] * scale / h
			a += max(w/h, h/w)
		}
		return a / float64(len(row))
	}
	y := r.Y
	for len(idx) > 0 {
		n := 1
		sum := weights[idx[0]] * scale
		best := avg(idx[:1], sum)
		for n < len(idx) {
			s2 := sum + weights[idx[n]]*scale
			a2 := avg(idx[:n+1], s2)
			if a2 > best {
				break
			}
			n, sum, best = n+1, s2, a2
		}
		h := sum / r.W
		if n == len(idx) { // the last row takes the remaining height exactly
			h = r.Y + r.H - y
		}
		x := r.X
		rowSum := 0.0
		for _, i := range idx[:n] {
			rowSum += weights[i]
		}
		for _, i := range idx[:n] {
			w := r.W * weights[i] / rowSum
			out[i] = Rect{x, y, w, h}
			x += w
		}
		y += h
		idx = idx[n:]
	}
	return out
}

func worst(weights []float64, row []int, sum, side, scale float64) float64 {
	thick := sum / side
	w := 0.0
	for _, i := range row {
		l := weights[i] * scale / thick
		a := max(l/thick, thick/l)
		w = max(w, a)
	}
	return w
}

// Rows lays the weights out as full-width bands, in order, each as tall as
// its share of r. Reading order is plain: top to bottom, no winding.
func Rows(weights []float64, r Rect) []Rect {
	return bands(weights, r, false)
}

// Columns is Rows turned ninety degrees: full-height columns, left to right.
func Columns(weights []float64, r Rect) []Rect {
	return bands(weights, r, true)
}

func bands(weights []float64, r Rect, vertical bool) []Rect {
	out := make([]Rect, len(weights))
	total := 0.0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	if total <= 0 || r.W <= 0 || r.H <= 0 {
		return out
	}
	at := 0.0
	for i, w := range weights {
		if w <= 0 {
			continue
		}
		if vertical {
			d := r.W * w / total
			out[i] = Rect{r.X + at, r.Y, d, r.H}
			at += d
			continue
		}
		d := r.H * w / total
		out[i] = Rect{r.X, r.Y + at, r.W, d}
		at += d
	}
	return out
}

// Cards lays the items out as a grid of equal cards with air between them,
// in the order given. Size stops carrying weight here — every item gets the
// same card — which is exactly what makes a folder's contents countable
// instead of a mosaic. gap is the share of a cell left empty (0.1 = 10%).
func Cards(weights []float64, r Rect, gap float64) []Rect {
	out := make([]Rect, len(weights))
	n := 0
	for _, w := range weights {
		if w > 0 {
			n++
		}
	}
	if n == 0 || r.W <= 0 || r.H <= 0 {
		return out
	}
	// pick the column count whose cells come closest to a 4:3 card
	cols, best := 1, math.Inf(1)
	for c := 1; c <= n; c++ {
		rows := (n + c - 1) / c
		cw, ch := r.W/float64(c), r.H/float64(rows)
		if cw <= 0 || ch <= 0 {
			continue
		}
		if d := math.Abs(math.Log(cw / ch * 3 / 4)); d < best {
			cols, best = c, d
		}
	}
	rows := (n + cols - 1) / cols
	cw, ch := r.W/float64(cols), r.H/float64(rows)
	pad := gap * 0.5 * min(cw, ch)
	i := 0
	for k, w := range weights {
		if w <= 0 {
			continue
		}
		c, row := i%cols, i/cols
		out[k] = Rect{r.X + float64(c)*cw + pad, r.Y + float64(row)*ch + pad,
			max(cw-2*pad, 0), max(ch-2*pad, 0)}
		i++
	}
	return out
}
