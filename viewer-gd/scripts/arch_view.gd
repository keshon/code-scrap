class_name ArchView
extends Control
## The architecture view: the map at the altitude where a system is a
## handful of blocks. The server clusters files by how they are connected
## (imports, calls, git co-change) and gathers the clusters into groups;
## this view draws them in columns along the direction dependencies point —
## entry points left, what everything leans on right — with the lifted
## relations between them.
##
## Two levels: the groups, and the clusters of the group you open. That
## keeps about ten boxes on screen, which is what a person can hold at
## once. It answers "how is this built", which the treemap and the city
## cannot: they answer "where is much, and where is hot".

signal picked(node: int)            ## a box was clicked: select its folder
signal opened(node: int)            ## …double-clicked: show that folder on the map
signal level_changed(group: String) ## "" = all groups, else the opened one

const MIN_NODE_H := 30.0
const MAX_NODE_H := 110.0
const PAD := Vector2(26, 26)
const BOTTOM := 22.0        # room for the landmarks line
const MAX_EDGES := 18       # the heaviest only: the rest is noise at this altitude

var client: ScrapClient

var _arch := {}                     # the "arch" reply
var _colors := {}                   # cluster index (as string) -> [r, g, b]
var _group := -1                    # the opened group, -1 = all groups
var _view := []                     # what is on screen: groups, or one group's clusters
var _edges := []                    # lifted links between them, heaviest first
var _rects: Array[Rect2] = []       # by item index
var _back := Rect2()                # the "all groups" arrow
var _hover := -1
var _selected := -1
var _pending := false
var _req := -1
var _mouse := Vector2.ZERO


func _ready() -> void:
	name = "Arch"
	focus_mode = Control.FOCUS_ALL
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	Style.theme_changed.connect(queue_redraw)
	resized.connect(_relayout)
	visibility_changed.connect(func():
		if visible:
			refresh())


func attach(c: ScrapClient) -> void:
	client = c
	client.reply.connect(_on_reply)
	client.hello.connect(func(_i):
		_arch = {}          # node ids and clusters change with every rebuild
		_view = []
		if visible:
			refresh())


## Asks the server for the cluster graph (it answers "pending" while the
## clustering is still being computed in the background).
func refresh() -> void:
	if client == null or _pending:
		return
	_pending = true
	_req = client.request("arch", {})
	queue_redraw()


func _on_reply(id: int, data: Dictionary) -> void:
	if id != _req or data.get("op", "") != "arch":
		return
	_pending = false
	if data.get("pending", false):
		_arch = {}
		get_tree().create_timer(1.0).timeout.connect(func():
			if visible:
				refresh())
	else:
		_arch = data.get("arch", {})
		_colors = data.get("colors", {})
		_group = -1
		_relayout()
	queue_redraw()


## The opened group's name, "" at the top level.
func group_name() -> String:
	return _group_name() if _group >= 0 else ""


# ------------------------------------------------------- what is on screen

## The boxes to draw: the groups, or the clusters of the opened group.
func _items() -> Array:
	var nodes: Array = _arch.get("nodes", [])
	if nodes.is_empty():
		return []
	var out := []
	if _group < 0:
		for g in _arch.get("groups", []):
			var files := 0
			var lines := 0
			var level := 0.0
			var biggest := -1          # the group's biggest cluster names its home
			for c in g.clusters:
				var i := _node_of_cluster(int(c))
				if i < 0:
					continue
				var n: Dictionary = nodes[i]
				files += int(n.files)
				lines += int(n.lines)
				level += float(n.level) * float(n.files)
				if biggest < 0 or int(n.files) > int(nodes[biggest].files):
					biggest = i
			if biggest < 0:
				continue
			out.append({"group": int(g.id), "cluster": -1, "name": str(g.name), "files": files, "lines": lines,
				"level": level / maxf(float(files), 1.0), "home": int(nodes[biggest].home),
				"homePath": str(nodes[biggest].homePath), "color": _color(nodes[biggest]),
				"clusters": g.clusters.size()})
	else:
		for n in nodes:
			if int(n.group) != _group:
				continue
			out.append({"group": _group, "cluster": int(n.cluster), "name": str(n.name), "files": int(n.files),
				"lines": int(n.lines), "level": float(n.level), "home": int(n.home),
				"homePath": str(n.homePath), "color": _color(n), "clusters": 0})
	out.sort_custom(func(a, b): return a.level < b.level)
	return out


