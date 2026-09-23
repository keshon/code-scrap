package server

import (
	"cmp"
	"encoding/binary"
	"fmt"
	"maps"
	"math"
	"slices"
	"strconv"
	"time"

	"github.com/keshon/code-scrap/scrap/internal/codemap"
	"github.com/keshon/code-scrap/scrap/internal/tile"
)

func rect(r codemap.Rect) [4]float64 { return [4]float64{r.X, r.Y, r.W, r.H} }

// Protocol is the wire protocol version (docs/protocol.md). Bump it on any
// incompatible change to a message or binary frame.
const Protocol = 11

func hello(st *state) map[string]any {
	m := st.m
	return map[string]any{
		"op":       "hello",
		"protocol": Protocol,
		"gen":      st.gen,
		"root":     m.Root,
		"name":     m.Nodes[0].Name,
		"world":    rect(m.World),
		"tilePx":   tile.Px,
		"maxZ":     tile.MaxZ,
		"precise":  st.precise,
		"stats":    m.Stats,
		"maxTop":   m.Nodes[0].MaxTop,
		"view":     m.View,
		"git":      m.GitTime != 0,
		"metrics":  codemap.Metrics,
		"lenses":   map[string]any{"height": codemap.HeightLenses(), "color": codemap.ColorLenses()},
		"legend":   legend(m),
		"text": map[string]any{
			"font":      st.renderer.Atlas.Font,
			"colChars":  codemap.ColChars + int(m.Gutter()), // gutter included
			"blockRows": tile.BlockRows,
			"texW":      tile.BlockChars,
		},
	}
}

// legend describes what the colors mean under the current view: the areas
// and their hues, or the metric ramp with its value quantiles.
func legend(m *codemap.Map) map[string]any {
	if m.View.Color == codemap.ColorCluster && m.Clusters != nil {
		return clusterLegend(m)
	}
	if m.View.Color != "" && m.View.Color != codemap.ColorArea {
		return map[string]any{
			"kind":      "metric",
			"ramp":      tile.HeatRamp(9),
			"quantiles": m.Quantiles(codemap.Metric(m.View.Color)),
		}
	}
	areas := m.Areas()
	list := make([]map[string]any, 0, min(len(areas), 16))
	for _, a := range areas[:min(len(areas), 16)] {
		list = append(list, map[string]any{"node": a.Node, "name": a.Name, "color": tile.AreaColor(m, a.Hue), "lines": a.Lines})
	}
	return map[string]any{"kind": "area", "areas": list, "more": max(len(areas)-16, 0)}
}

// clusterLegend lists the clusters with their names and colors; each
// entry's node is the cluster's home folder (to frame it).
func clusterLegend(m *codemap.Map) map[string]any {
	c := m.Clusters
	const shown = 24
	list := make([]map[string]any, 0, min(len(c.Clusters), shown))
	for _, x := range c.Clusters[:min(len(c.Clusters), shown)] {
		list = append(list, map[string]any{"node": x.Home, "name": x.Name, "color": tile.ClusterColor(x.Hue),
			"lines": x.Lines, "files": x.Files, "home": m.Path(x.Home)})
	}
	none := 0 // text files only: media and binaries never join a cluster
	for i, k := range c.Of {
		if k == codemap.ClusterNone && !m.Files[i].Class.Has(codemap.ClassBinary|codemap.ClassAsset|codemap.ClassSecret) {
			none++
		}
	}
	return map[string]any{"kind": "cluster", "clusters": list, "more": max(len(c.Clusters)-shown, 0),
		"hubs": len(c.Hubs), "unclustered": none, "hubColor": tile.HubColor, "noneColor": tile.NoneColor}
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
		"base":        baseTop(m, id),
		"line":        1,
		"ancestors":   ancestors(m, id),
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
	if n.Kind == codemap.KindDir {
		out["header"] = rect(m.Header(id))
	}
	if c := clusterInfo(m, id); c != nil {
		out["cluster"] = c
	}
	return out
}

// clusterInfo tells which cluster a file belongs to, or which clusters a
// folder's files belong to (biggest share first); nil without clusters.
func clusterInfo(m *codemap.Map, id int32) map[string]any {
	c := m.Clusters
	if c == nil {
		return nil
	}
	entry := func(k int32) map[string]any {
		x := &c.Clusters[k]
		return map[string]any{"name": x.Name, "color": tile.ClusterColor(x.Hue), "home": x.Home, "homePath": m.Path(x.Home), "files": x.Files}
	}
	n := &m.Nodes[id]
	if n.Kind != codemap.KindDir {
		switch k := m.ClusterOf(n.File); {
		case k >= 0:
			return map[string]any{"of": entry(k)}
		case k == codemap.ClusterHub:
			return map[string]any{"hub": true, "color": tile.HubColor}
		}
		return map[string]any{"none": true}
	}
	count := map[int32]int{}
	total := 0
	for fi := range m.Files {
		if f := m.Files[fi].Node; f > id && f < n.End {
			if k := c.Of[fi]; k >= 0 || k == codemap.ClusterHub {
				count[k]++
				total++
			}
		}
	}
	keys := slices.Collect(maps.Keys(count))
	slices.SortFunc(keys, func(a, b int32) int { return cmp.Or(cmp.Compare(count[b], count[a]), cmp.Compare(a, b)) })
	parts := []map[string]any{}
	for _, k := range keys[:min(len(keys), 5)] {
		var e map[string]any
		if k == codemap.ClusterHub {
			e = map[string]any{"hub": true, "color": tile.HubColor}
		} else {
			e = entry(k)
		}
		e["share"] = float64(count[k]) / float64(total)
		parts = append(parts, e)
	}
	if total == 0 {
		return nil // nothing here belongs to a cluster yet
	}
	return map[string]any{"parts": parts, "spread": len(keys), "clustered": total}
}

