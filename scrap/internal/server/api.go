package server

import (
	"encoding/binary"
	"math"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/tile"
)

func rect(r codemap.Rect) [4]float64 { return [4]float64{r.X, r.Y, r.W, r.H} }

func hello(st *state) map[string]any {
	m := st.m
	return map[string]any{
		"op":      "hello",
		"gen":     st.gen,
		"root":    m.Root,
		"name":    m.Nodes[0].Name,
		"world":   rect(m.World),
		"tilePx":  tile.Px,
		"maxZ":    tile.MaxZ,
		"precise": st.precise,
		"stats":   m.Stats,
		"maxTop":  m.Nodes[0].MaxTop,
		"view":    m.View,
		"git":     m.GitTime != 0,
		"metrics": codemap.Metrics,
		"text": map[string]any{
			"font":      st.renderer.Atlas.Font,
			"colChars":  codemap.ColChars,
			"blockRows": tile.BlockRows,
			"texW":      tile.BlockChars,
		},
	}
}

var classNames = []struct {
	c    codemap.FileClass
	name string
}{
	{codemap.ClassBinary, "binary"}, {codemap.ClassAsset, "asset"}, {codemap.ClassSecret, "secret"},
	{codemap.ClassVendored, "vendored"}, {codemap.ClassData, "data"}, {codemap.ClassMinified, "minified"},
}

func nodeInfo(st *state, id int32) map[string]any {
	m := st.m
	if id < 0 || int(id) >= len(m.Nodes) {
		return map[string]any{"op": "node", "node": -1}
	}
	n := &m.Nodes[id]
	out := map[string]any{
		"op":          "node",
		"node":        id,
		"parent":      n.Parent,
		"name":        n.Name,
		"kind":        n.Kind.String(),
		"path":        m.Path(id),
		"lines":       n.Lines,
		"bytes":       n.Bytes,
		"children":    len(n.Children),
		"descendants": n.End - id - 1,
		"rect":        rect(n.Rect),
		"top":         n.Top,
		"line":        1,
	}
	if n.Kind != codemap.KindDir {
		f := &m.Files[n.File]
		out["lang"] = f.Lang.Name
		out["precise"] = f.Precise
		var classes []string
		for _, c := range classNames {
			if f.Class.Has(c.c) {
				classes = append(classes, c.name)
			}
		}
		out["classes"] = classes
		if n.Kind == codemap.KindFile {
			fm := map[string]any{
				"functions":     len(f.Scopes),
				"maxComplexity": f.MaxComplexity,
			}
			if m.GitTime != 0 {
				fm["commits"] = f.Commits
				fm["authors"] = f.Authors
				fm["lastChange"] = f.LastChange
			}
			out["fileMetrics"] = fm
		}
	}
	if n.Kind == codemap.KindScope {
		out["line"] = n.StartLine + 1
		out["scope"] = n.Scope.String()
		if n.Scope.String() == "func" {
			out["metrics"] = map[string]any{
				"complexity": n.Complexity,
				"params":     n.Params,
				"nesting":    n.MaxNesting,
				"lines":      n.Lines,
			}
		}
	}
	return out
}

func pick(st *state, x, y, scale float64) map[string]any {
	id, line := st.m.Pick(x, y, scale, 3)
	out := map[string]any{"op": "pick", "node": id, "line": line}
	if id >= 0 {
		n := &st.m.Nodes[id]
		out["name"] = n.Name
		out["kind"] = n.Kind.String()
		out["path"] = st.m.Path(id)
		out["rect"] = rect(n.Rect)
		out["top"] = n.Top
		if line >= 0 {
			f := &st.m.Files[n.File]
			out["lineRect"] = rect(f.LineRect(line))
		}
	}
	return out
}

func pickRay(st *state, r [6]float64) map[string]any {
	id, t := st.m.PickRay(r[0], r[1], r[2], r[3], r[4], r[5])
	out := map[string]any{"op": "pick", "node": id, "line": -1}
	if id >= 0 {
		n := &st.m.Nodes[id]
		out["name"] = n.Name
		out["kind"] = n.Kind.String()
		out["path"] = st.m.Path(id)
		out["rect"] = rect(n.Rect)
		out["top"] = n.Top
		out["t"] = t
	}
	return out
}

func search(st *state, q string, page, size int) map[string]any {
	if size <= 0 || size > 500 {
		size = 64
	}
	t := time.Now()
	res := st.m.Search(q, page, size)
	ms := float64(time.Since(t).Microseconds()) / 1000
	m := st.m
	hits := make([]map[string]any, 0, len(res.Hits))
	for _, h := range res.Hits {
		f := &m.Files[h.File]
		hits = append(hits, map[string]any{
			"node": h.Node, "fileNode": f.Node, "path": f.Path, "line": h.Line + 1,
			"name": h.Name, "kind": h.Kind.String(), "rect": rect(f.LineRect(h.Line)),
			"top": m.Nodes[f.Node].Top,
		})
	}
	files := make([][5]float64, 0, len(res.Files))
	for _, fi := range res.Files {
		n := &m.Nodes[m.Files[fi].Node]
		files = append(files, [5]float64{n.Rect.X, n.Rect.Y, n.Rect.W, n.Rect.H, n.Top})
	}
	return map[string]any{
		"op": "search", "q": q, "page": page, "total": res.Total, "more": res.More,
		"hits": hits, "files": files, "ms": ms,
	}
}