## Lifted links between whatever is on screen, heaviest first.
func _links(items: Array) -> Array:
	var nodes: Array = _arch.get("nodes", [])
	var where := {}    # cluster index -> item index
	for i in items.size():
		if _group >= 0:
			where[int(items[i].cluster)] = i
		else:
			for c in _arch.groups[_group_at(int(items[i].group))].clusters:
				where[int(c)] = i
	var acc := {}
	for e in _arch.get("edges", []):
		var a: int = where.get(int(e.from), -1)
		var b: int = where.get(int(e.to), -1)
		if a < 0 or b < 0 or a == b:
			continue
		var k := a * 1000 + b
		acc[k] = float(acc.get(k, 0.0)) + float(e.weight)
	var out := []
	for k in acc:
		out.append({"a": int(k / 1000), "b": int(k % 1000), "w": acc[k]})
	out.sort_custom(func(x, y): return x.w > y.w)
	return out


func _group_at(id: int) -> int:
	var groups: Array = _arch.get("groups", [])
	for i in groups.size():
		if int(groups[i].id) == id:
			return i
	return 0


func _group_name() -> String:
	for g in _arch.get("groups", []):
		if int(g.id) == _group:
			return str(g.name)
	return "group"


func _node_of_cluster(cluster: int) -> int:
	var nodes: Array = _arch.get("nodes", [])
	for i in nodes.size():
		if int(nodes[i].cluster) == cluster:
			return i
	return -1


func _color(n: Variant) -> Color:
	if n is Dictionary:
		var c: Variant = _colors.get(str(int(n.get("cluster", -1))), null)
		if c is Array and c.size() == 3:
			return Color(c[0], c[1], c[2])
	return Style.color("text2")


# ---------------------------------------------------------------- layout

## Columns follow the level (entry points left, foundations right) and each
## column splits its height evenly; a box's height carries how much code it
## holds.
func _relayout() -> void:
	_view = _items()
	_edges = _links(_view)
	_rects = []
	if _view.is_empty():
		queue_redraw()
		return
	var cols := clampi(int(ceil(sqrt(float(_view.size())))), 1, 5)
	var per_col := {}
	var biggest := 1
	# columns by rank, not by the level itself: groups average out to much
	# the same level and would all pile into one column
	var order := range(_view.size())
	order.sort_custom(func(a, b): return float(_view[a].level) < float(_view[b].level))
	for rank in order.size():
		var i: int = order[rank]
		biggest = max(biggest, int(_view[i].files))
		var c := mini(rank * cols / maxi(order.size(), 1), cols - 1)
		_view[i]["col"] = c
		per_col[c] = int(per_col.get(c, 0)) + 1
	var col_w := (size.x - 2.0 * PAD.x) / float(cols)
	var seen := {}
	_rects.resize(_view.size())
	for i in _view.size():
		var it: Dictionary = _view[i]
		var c: int = it.col
		var rows: int = maxi(int(per_col[c]), 1)
		var row: int = int(seen.get(c, 0))
		seen[c] = row + 1
		var row_h := (size.y - 2.0 * PAD.y - BOTTOM) / float(rows)
		var h := clampf(sqrt(float(it.files) / float(biggest)) * MAX_NODE_H, MIN_NODE_H, maxf(row_h - 14.0, MIN_NODE_H))
		var x := PAD.x + col_w * float(c) + 8.0
		var y := PAD.y + row_h * (float(row) + 0.5) - h * 0.5
		_rects[i] = Rect2(x, y, maxf(col_w - 16.0, 60.0), h)
	queue_redraw()


func _node_at(p: Vector2) -> int:
	for i in _rects.size():
		if _rects[i].has_point(p):
			return i
	return -1


