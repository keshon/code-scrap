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
		if line >= 0 {
			f := &st.m.Files[n.File]
			out["lineRect"] = rect(f.LineRect(line))
		}
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
		})
	}
	files := make([][4]float64, 0, len(res.Files))
	for _, fi := range res.Files {
		files = append(files, rect(m.Nodes[m.Files[fi].Node].Rect))
	}
	return map[string]any{
		"op": "search", "q": q, "page": page, "total": res.Total, "more": res.More,
		"hits": hits, "files": files, "ms": ms,
	}
}

// Binary tile frame, little endian:
//
//	u8  type (1 = tile)
//	u8  z
//	u16 flags (bit 0: has code image)
//	i32 x, i32 y
//	u32 gen
//	u32 n          boxes
//	f32 × 16n      MultiMesh instance buffer
//	i32 × n        node ids
//	u32 nl         labels
//	nl × { i32 id, u8 kind, f32 x, y, w, h, u16 len, bytes }
//	[256×256×4]    RGBA8 code image, if flags bit 0
func encodeTile(st *state, k tile.Key) []byte {
	b := tile.BoxTile(st.m, k)
	code := st.renderer.Code(k)
	size := 20 + 4 + len(b.Instances)*4 + len(b.IDs)*4 + 4
	for _, l := range b.Labels {
		size += 4 + 1 + 16 + 2 + len(l.Text)
	}
	if code != nil {
		size += len(code.Pix)
	}
	buf := make([]byte, 0, size)
	le := binary.LittleEndian
	var flags uint16
	if code != nil {
		flags |= 1
	}
	buf = append(buf, 1, byte(k.Z))
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
		for _, f := range [4]float32{l.X, l.Y, l.W, l.H} {
			buf = le.AppendUint32(buf, math.Float32bits(f))
		}
		t := l.Text
		if len(t) > 0xFFFF {
			t = t[:0xFFFF]
		}
		buf = le.AppendUint16(buf, uint16(len(t)))
		buf = append(buf, t...)
	}
	if code != nil {
		buf = append(buf, code.Pix...)
	}
	return buf
}