// Binary tile frame, little endian:
//
//	u8  type (1 = 2D tile, 2 = 3D tile)
//	u8  z
//	u16 flags (reserved, 0)
//	i32 x, i32 y
//	u32 gen
//	u32 n          boxes
//	f32 × 16n|20n  MultiMesh instance buffer (2D | 3D layout, see tile.Boxes)
//	i32 × n        node ids
//	u32 nl         labels
//	nl × { i32 id, u8 kind, f32 x, y, w, h, top, u16 len, bytes }
//	u32 nb         text blocks
//	nb × { i32 file, u16 col, u16 seg, u16 rows, f32 x, y, w, h, top }
func encodeTile(st *state, k tile.Key, is3D bool) []byte {
	b := tile.BoxTile(st.m, k, is3D)
	size := 20 + 4 + len(b.Instances)*4 + len(b.IDs)*4 + 4 + 4 + len(b.Blocks)*30
	for _, l := range b.Labels {
		size += 4 + 1 + 20 + 2 + len(l.Text)
	}
	buf := make([]byte, 0, size)
	le := binary.LittleEndian
	var flags uint16
	typ := byte(1)
	if is3D {
		typ = 2
	}
	buf = append(buf, typ, byte(k.Z))
	buf = le.AppendUint16(buf, flags)
	buf = le.AppendUint32(buf, uint32(int32(k.X)))
	buf = le.AppendUint32(buf, uint32(int32(k.Y)))
	buf = le.AppendUint32(buf, st.gen)
	buf = le.AppendUint32(buf, uint32(len(b.IDs)))
	for _, f := range b.Instances {
		buf = le.AppendUint32(buf, math.Float32bits(f))
	}
	for _, id := range b.IDs {
		buf = le.AppendUint32(buf, uint32(id))
	}
	buf = le.AppendUint32(buf, uint32(len(b.Labels)))
	for _, l := range b.Labels {
		buf = le.AppendUint32(buf, uint32(l.ID))
		buf = append(buf, l.Kind)
		for _, f := range [5]float32{l.X, l.Y, l.W, l.H, l.Top} {
			buf = le.AppendUint32(buf, math.Float32bits(f))
		}
		t := l.Text
		if len(t) > 0xFFFF {
			t = t[:0xFFFF]
		}
		buf = le.AppendUint16(buf, uint16(len(t)))
		buf = append(buf, t...)
	}
	buf = le.AppendUint32(buf, uint32(len(b.Blocks)))
	for _, bl := range b.Blocks {
		buf = le.AppendUint32(buf, uint32(bl.File))
		buf = le.AppendUint16(buf, bl.Col)
		buf = le.AppendUint16(buf, bl.Seg)
		buf = le.AppendUint16(buf, bl.Rows)
		for _, f := range [5]float32{bl.X, bl.Y, bl.W, bl.H, bl.Top} {
			buf = le.AppendUint32(buf, math.Float32bits(f))
		}
	}
	return buf
}

// Text block frame:
//
//	u8 type (3), u8 0, u16 col, i32 file, u16 seg, u16 rows, u32 gen
//	RGBA8 x texW*rows   premultiplied syntax color
//	RG8   x texW*rows   atlas cell per character
func encodeText(st *state, k textKey) []byte {
	rows, color, glyphs, ok := st.renderer.TextBlock(k.file, k.col, k.seg)
	if !ok {
		return nil
	}
	le := binary.LittleEndian
	buf := make([]byte, 0, 16+len(color)+len(glyphs))
	buf = append(buf, 3, 0)
	buf = le.AppendUint16(buf, uint16(k.col))
	buf = le.AppendUint32(buf, uint32(k.file))
	buf = le.AppendUint16(buf, uint16(k.seg))
	buf = le.AppendUint16(buf, uint16(rows))
	buf = le.AppendUint32(buf, st.gen)
	buf = append(buf, color...)
	return append(buf, glyphs...)
}

// Font atlas frame: u8 type (4), u8 0, u16 cols, rows, cellW, cellH, then
// L8 pixels, (cols*cellW) x (rows*cellH).
func encodeFont(a *tile.Atlas) []byte {
	le := binary.LittleEndian
	buf := make([]byte, 0, 10+len(a.Pix))
	buf = append(buf, 4, 0)
	for _, v := range []int{a.Cols, a.Rows, a.CellW, a.CellH} {
		buf = le.AppendUint16(buf, uint16(v))
	}
	return append(buf, a.Pix...)
}
