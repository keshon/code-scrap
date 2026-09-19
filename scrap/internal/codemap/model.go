// Package codemap builds a spatial model of a source tree: every directory,
// file and code scope becomes a nested box in one world-space map.
package codemap

import (
	"strings"

	"github.com/keshon/code-scrap/scrap/internal/syntax"
	"github.com/keshon/code-scrap/scrap/internal/treemap"
)

type Rect = treemap.Rect

func rect(x, y, w, h float64) Rect { return Rect{X: x, Y: y, W: w, H: h} }

type Kind uint8

const (
	KindDir Kind = iota
	KindFile
	KindScope
)

func (k Kind) String() string {
	switch k {
	case KindDir:
		return "dir"
	case KindFile:
		return "file"
	}
	return "scope"
}

// Node is one box on the map. IDs are assigned in pre-order, so a subtree is
// the ID range [id, End).
type Node struct {
	Name     string
	Kind     Kind
	Scope    syntax.ScopeKind // for KindScope
	Depth    uint8            // nesting depth from the root, scopes included
	Parent   int32
	Children []int32
	End      int32
	File     int32 // index into Map.Files for files and scopes, -1 for dirs
	Hue      uint8 // palette slot inherited from the top-level ancestor
	Rect     Rect  // layout rect; for scopes, the bounds of all segments

	Lines, Bytes int64
	Weight       float64

	// scopes only
	StartLine, EndLine int32 // 0-based, inclusive
	Complexity         int32
	Params             int32
	MaxNesting         int32
}

// ColChars is the width of one text column inside a file box, in characters.
const ColChars = 100

// File holds per-file facts plus the text layout inside the file box.
type File struct {
	Node    int32
	Path    string // slash-separated, relative to the root
	Abs     string
	Lang    *syntax.Lang
	Class   FileClass
	Precise bool // scopes came from tree-sitter, not the heuristic
	Lines   int32
	Bytes   int64
	Scopes  []int32 // scope node ids, pre-order

	// Text layout, world units. Lines flow top-to-bottom into Cols columns
	// of Rows lines each.
	TX, TY float64 // origin of column 0, line 0
	LH     float64 // line height
	CW     float64 // char width
	Cols   int32
	Rows   int32
	Stride float64 // distance between column origins
}

// Symbol is a named definition that search can find.
type Symbol struct {
	Lower string
	Name  string
	Node  int32 // scope node, or file node for declarations without a body
	File  int32
	Line  int32
	Kind  syntax.ScopeKind
}

// Map is the whole in-memory model of one source tree.
type Map struct {
	Root    string
	Nodes   []Node
	Files   []File
	Symbols []Symbol // sorted by Lower, then path, then line
	World   Rect     // repo bounds in world space
	Stats   Stats
}

type Stats struct {
	Dirs, Files, Scopes, Symbols int
	PreciseFiles                 int
	Lines, Bytes                 int64
	IndexMs, LayoutMs            int64
}

// Path returns the repo-relative path of a node.
func (m *Map) Path(id int32) string {
	n := &m.Nodes[id]
	if n.Kind != KindDir {
		return m.Files[n.File].Path
	}
	var parts []string
	for id > 0 {
		parts = append(parts, m.Nodes[id].Name)
		id = m.Nodes[id].Parent
	}
	for i, j := 0, len(parts)-1; i < j; i, j = i+1, j-1 {
		parts[i], parts[j] = parts[j], parts[i]
	}
	return strings.Join(parts, "/")
}

// LineRect is the world rect of a 0-based text line.
func (f *File) LineRect(line int32) Rect {
	if f.Rows <= 0 {
		return Rect{}
	}
	c, r := line/f.Rows, line%f.Rows
	return rect(f.TX+float64(c)*f.Stride, f.TY+float64(r)*f.LH, ColChars*f.CW, f.LH)
}

// LineAt returns the 0-based line under a world point, or -1.
func (f *File) LineAt(x, y float64) int32 {
	if f.Rows <= 0 || y < f.TY || x < f.TX {
		return -1
	}
	c := int32((x - f.TX) / f.Stride)
	r := int32((y - f.TY) / f.LH)
	if c >= f.Cols || r >= f.Rows || x-f.TX-float64(c)*f.Stride > ColChars*f.CW {
		return -1
	}
	if l := c*f.Rows + r; l < f.Lines {
		return l
	}
	return -1
}

// Segments splits the line range [start, end] into one rect per text column,
// shrunk horizontally by inset on both sides.
func (f *File) Segments(start, end int32, inset float64) []Rect {
	if f.Rows <= 0 || end < start {
		return nil
	}
	var out []Rect
	for c := start / f.Rows; c <= end/f.Rows && c < f.Cols; c++ {
		a := max(start, c*f.Rows) - c*f.Rows
		b := min(end, (c+1)*f.Rows-1) - c*f.Rows
		out = append(out, Rect{
			X: f.TX + float64(c)*f.Stride - 0.6*f.CW + inset,
			Y: f.TY + float64(a)*f.LH - 0.1*f.LH,
			W: (ColChars+1.2)*f.CW - 2*inset,
			H: float64(b-a+1)*f.LH + 0.2*f.LH,
		})
	}
	return out
}