# ---------------------------------------------------------------- input

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_mouse = (ev as InputEventMouseMotion).position
		_hover = _node_at(_mouse)
		queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			close_group()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		grab_focus()
		var i := _node_at(mb.position)
		if i < 0:
			if _back.has_point(mb.position):
				close_group()
			return
		var it: Dictionary = _view[i]
		if _group < 0:
			_group = int(it.group)      # a group opens into its clusters
			_selected = -1
			_hover = -1
			picked.emit(int(it.home))
			level_changed.emit(str(it.name))
			_relayout()
			return
		_selected = int(it.cluster)
		if mb.double_click:
			opened.emit(int(it.home))
		else:
			picked.emit(int(it.home))
		queue_redraw()


func _gui_key(ev: InputEventKey) -> void:
	if ev.pressed and ev.keycode == KEY_ESCAPE:
		close_group()


func _unhandled_key_input(ev: InputEvent) -> void:
	if visible and _group >= 0 and ev is InputEventKey:
		_gui_key(ev as InputEventKey)


## Back to all groups.
func close_group() -> void:
	if _group < 0:
		return
	_group = -1
	_selected = -1
	_hover = -1
	level_changed.emit("")
	_relayout()


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if _view.is_empty():
		_draw_note("Working out the clusters…" if _pending or _arch.is_empty() else "Nothing clustered yet.")
		return
	_draw_axis()
	_draw_edges()
	_draw_nodes()
	_draw_footer()
	if _hover >= 0:
		_draw_tip(_view[_hover])


func _draw_note(text: String) -> void:
	var font := Style.font("ui", 500)
	var fs := int(Style.num("font", "size_title", 15))
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(size.x * 0.5 - w * 0.5, size.y * 0.5), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Style.color("text3"))


## What the columns mean, and which group is open.
func _draw_axis() -> void:
	var font := Style.font("ui", 500)
	var bold := Style.font("ui", 600)
	var fs := 11
	var y := PAD.y - 9.0
	draw_string(font, Vector2(PAD.x, y), "entry points", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Style.color("text3"))
	var right := "what everything leans on"
	var rw := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(size.x - PAD.x - rw, y), right, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Style.color("text3"))
	var title := "%d groups · click one to open it" % _view.size()
	_back = Rect2()
	if _group >= 0:
		title = "%s · %d clusters · Esc for all groups" % [_group_name(), _view.size()]
	var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var tx := size.x * 0.5 - tw * 0.5
	draw_string(font, Vector2(tx, y), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Style.color("text2"))
	if _group >= 0:
		_back = Rect2(tx - 22.0, y - 12.0, 18.0, 16.0)
		draw_string(bold, _back.position + Vector2(2, 12), "‹", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Style.color("text2"))


## Lifted relations: a curve from the user to what it uses. Only the
## heaviest are drawn, plus every link of whatever is under the cursor.
func _draw_edges() -> void:
	if _edges.is_empty():
		return
	var heaviest: float = maxf(float(_edges[0].w), 1e-6)
	var keep := mini(_edges.size(), MAX_EDGES)
	for i in _edges.size():
		var e: Dictionary = _edges[i]
		var a := int(e.a)
		var b := int(e.b)
		var lit := _hover >= 0 and (a == _hover or b == _hover)
		if i >= keep and not lit:
			continue
		var ra := _rects[a]
		var rb := _rects[b]
		var forward := rb.get_center().x >= ra.get_center().x
		var p0 := Vector2(ra.end.x, ra.get_center().y) if forward else Vector2(ra.position.x, ra.get_center().y)
		var p1 := Vector2(rb.position.x, rb.get_center().y) if forward else Vector2(rb.end.x, rb.get_center().y)
		# a gentle curve on the weight: the heaviest link is often ten times
		# the next one, and a linear scale would hide everything else
		var t := pow(float(e.w) / heaviest, 0.35)
		var w := 1.0 + 4.0 * t
		var col: Color = _view[a].color
		var alpha := (0.5 if forward else 0.26) * (0.45 + 0.55 * t)
		if _hover >= 0:
			alpha *= 2.2 if lit else 0.2
		var bend := absf(p1.x - p0.x) * 0.45 + 24.0
		var c0 := p0 + Vector2(bend if forward else -bend, 0)
		var c1 := p1 - Vector2(bend if forward else -bend, 0)
		var pts := PackedVector2Array()
		for k in 17:
			var s := k / 16.0
			pts.append(p0.lerp(c0, s).lerp(c0.lerp(c1, s), s).lerp(c0.lerp(c1, s).lerp(c1.lerp(p1, s), s), s))
		draw_polyline(pts, Color(col, minf(alpha, 0.95)), w, true)
		var dir := (pts[16] - pts[14]).normalized()
		var side := Vector2(-dir.y, dir.x)
		var head := 5.0 + w
		draw_colored_polygon(PackedVector2Array([pts[16], pts[16] - dir * head + side * head * 0.5,
			pts[16] - dir * head - side * head * 0.5]), Color(col, minf(alpha * 1.6, 0.95)))


