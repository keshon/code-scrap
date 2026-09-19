// Package treemap lays out weighted items as nested rectangles.
package treemap

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