// ancestors lists [id, name] from the root down to the node's parent.
func ancestors(m *codemap.Map, id int32) [][2]any {
	var out [][2]any
	for p := m.Nodes[id].Parent; p >= 0; p = m.Nodes[p].Parent {
		out = append(out, [2]any{p, m.Nodes[p].Name})
	}
	slices.Reverse(out)
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
		out["base"] = baseTop(st.m, id)
		if line >= 0 {
			f := &st.m.Files[n.File]
			out["lineRect"] = rect(f.LineRect(line))
		}
		boxFacts(st.m, id, out)
		// the folder the hovered file or scope lives in, for context
		if n.Kind != codemap.KindDir {
			d := n.Parent
			for d >= 0 && st.m.Nodes[d].Kind != codemap.KindDir {
				d = st.m.Nodes[d].Parent
			}
			if d > 0 {
				dn := &st.m.Nodes[d]
				out["folder"] = map[string]any{"node": d, "name": dn.Name, "rect": rect(dn.Rect), "header": rect(st.m.Header(d))}
			}
		}
	}
	return out
}

// baseTop is the height a box stands on: its parent's roof (0 at the root).
// Highlights in 3D span base..top, like the box itself.
func baseTop(m *codemap.Map, id int32) float64 {
	if p := m.Nodes[id].Parent; p >= 0 {
		return m.Nodes[p].Top
	}
	return 0
}

// boxFacts adds what hover tooltips and selection frames need: the
// header band of a folder, and its file and folder counts.
func boxFacts(m *codemap.Map, id int32, out map[string]any) {
	n := &m.Nodes[id]
	out["lines"] = n.Lines
	if n.Kind != codemap.KindDir {
		return
	}
	out["header"] = rect(m.Header(id))
	files, dirs := 0, 0
	for i := id + 1; i < n.End; i++ {
		switch m.Nodes[i].Kind {
		case codemap.KindFile:
			files++
		case codemap.KindDir:
			dirs++
		}
	}
	out["files"], out["dirs"] = files, dirs
}

// relations answers "what does this node import, and who imports it"
// (op "edges") or "what does it call, and who calls it" (op "calls"), plus
// the geometry of every endpoint so the viewer can draw arcs directly.
func relations(st *state, op string, id int32) map[string]any {
	m := st.m
	var out, in []codemap.Edge
	var outTotal, inTotal int
	if op == "calls" {
		out, in, outTotal, inTotal = m.CallsOf(id, 2000)
	} else {
		if id >= 0 && int(id) < len(m.Nodes) && m.Nodes[id].Kind == codemap.KindScope {
			id = m.Files[m.Nodes[id].File].Node // imports belong to the file
		}
		out, in, outTotal, inTotal = m.DepsOf(id, 2000)
	}
	nodes := map[string][5]float64{}
	names := map[string]string{}
	lines := map[string][5]float64{}
	box := func(n int32) {
		if n < 0 {
			return
		}
		r := m.Nodes[n].Rect
		k := strconv.Itoa(int(n))
		nodes[k] = [5]float64{r.X, r.Y, r.W, r.H, m.Nodes[n].Top}
		names[k] = m.Path(n)
		if m.Nodes[n].Kind == codemap.KindScope {
			names[k] = m.Nodes[n].Name + " · " + m.Files[m.Nodes[n].File].Path
		}
	}
	// the exact place inside a box an arc starts from or lands on: the
	// import statement, the call, the declaration
	line := func(n, ln int32) {
		if n < 0 || ln < 0 || m.Nodes[n].Kind == codemap.KindDir {
			return
		}
		f := &m.Files[m.Nodes[n].File]
		if ln >= f.Lines {
			return
		}
		r := f.LineRect(ln)
		lines[fmt.Sprintf("%d#%d", n, ln)] = [5]float64{r.X, r.Y, r.W, r.H, m.Nodes[n].Top}
	}
	pair := func(es []codemap.Edge) [][4]int32 {
		res := make([][4]int32, len(es))
		for i, e := range es {
			res[i] = [4]int32{e.From, e.To, e.FromLine, e.ToLine}
			if e.ToSym >= 0 {
				res[i][1] = e.ToSym // a declaration with a box of its own
			}
			box(e.From)
			box(res[i][1])
			line(e.From, e.FromLine)
			line(res[i][1], res[i][3])
		}
		return res
	}
	return map[string]any{
		"op": op, "node": id,
		"out": pair(out), "in": pair(in), "outTotal": outTotal, "inTotal": inTotal,
		"nodes": nodes, "names": names, "lines": lines,
	}
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
		out["base"] = baseTop(st.m, id)
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
	// files and directories whose path matches (first page only)
	paths := []map[string]any{}
	pathTotal := 0
	if page == 0 {
		var ph []codemap.PathHit
		ph, pathTotal = m.FindPaths(q, 50)
		for _, p := range ph {
			n := &m.Nodes[p.Node]
			paths = append(paths, map[string]any{
				"node": p.Node, "path": m.Path(p.Node), "name": n.Name, "kind": n.Kind.String(),
				"rect": rect(n.Rect), "top": n.Top,
			})
		}
	}
	return map[string]any{
		"op": "search", "q": q, "page": page, "total": res.Total, "more": res.More,
		"hits": hits, "files": files, "ms": float64(time.Since(t).Microseconds()) / 1000,
		"paths": paths, "pathTotal": pathTotal,
	}
}