func _draw_nodes() -> void:
	var bold := Style.font("ui", 600)
	var font := Style.font("ui", 500)
	var bg := Style.color("bg")
	for i in _view.size():
		var it: Dictionary = _view[i]
		var r := _rects[i]
		var col: Color = it.color
		var on := _group >= 0 and int(it.cluster) == _selected
		draw_rect(r, Color(bg.lerp(col, 0.2), 0.96))
		draw_rect(r, Color(col, 1.0 if on or i == _hover else 0.55), false, 2.0 if on else 1.0)
		draw_rect(Rect2(r.position, Vector2(4, r.size.y)), col)
		var label := str(it.name) if str(it.name) != "" else "unnamed"
		draw_string(bold, r.position + Vector2(12, 18), label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18.0, 12,
			Style.color("text"))
		if r.size.y >= 36.0:
			var sub := "%s files · %s lines" % [Fmt.num(it.files), Fmt.num(it.lines)]
			if _group < 0:
				sub = "%d clusters · %s files" % [int(it.clusters), Fmt.num(it.files)]
			draw_string(font, r.position + Vector2(12, 34), sub, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18.0, 11,
				Style.color("text3"))


## The landmarks: files no cluster holds because most of the code uses them.
func _draw_footer() -> void:
	var font := Style.font("ui", 500)
	var hubs: Array = _arch.get("hubs", [])
	var text := ""
	for i in mini(hubs.size(), 4):
		var h: Dictionary = hubs[i]
		text += (" · " if i > 0 else "landmarks: ") + str(h.path).get_file() + " (%s)" % Fmt.num(h.importers)
	var files: Dictionary = _arch.get("files", {})
	text += "    %s files clustered · %s outside" % [Fmt.num(files.get("clustered", 0)), Fmt.num(files.get("unclustered", 0))]
	draw_string(font, Vector2(PAD.x, size.y - 9.0), text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 2.0 * PAD.x, 11,
		Style.color("text3"))


func _draw_tip(it: Dictionary) -> void:
	var font := Style.font("ui", 500)
	var bold := Style.font("ui", 600)
	var fs := 11
	var rows := [[str(it.name), bold, Style.color("text")]]
	if _group < 0:
		rows.append(["%d clusters · %s files · %s lines" % [int(it.clusters), Fmt.num(it.files), Fmt.num(it.lines)],
			font, Style.color("text2")])
		rows.append(["click to open the group", font, Style.color("text3")])
	else:
		rows.append(["%s files · %s lines" % [Fmt.num(it.files), Fmt.num(it.lines)], font, Style.color("text2")])
		rows.append(["double-click to show it on the map", font, Style.color("text3")])
	rows.append(["mostly in " + str(it.homePath), font, Style.color("text3")])
	rows.append(["%d%% of the way to the foundations" % int(round(float(it.level) * 100.0)), font, Style.color("text3")])
	var w := 0.0
	for r in rows:
		w = maxf(w, (r[1] as Font).get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var lh := fs + 5.0
	var box := Rect2(_mouse + Vector2(16, 14), Vector2(w + 16, lh * rows.size() + 8))
	if box.end.x > size.x:
		box.position.x = _mouse.x - box.size.x - 10
	if box.end.y > size.y:
		box.position.y = _mouse.y - box.size.y - 10
	draw_rect(box, Color(Style.color("raised"), 0.96))
	draw_rect(box, Color(Style.color("text3"), 0.5), false, 1.0)
	for i in rows.size():
		var r: Array = rows[i]
		draw_string(r[1], box.position + Vector2(8, 4 + lh * i + fs), r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, r[2])
