package tile

import (
	"hash/fnv"
	"unicode/utf8"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
)

// Text is drawn on the GPU per text block: one column of a file's text
// layout, split into segments of at most BlockRows lines. A block's texture
// has BlockChars texels per line (codemap.ColChars of them used).
const (
	BlockRows  = 4096
	BlockChars = 128
	minTextPx  = 0.2 // blocks are listed once a line is this many pixels tall
)

// Block places a text block in a tile (tile-local units, like boxes).
type Block struct {
	File       int32 // file node id
	Col, Seg   uint16
	Rows       uint16 // lines in this block
	X, Y, W, H float32
	Top        float32 // roof height of the file (3D)
	Key        uint32  // content key, stable across generations (see TextKey)
}

// TextKey identifies a text block's content independently of node ids,
// which change whenever the map is rebuilt: the file path, its column
// layout and the block's place in it. Equal keys mean equal textures, so
// viewers keep text they already have when a new generation arrives.
func TextKey(f *codemap.File, col, seg int32) uint32 {
	h := fnv.New32a()
	h.Write([]byte(f.Path))
	var b [16]byte
	for i, v := range [4]int32{f.Rows, f.Lines, col, seg} {
		b[i*4], b[i*4+1], b[i*4+2], b[i*4+3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
	}
	h.Write(b[:])
	return h.Sum32()
}

// TextKey returns the content key of a block of a file node (0 if none).
func (r *Renderer) TextKey(fileNode int32, col, seg int) uint32 {
	m := r.Map
	if fileNode < 0 || int(fileNode) >= len(m.Nodes) || m.Nodes[fileNode].Kind != codemap.KindFile {
		return 0
	}
	return TextKey(&m.Files[m.Nodes[fileNode].File], int32(col), int32(seg))
}

// blocks lists the text blocks of file f that intersect the tile.
func (b *Boxes) blocks(m *codemap.Map, n *codemap.Node, f *codemap.File, tr codemap.Rect, scale float64) {
	if f.Rows <= 0 || f.LH*scale < minTextPx || f.Class.Has(codemap.ClassBinary) {
		return
	}
	inv := 1 / tr.W
	for c := int32(0); c < f.Cols; c++ {
		x := f.TX + float64(c)*f.Stride
		w := codemap.ColChars * f.CW
		if x > tr.X+tr.W || x+w < tr.X {
			continue
		}
		lines := min(f.Rows, f.Lines-c*f.Rows)
		for seg := int32(0); seg*BlockRows < lines; seg++ {
			rows := min(BlockRows, lines-seg*BlockRows)
			y := f.TY + float64(seg*BlockRows)*f.LH
			h := float64(rows) * f.LH
			if y > tr.Y+tr.H || y+h < tr.Y {
				continue
			}
			b.Blocks = append(b.Blocks, Block{
				File: f.Node, Col: uint16(c), Seg: uint16(seg), Rows: uint16(rows),
				X: float32((x - tr.X) * inv), Y: float32((y - tr.Y) * inv),
				W: float32(w * inv), H: float32(h * inv), Top: float32(n.Top * inv),
				Key: TextKey(f, c, seg),
			})
		}
	}
}

// TextBlock builds the textures of one block:
//   - color: RGBA8, premultiplied syntax color × "has a glyph", so mipmaps
//     average into the dashed minimap look at any distance;
//   - glyphs: RG8, the atlas cell of each character (little endian u16).
//
// Both are BlockChars × rows texels. ok is false for files without text.
func (r *Renderer) TextBlock(fileNode int32, col, seg int) (rows int, color, glyphs []byte, ok bool) {
	m := r.Map
	if fileNode < 0 || int(fileNode) >= len(m.Nodes) || m.Nodes[fileNode].Kind != codemap.KindFile {
		return 0, nil, nil, false
	}
	fi := m.Nodes[fileNode].File
	f := &m.Files[fi]
	src := r.Texts.Get(fi)
	if src == nil || f.Rows <= 0 || int32(col) >= f.Cols {
		return 0, nil, nil, false
	}
	first := int32(col)*f.Rows + int32(seg)*BlockRows
	lines := min(f.Rows, f.Lines-int32(col)*f.Rows)
	rows = int(min(BlockRows, lines-int32(seg)*BlockRows))
	if rows <= 0 {
		return 0, nil, nil, false
	}
	color = make([]byte, BlockChars*rows*4)
	glyphs = make([]byte, BlockChars*rows*2)
	for row := 0; row < rows; row++ {
		li := int(first) + row
		if li >= len(src.Lines) {
			break
		}
		text := src.Lines[li]
		for _, s := range src.Segs[li] {
			c := classColors[s.Cls]
			ci := charIndex(text, int(s.Col))
			for bi := int(s.Col); bi < int(s.Col)+int(s.Len) && bi < len(text) && ci < codemap.ColChars; ci++ {
				ru, w := utf8.DecodeRuneInString(text[bi:])
				bi += w
				if ru == ' ' {
					continue
				}
				p := (row*BlockChars + ci) * 4
				color[p], color[p+1], color[p+2], color[p+3] = c.R, c.G, c.B, 255
				g := r.Atlas.Index(ru)
				q := (row*BlockChars + ci) * 2
				glyphs[q], glyphs[q+1] = byte(g), byte(g>>8)
			}
		}
	}
	return rows, color, glyphs, true
}

// charIndex converts a byte offset in a line to a character column.
func charIndex(s string, byteOff int) int {
	if byteOff > len(s) {
		byteOff = len(s)
	}
	return utf8.RuneCountInString(s[:byteOff])
}