// overview is the whole map, coarse, for the minimap: directories and files
// down to a few levels, skipping boxes too small to see at minimap size.
// boxes: flat [x, y, w, h, r, g, b, kind] per box, parents first.
func overview(st *state) map[string]any {
	m := st.m
	minArea := m.World.W * m.World.H * 2e-5
	boxes := make([]float32, 0, 8*4096)
	var visit func(id int32, depth int)
	visit = func(id int32, depth int) {
		n := &m.Nodes[id]
		if n.Kind == codemap.KindScope || n.Rect.W*n.Rect.H < minArea || len(boxes) >= 8*6000 {
			return
		}
		if id != 0 {
			c := tile.BoxColor(m, n)
			boxes = append(boxes, float32(n.Rect.X), float32(n.Rect.Y), float32(n.Rect.W), float32(n.Rect.H),
				c[0], c[1], c[2], float32(n.Kind))
		}
		if depth < 4 {
			for _, c := range n.Children {
				visit(c, depth+1)
			}
		}
	}
	visit(0, 0)
	return map[string]any{"op": "overview", "world": rect(m.World), "boxes": boxes}
}

// children lists a node's children for tree views and breadcrumb menus.
func children(st *state, id int32) map[string]any {
	m := st.m
	items := []map[string]any{}
	for _, c := range m.Children(id) {
		n := &m.Nodes[c]
		items = append(items, map[string]any{
			"node": c, "name": n.Name, "kind": n.Kind.String(), "lines": n.Lines,
			"kids": len(n.Children), "color": tile.AreaColor(m, n.Hue),
		})
	}
	return map[string]any{"op": "children", "node": id, "items": items}
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
//	nl × { i32 id, u8 kind, u8 r, g, b, f32 x, y, w, h, top, u16 len, bytes }
//	u32 nb         text blocks
//	nb × { i32 file, u16 col, u16 seg, u16 rows, f32 x, y, w, h, top, u32 key }
func encodeTile(st *state, k tile.Key, is3D bool) []byte {
	b := tile.BoxTile(st.m, k, is3D)
	size := 20 + 4 + len(b.Instances)*4 + len(b.IDs)*4 + 4 + 4 + len(b.Blocks)*34
	for _, l := range b.Labels {
		size += 4 + 1 + 3 + 20 + 2 + len(l.Text)
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
		buf = append(buf, l.Kind, l.Color[0], l.Color[1], l.Color[2])
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
		buf = le.AppendUint32(buf, bl.Key)
	}
	return buf
}

// Text block frame:
//
//	u8 type (3), u8 0, u16 col, i32 file, u16 seg, u16 rows, u32 gen, u32 key
//	RGBA8 x texW*rows   premultiplied syntax color
//	RG8   x texW*rows   atlas cell per character
func encodeText(st *state, k textKey) []byte {
	rows, color, glyphs, ok := st.renderer.TextBlock(k.file, k.col, k.seg)
	if !ok {
		return nil
	}
	le := binary.LittleEndian
	buf := make([]byte, 0, 20+len(color)+len(glyphs))
	buf = append(buf, 3, 0)
	buf = le.AppendUint16(buf, uint16(k.col))
	buf = le.AppendUint32(buf, uint32(k.file))
	buf = le.AppendUint16(buf, uint16(k.seg))
	buf = le.AppendUint16(buf, uint16(rows))
	buf = le.AppendUint32(buf, st.gen)
	buf = le.AppendUint32(buf, st.renderer.TextKey(k.file, k.col, k.seg))
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
