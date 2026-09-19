package codemap

import (
	"cmp"
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
