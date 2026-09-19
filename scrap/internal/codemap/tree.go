package codemap

import (
	"cmp"
	"path"
	"slices"
	"strings"
)

// PathHit is a file or directory matched by FindPaths.
type PathHit struct {
	Node int32
	Rank int // 0 exact name · 1 name prefix · 2 name contains · 3 path contains
}

// FindPaths finds files and directories whose path contains every
// space-separated term of q, case-insensitively, best first: matches on
// the name beat matches deeper in the path, then shorter paths win.
func (m *Map) FindPaths(q string, limit int) (hits []PathHit, total int) {
	terms := strings.Fields(strings.ToLower(q))
	if len(terms) == 0 {
		return nil, 0
	}
	last := terms[len(terms)-1]
	for i := range m.Nodes {
		n := &m.Nodes[i]
		if n.Kind == KindScope || i == 0 {
			continue
		}
		p := strings.ToLower(m.Path(int32(i)))
		ok := true
		for _, t := range terms {
			if !strings.Contains(p, t) {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		name := path.Base(p)
		rank := 3
		switch {
		case name == last:
			rank = 0
		case strings.HasPrefix(name, last):
			rank = 1
		case strings.Contains(name, last):
			rank = 2
		}
		hits = append(hits, PathHit{Node: int32(i), Rank: rank})
	}
	total = len(hits)
	slices.SortFunc(hits, func(a, b PathHit) int {
		if c := cmp.Compare(a.Rank, b.Rank); c != 0 {
			return c
		}
		pa, pb := m.Path(a.Node), m.Path(b.Node)
		if c := cmp.Compare(len(pa), len(pb)); c != 0 {
			return c
		}
		return cmp.Compare(pa, pb)
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits, total
}

// Lookup finds a directory or file by its repo-relative path ("" = root),
// or -1. Node ids change between map generations; paths do not.
func (m *Map) Lookup(p string) int32 {
	if p == "" {
		return 0
	}
	for i := range m.Nodes {
		if m.Nodes[i].Kind != KindScope && m.Path(int32(i)) == p {
			return int32(i)
		}
	}
	return -1
}

// Children lists a node's children for tree views: directories first, then
// files, then scopes, each alphabetically (scopes keep source order).
func (m *Map) Children(id int32) []int32 {
	if id < 0 || int(id) >= len(m.Nodes) {
		return nil
	}
	out := slices.Clone(m.Nodes[id].Children)
	slices.SortStableFunc(out, func(a, b int32) int {
		na, nb := &m.Nodes[a], &m.Nodes[b]
		if c := cmp.Compare(na.Kind, nb.Kind); c != 0 {
			return c
		}
		if na.Kind == KindScope {
			return cmp.Compare(na.StartLine, nb.StartLine)
		}
		return cmp.Compare(strings.ToLower(na.Name), strings.ToLower(nb.Name))
	})
	return out
}
