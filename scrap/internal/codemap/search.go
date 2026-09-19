package codemap

import (
	"cmp"
	"math"
	"slices"
	"sort"
	"strings"
)

// SearchResult is one page of symbol hits, grouped by file path.
type SearchResult struct {
	Total int      // all matching symbols (capped at maxHits)
	More  bool     // Total was capped
	Hits  []Symbol // the requested page, ordered by path then line
	Files []int32  // every file with at least one hit (for map highlighting)
}

const maxHits = 50000

// Search finds symbols whose name starts with prefix, case-insensitively.
func (m *Map) Search(prefix string, page, pageSize int) SearchResult {
	p := strings.ToLower(strings.TrimSpace(prefix))
	if p == "" {
		return SearchResult{}
	}
	lo := sort.Search(len(m.Symbols), func(i int) bool { return m.Symbols[i].Lower >= p })
	hi := lo
	for hi < len(m.Symbols) && hi-lo < maxHits && strings.HasPrefix(m.Symbols[hi].Lower, p) {
		hi++
	}
	all := slices.Clone(m.Symbols[lo:hi])
	res := SearchResult{Total: len(all), More: hi < len(m.Symbols) && strings.HasPrefix(m.Symbols[hi].Lower, p)}
	slices.SortFunc(all, func(a, b Symbol) int {
		if c := cmp.Compare(m.Files[a.File].Path, m.Files[b.File].Path); c != 0 {
			return c
		}
		return cmp.Compare(a.Line, b.Line)
	})
	for i, s := range all {
		if i == 0 || all[i-1].File != s.File {
			res.Files = append(res.Files, s.File)
		}
	}
	start := min(page*pageSize, len(all))
	end := min(start+pageSize, len(all))
	res.Hits = all[start:end]
	return res
}

// Pick returns the deepest node under a world point that is at least minPx
// pixels big at the given scale (pixels per world unit), plus the 0-based
// text line under the point when it falls inside a file's text (else -1).
func (m *Map) Pick(x, y, pxPerUnit, minPx float64) (int32, int32) {
	if len(m.Nodes) == 0 || !m.Nodes[0].Rect.Contains(x, y) {
		return -1, -1
	}
	id := int32(0)
	for {
		n := &m.Nodes[id]
		next := int32(-1)
		if n.Kind == KindDir {
			for _, c := range n.Children {
				r := m.Nodes[c].Rect
				if r.Contains(x, y) && r.Min()*pxPerUnit >= minPx {
					next = c
					break
				}
			}
		} else {
			f := &m.Files[n.File]
			for _, c := range n.Children {
				s := &m.Nodes[c]
				if !s.Rect.Contains(x, y) {
					continue
				}
				depthInFile := float64(s.Depth-m.Nodes[f.Node].Depth-1) * 0.5 * f.CW
				for _, seg := range f.Segments(s.StartLine, s.EndLine, depthInFile) {
					if seg.Contains(x, y) && seg.H*pxPerUnit >= minPx {
						next = c
						break
					}
				}
				if next >= 0 {
					break
				}
			}
		}
		if next < 0 {
			line := int32(-1)
			if n.Kind != KindDir {
				f := &m.Files[n.File]
				if f.LH*pxPerUnit >= 1 {
					line = f.LineAt(x, y)
				}
			}
			return id, line
		}
		id = next
	}
}

// PickRay returns the nearest dir or file box hit by a ray (world units, the
// map lies in the X/Z plane with heights along Y) and the ray parameter of
// the hit. Boxes span [0, Top] vertically.
func (m *Map) PickRay(ox, oy, oz, dx, dy, dz float64) (int32, float64) {
	best, bestT := int32(-1), math.Inf(1)
	var visit func(id int32)
	visit = func(id int32) {
		n := &m.Nodes[id]
		r := n.Rect
		// subtree bounds first; skip if it can't beat the current hit
		if t, ok := rayBox(ox, oy, oz, dx, dy, dz, r, n.MaxTop); !ok || t > bestT {
			return
		}
		if id != 0 {
			if t, ok := rayBox(ox, oy, oz, dx, dy, dz, r, n.Top); ok && t <= bestT {
				best, bestT = id, t
			}
		}
		if n.Kind == KindDir {
			for _, c := range n.Children {
				visit(c)
			}
		}
	}
	visit(0)
	return best, bestT
}

// rayBox intersects a ray with the box r × [0, top] (slab method).
func rayBox(ox, oy, oz, dx, dy, dz float64, r Rect, top float64) (float64, bool) {
	t0, t1 := 0.0, math.Inf(1)
	slab := func(o, d, lo, hi float64) bool {
		if math.Abs(d) < 1e-300 {
			return o >= lo && o <= hi
		}
		a, b := (lo-o)/d, (hi-o)/d
		if a > b {
			a, b = b, a
		}
		t0, t1 = max(t0, a), min(t1, b)
		return t0 <= t1
	}
	if !slab(ox, dx, r.X, r.X+r.W) || !slab(oy, dy, 0, top) || !slab(oz, dz, r.Y, r.Y+r.H) {
		return 0, false
	}
	return t0, true
}

// HeightAt returns the roof height of the topmost dir or file box covering a
// ground point (0 outside the map). The camera uses it to stay above roofs.
func (m *Map) HeightAt(x, y float64) float64 {
	if len(m.Nodes) == 0 || !m.Nodes[0].Rect.Contains(x, y) {
		return 0
	}
	id := int32(0)
	for {
		n := &m.Nodes[id]
		next := int32(-1)
		if n.Kind == KindDir {
			for _, c := range n.Children {
				if m.Nodes[c].Rect.Contains(x, y) {
					next = c
					break
				}
			}
		}
		if next < 0 {
			return n.Top
		}
		id = next
	}
}
