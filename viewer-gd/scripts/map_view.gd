class_name MapView
extends Control
## The zoomable map: streams tiles from scrap, draws them, handles the camera,
## labels, hover/selection/search overlays.
##
## World space is the unit square (the repo occupies its top part). The camera
## is kept in float64 (GDScript floats) as a center + zoom (pixels per world
## unit); only screen-space values ever reach float32 nodes, so deep zoom
## stays precise.

signal hovered(info: Dictionary)
signal selected(node_id: int)
signal camera_changed

const TILE_PX := 256.0

var client: ScrapClient

# camera (world units, float64)
var cx := 0.5
var cy := 0.3
var zoom := 1500.0
var _zoom_target := 1500.0
var _anchor := Vector2.ZERO        # screen point kept fixed while zooming
var _anchor_w := [0.0, 0.0]        # world point under the anchor

# map
var gen := -1
var world := [0.0, 0.0, 1.0, 0.625]
var max_z := 24

# tiles
var _tiles := {}                   # Vector3i -> TileRec
var _tiles_root: Node2D
var _overlay: Control
var _quad: ArrayMesh
var _box_mat: ShaderMaterial
var _level := -1

# diagnostics (HUD)
var stat_shown := 0
var stat_missing := 0
var stat_evicted := 0
var stat_gens := 0
var _dirty := true
var _last_request := ""
var _frame := 0

# interaction
var _dragging := false
var _drag := {}                    # active mouse binding: {action, click, button}
var _press_pos := Vector2.ZERO
var _pressed := false
var _pick_pending := false
var _pick_at := 0.0
var _last_mouse := Vector2.ZERO
var hover := {}                    # last pick reply
var selection_rect := []           # world [x,y,w,h]
var selection_id := -1

# search overlays
var hit_files := []                # Array of world rects [x,y,w,h]
var hit_lines := []                # Array of world rects
var current_hit := []              # world rect of the focused hit

# relation arcs: [{a: [x,y,w,h,top], b: [...], color: Color}]
var arcs := []

# fly-to animation
var _fly := {}

var _label_font: Font
var _text: TextLayer


class TileRec:
	var key: Vector3i
	var node: Node2D
	var gen: int
	var used: int
	var label_ids: PackedInt32Array
	var label_kinds: PackedByteArray
	var label_rects: PackedFloat64Array  # world x,y,w,h per label
	var label_texts: PackedStringArray
	var blocks: Array  # text blocks in world units: {file, col, seg, rows, x, y, w, h}


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	_label_font = Style.font("ui", 500)
	Style.theme_changed.connect(func():
		_label_font = Style.font("ui", 500)
		_overlay.queue_redraw())
	Settings.changed.connect(func(_id, _v): _dirty = true)
	Settings.reloaded.connect(func(): _dirty = true)

	_tiles_root = Node2D.new()
	add_child(_tiles_root)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_overlay.z_index = 1000  # above tile nodes, whose z_index is their level
	add_child(_overlay)

	_quad = ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)])
	_quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_box_mat = ShaderMaterial.new()
	_box_mat.shader = load("res://shaders/box.gdshader")

	resized.connect(func(): _dirty = true)


func attach(c: ScrapClient) -> void:
	client = c
	client.hello.connect(_on_hello)
	client.tile_received.connect(_on_tile)
	client.reply.connect(_on_reply)
	client.text_received.connect(func(_t): _dirty = true)
	client.font_ready.connect(func(): _dirty = true)
	var text_root := Node2D.new()
	text_root.z_index = 500  # above every tile level
	add_child(text_root)
	move_child(_overlay, -1)
	_text = TextLayer.new(client, text_root, load("res://shaders/text2d.gdshader"), func(mat):
		var mi := MeshInstance2D.new()
		mi.mesh = _quad
		mi.material = mat
		return mi)


# ---------------------------------------------------------------- camera

func world_to_screen(wx: float, wy: float) -> Vector2:
	return Vector2((wx - cx) * zoom + size.x * 0.5, (wy - cy) * zoom + size.y * 0.5)


func screen_to_world(p: Vector2) -> Array:
	return [cx + (p.x - size.x * 0.5) / zoom, cy + (p.y - size.y * 0.5) / zoom]


func rect_to_screen(r: Array) -> Rect2:
	var p := world_to_screen(r[0], r[1])
	return Rect2(p, Vector2(r[2] * zoom, r[3] * zoom))


func min_zoom() -> float:
	return min(size.x / (world[2] * 1.15), size.y / (world[3] * 1.15)) * 0.5


func max_zoom() -> float:
	return TILE_PX * pow(2.0, max_z + 0.5)


func fit_rect(r: Array, margin := 1.12) -> Array:
	var z: float = min(size.x / (r[2] * margin), size.y / (r[3] * margin))
	return [r[0] + r[2] * 0.5, r[1] + r[3] * 0.5, clamp(z, min_zoom(), max_zoom())]


func home(animate := true) -> void:
	var t := fit_rect(world, 1.06)
	if animate:
		fly_to(t[0], t[1], t[2])
	else:
		_fly = {}
		cx = t[0]
		cy = t[1]
		zoom = t[2]
		_zoom_target = zoom
		_dirty = true


## Smooth zoom-out/pan/zoom-in (van Wijk & Nuij, "Smooth and efficient
## zooming and panning", 2003). w = visible world width.
func fly_to(tx: float, ty: float, tzoom: float) -> void:
	var w0 := size.x / zoom
	var w1 := size.x / tzoom
	var dx := tx - cx
	var dy := ty - cy
	var u1 := sqrt(dx * dx + dy * dy)
	var rho := 1.42
	var f := {"x0": cx, "y0": cy, "dx": dx, "dy": dy, "u1": u1, "w0": w0, "w1": w1, "rho": rho, "t": 0.0}
	if u1 < 1e-12 * w0:
		f.S = abs(log(w1 / w0)) / rho
		f.k = sign(log(w1 / w0))
	else:
		var b0 := (w1 * w1 - w0 * w0 + rho * rho * rho * rho * u1 * u1) / (2.0 * w0 * rho * rho * u1)
		var b1 := (w1 * w1 - w0 * w0 - rho * rho * rho * rho * u1 * u1) / (2.0 * w1 * rho * rho * u1)
		f.r0 = log(-b0 + sqrt(b0 * b0 + 1.0))
		var r1 := log(-b1 + sqrt(b1 * b1 + 1.0))
		f.S = (r1 - f.r0) / rho
	f.dur = clamp(f.S * 0.32, 0.35, 1.6) / float(Settings.get_value("camera.fly_speed"))
	_fly = f
	_zoom_target = tzoom


func _step_fly(dt: float) -> void:
	var f := _fly
	f.t = min(1.0, f.t + dt / f.dur)
	var e: float = f.t * f.t * (3.0 - 2.0 * f.t)
	var s: float = f.S * e
	var w: float
	var u: float
	if f.has("k"):
		w = f.w0 * exp(f.k * f.rho * s)
		u = 0.0
	else:
		var rho: float = f.rho
		var r0: float = f.r0
		w = f.w0 * cosh(r0) / cosh(rho * s + r0)
		u = f.w0 / (rho * rho) * (cosh(r0) * tanh(rho * s + r0) - sinh(r0))
	var k: float = 0.0 if f.u1 == 0.0 else u / f.u1
	cx = f.x0 + f.dx * k
	cy = f.y0 + f.dy * k
	zoom = size.x / w
	if f.t >= 1.0:
		cx = f.x0 + f.dx
		cy = f.y0 + f.dy
		zoom = size.x / f.w1
		_zoom_target = zoom
		_fly = {}
	_dirty = true


func _process(dt: float) -> void:
	if not visible:
		return
	_frame += 1
	if not _fly.is_empty():
		_step_fly(dt)
	elif abs(log(_zoom_target / zoom)) > 1e-4:
		zoom = exp(lerp(log(zoom), log(_zoom_target), 1.0 - exp(-dt * float(Settings.get_value("camera.smoothing")))))
		cx = _anchor_w[0] - (_anchor.x - size.x * 0.5) / zoom
		cy = _anchor_w[1] - (_anchor.y - size.y * 0.5) / zoom
		_dirty = true
	if _pick_pending and Time.get_ticks_msec() / 1000.0 >= _pick_at:
		_pick_pending = false
		_send_pick()
	if _text != null and _text.animating():
		_dirty = true  # text fades in/out
	if _dirty and gen >= 0:
		_dirty = false
		_update_tiles()
		_overlay.queue_redraw()
		camera_changed.emit()


# ---------------------------------------------------------------- tiles

func text_layer() -> TextLayer:
	return _text


func tile_count() -> int:
	return _tiles.size()


func _on_hello(info: Dictionary) -> void:
	var first := gen < 0
	gen = int(info.gen)
	stat_gens += 1
	world = info.world
	max_z = int(info.maxZ)
	_text.set_gen(gen)
	if first:
		home(false)
	_last_request = ""
	_dirty = true


func _level_for_zoom() -> int:
	# +0.9: tiles are shown at 0.54–1.07× their native size, so code text is
	# almost never magnified
	var px_zoom := zoom * get_window().content_scale_factor  # physical pixels
	var lf := log(px_zoom / TILE_PX) / log(2.0) + 0.9
	# hysteresis: stay on the current level until the zoom is clearly past
	# its range, so wobbling at a boundary does not swap every tile
	if _level >= 0 and lf > _level - 0.12 and lf < _level + 1.12:
		return clampi(_level, 0, max_z)
	return clampi(int(floor(lf)), 0, max_z)


func _update_tiles() -> void:
	_level = _level_for_zoom()
	var z := _level
	var n := 1 << z
	var ts := 1.0 / n
	var tl := screen_to_world(Vector2.ZERO)
	var br := screen_to_world(size)
	var x0 := clampi(int(floor(max(tl[0], world[0]) / ts)), 0, n - 1)
	var x1 := clampi(int(floor(min(br[0], world[0] + world[2]) / ts)), 0, n - 1)
	var y0 := clampi(int(floor(max(tl[1], world[1]) / ts)), 0, n - 1)
	var y1 := clampi(int(floor(min(br[1], world[1] + world[3]) / ts)), 0, n - 1)

	var shown := {}
	var missing := []
	var ccx := cx / ts
	var ccy := cy / ts
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			var key := Vector3i(z, tx, ty)
			var rec: TileRec = _tiles.get(key)
			if rec != null and rec.gen == gen:
				shown[key] = rec
				continue
			missing.append([Vector2(tx + 0.5 - ccx, ty + 0.5 - ccy).length_squared(), key])
			if rec != null:
				shown[key] = rec  # stale generation: keep until the fresh one lands
			else:
				ViewCommon.tile_fallback(_tiles, key, shown)
	missing.sort_custom(func(a, b): return a[0] < b[0])
	stat_shown = shown.size()
	stat_missing = missing.size()
	var keys := []
	for m in missing:
		keys.append([m[1].x, m[1].y, m[1].z])
	var sig := str(gen) + ":" + str(keys)
	if sig != _last_request and client != null:
		_last_request = sig
		client.request_tiles(gen, keys)

	for key: Vector3i in _tiles:
		var rec: TileRec = _tiles[key]
		var vis := shown.has(key)
		rec.node.visible = vis
		if vis:
			rec.used = _frame
			var tsz := 1.0 / (1 << key.x)
			rec.node.position = world_to_screen(key.y * tsz, key.z * tsz)
			var s := tsz * zoom
			rec.node.scale = Vector2(s, s)
	if _tiles.size() > int(Settings.get_value("perf.tile_cache")):
		_evict()
	_update_text()


## Text blocks listed by the visible tiles, biggest text first.
func _update_text() -> void:
	var view := Rect2(Vector2.ZERO, size).grow(64)
	var min_px: float = Settings.get_value("text.min_line_px")
	var seen := {}   # key -> index in wanted
	var wanted := []
	for key: Vector3i in _tiles:
		var rec: TileRec = _tiles[key]
		if not rec.node.visible:
			continue
		for b in rec.blocks:
			var line_px: float = b.h / b.rows * zoom
			if line_px < min_px or not view.intersects(rect_to_screen([b.x, b.y, b.w, b.h])):
				continue
			var k := TextLayer.key_of(b)
			if seen.has(k):
				# an old-generation tile may still list the block: prefer the
				# current placement
				if int(b.gen) == gen:
					wanted[seen[k]] = [line_px, b]
				continue
			seen[k] = wanted.size()
			wanted.append([line_px, b])
	if not Settings.get_value("viewport.code_text"):
		wanted = []
	_text.update(wanted, int(Settings.get_value("text.budget")), func(node: Node2D, b: Dictionary):
		node.position = world_to_screen(b.x, b.y)
		node.scale = Vector2(b.w * zoom, b.h * zoom))


func _evict() -> void:
	var recs := _tiles.values()
	recs.sort_custom(func(a, b): return a.used < b.used)
	var drop := _tiles.size() - int(int(Settings.get_value("perf.tile_cache")) * 0.8)
	for i in drop:
		var rec: TileRec = recs[i]
		if rec.node.visible:
			continue
		rec.node.queue_free()
		_tiles.erase(rec.key)
		stat_evicted += 1


func _on_tile(t: Dictionary) -> void:
	if int(t.gen) != gen or int(t.dim) != 2:
		return
	var key := Vector3i(t.z, t.x, t.y)
	var old: TileRec = _tiles.get(key)
	if old != null:
		old.node.queue_free()
	var rec := TileRec.new()
	rec.key = key
	rec.gen = gen
	rec.used = _frame
	var node := Node2D.new()
	node.z_index = t.z
	var ids: PackedInt32Array = t.ids
	if ids.size() > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _quad
		mm.instance_count = ids.size()
		mm.buffer = t.buffer
		var mmi := MultiMeshInstance2D.new()
		mmi.multimesh = mm
		mmi.material = _box_mat
		node.add_child(mmi)
	# labels and text blocks → world space
	var ts := 1.0 / (1 << int(t.z))
	var ox: float = t.x * ts
	var oy: float = t.y * ts
	for bl in t.blocks:
		var br: Rect2 = bl.rect
		rec.blocks.append({"file": bl.file, "col": bl.col, "seg": bl.seg, "rows": bl.rows, "key": bl.key, "gen": gen,
			"x": ox + br.position.x * ts, "y": oy + br.position.y * ts, "w": br.size.x * ts, "h": br.size.y * ts})
	for l in t.labels:
		var r: Rect2 = l.rect
		rec.label_ids.append(l.id)
		rec.label_kinds.append(l.kind)
		rec.label_rects.append_array([ox + r.position.x * ts, oy + r.position.y * ts, r.size.x * ts, r.size.y * ts])
		rec.label_texts.append(l.text)
	rec.node = node
	node.visible = false
	_tiles_root.add_child(node)
	_tiles[key] = rec
	_dirty = true


# ---------------------------------------------------------------- input

## Mouse input goes through the active keymap (Settings → Mouse & keys):
## orbit and pan both pan the flat map, dolly zooms, select clicks.
func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			if Keymap.wheel_action(mb) == "zoom":
				var step: float = Settings.get_value("camera.zoom_step")
				var f := step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / step
				if mb.factor > 0.0:
					f = pow(f, mb.factor)
				_zoom_at(mb.position, f)
				accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if mb.pressed:
				grab_focus()
				_drag = Keymap.mouse_binding(mb)
				_drag.button = mb.button_index
				_dragging = false
				_press_pos = mb.position
				if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
					_focus_hovered()
			elif _drag.get("button", -1) == mb.button_index:
				if not _dragging and _drag.get("click", "") == "select":
					_click_select()
				_drag = {}
				_dragging = false
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		_last_mouse = mm.position
		if not _drag.is_empty() and _drag.has("action"):
			if not _dragging and mm.position.distance_to(_press_pos) > 4.0:
				_dragging = true
			if _dragging:
				match _drag.action:
					"pan", "orbit":
						_fly = {}
						cx -= mm.relative.x / zoom
						cy -= mm.relative.y / zoom
						_zoom_target = zoom
						_anchor_w = screen_to_world(_anchor)
						_dirty = true
					"dolly":
						_zoom_at(_press_pos, exp(-mm.relative.y * 0.01))
		_schedule_pick()
	elif ev is InputEventMagnifyGesture:
		_zoom_at(ev.position, ev.factor)
	elif ev is InputEventPanGesture:
		cx += ev.delta.x * 20.0 / zoom
		cy += ev.delta.y * 20.0 / zoom
		_dirty = true


func _zoom_at(p: Vector2, f: float) -> void:
	_fly = {}
	_anchor = p
	_anchor_w = screen_to_world(p)
	_zoom_target = clamp(_zoom_target * f, min_zoom(), max_zoom())


## A rectangle outline of w UI px, snapped to whole physical pixels and
## drawn inside r, so highlight lines are as crisp as the box outlines.
func _outline(r: Rect2, c: Color, w: float) -> void:
	var f := get_window().content_scale_factor
	var a := (r.position * f).round() / f
	var b := (r.end * f).round() / f
	var t := Style.line_px(w) / f
	var o := _overlay
	o.draw_rect(Rect2(a.x, a.y, b.x - a.x, t), c)
	o.draw_rect(Rect2(a.x, b.y - t, b.x - a.x, t), c)
	o.draw_rect(Rect2(a.x, a.y + t, t, b.y - a.y - 2.0 * t), c)
	o.draw_rect(Rect2(b.x - t, a.y + t, t, b.y - a.y - 2.0 * t), c)


func _schedule_pick() -> void:
	if not _pick_pending:
		_pick_pending = true
		_pick_at = Time.get_ticks_msec() / 1000.0 + 0.03


func _send_pick() -> void:
	if client == null or gen < 0:
		return
	var w := screen_to_world(_last_mouse)
	client.request("pick", {"x": w[0], "y": w[1], "scale": zoom})


func _on_reply(_id: int, data: Dictionary) -> void:
	if visible and data.get("op") == "pick":
		hover = data
		hovered.emit(data)
		_overlay.queue_redraw()


## A click selects what is under the cursor; a click on empty space
## deselects.
func _click_select() -> void:
	if hover.is_empty() or int(hover.get("node", -1)) < 0:
		deselect()
		return
	select_node(int(hover.node), hover.rect)


func deselect() -> void:
	if selection_id < 0 and selection_rect.is_empty():
		return
	selection_id = -1
	selection_rect = []
	current_hit = []
	selected.emit(-1)
	_overlay.queue_redraw()


func frame_selected() -> void:
	if selection_rect.size() == 4:
		var t := fit_rect(selection_rect)
		fly_to(t[0], t[1], t[2])


## Shows a selection made elsewhere (no signal).
func set_selection(id: int, rect: Array) -> void:
	selection_id = id
	selection_rect = rect
	_overlay.queue_redraw()


func select_node(id: int, rect: Array) -> void:
	selection_id = id
	selection_rect = rect
	selected.emit(id)
	_overlay.queue_redraw()


func _focus_hovered() -> void:
	if hover.is_empty() or int(hover.get("node", -1)) < 0:
		return
	var t := fit_rect(hover.rect)
	fly_to(t[0], t[1], t[2])


## Flies so the world rect r (e.g. a text line) is centered with its height
## shown at about `line_px` pixels.
func focus_line(r: Array, line_px := 16.0) -> void:
	var z: float = clamp(line_px / max(r[3], 1e-12), min_zoom(), max_zoom())
	fly_to(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5, z)


# ---------------------------------------------------------------- overlay

func _draw_overlay() -> void:
	var o := _overlay
	var view := Rect2(Vector2.ZERO, size)
	var HIT_COLOR: Color = Settings.get_value("highlight.search")
	var hover_c: Color = Settings.get_value("highlight.hover")
	var sel_c: Color = Settings.get_value("highlight.selection")
	var show_hits: bool = Settings.get_value("viewport.search_hits")
	# search: files with hits, then hit lines
	for r in (hit_files if show_hits else []):
		var s := rect_to_screen(r)
		if not view.intersects(s.grow(2)):
			continue
		if s.size.x < 6.0 or s.size.y < 6.0:
			var c := s.get_center()
			o.draw_rect(Rect2(c - Vector2(1.5, 1.5), Vector2(3, 3)).merge(s), HIT_COLOR)
		else:
			# strong when small, just an outline once the file fills the view
			var fade: float = 1.0 - smoothstep(60.0, 400.0, min(s.size.x, s.size.y))
			o.draw_rect(s, Color(HIT_COLOR, 0.05 + 0.2 * fade))
			o.draw_rect(s, Color(HIT_COLOR, 0.5 + 0.3 * fade), false, 1.0)
	for r in (hit_lines if show_hits else []):
		var s := rect_to_screen(r)
		if view.intersects(s) and s.size.y >= 1.0:
			o.draw_rect(s, Color(HIT_COLOR, 0.22))
	if current_hit.size() == 4 and show_hits:
		var s := rect_to_screen(current_hit)
		o.draw_rect(s.grow(1), Color(HIT_COLOR, 0.35))
		o.draw_rect(s.grow(1), HIT_COLOR, false, 1.5)
	if Settings.get_value("viewport.arcs"):
		_draw_arcs()
	if Settings.get_value("viewport.labels"):
		_draw_labels()
	# hover + selection
	if hover.has("rect") and int(hover.get("node", -1)) >= 0 and Settings.get_value("viewport.hover"):
		var hr := rect_to_screen(hover.rect)
		o.draw_rect(hr, Color(hover_c, 0.06))
		_outline(hr, Color(hover_c, 0.7), Settings.get_value("lines.hover_width"))
		if hover.has("lineRect"):
			o.draw_rect(rect_to_screen(hover.lineRect), Color(hover_c, 0.12))
	if selection_rect.size() == 4:
		var sr := rect_to_screen(selection_rect)
		o.draw_rect(sr, Color(sel_c, 0.16))
		_outline(sr, sel_c, Settings.get_value("lines.selected_width"))


func _draw_labels() -> void:
	var o := _overlay
	var seen := {}
	var cand := []
	var view := Rect2(Vector2.ZERO, size)
	var fs: int = Settings.get_value("labels.font_size")
	var min_box: float = Settings.get_value("labels.min_box_px")
	for key: Vector3i in _tiles:
		var rec: TileRec = _tiles[key]
		if not rec.node.visible:
			continue
		for i in rec.label_ids.size():
			var id := rec.label_ids[i]
			if seen.has(id):
				continue
			seen[id] = true
			var r := Rect2(world_to_screen(rec.label_rects[i * 4], rec.label_rects[i * 4 + 1]),
				Vector2(rec.label_rects[i * 4 + 2] * zoom, rec.label_rects[i * 4 + 3] * zoom))
			var kind := rec.label_kinds[i]
			if kind == 2:
				if r.size.y < 7.0 or r.size.x < 30.0:
					continue
			elif r.size.x < min_box:
				continue
			if not view.intersects(r):
				continue
			cand.append({"prio": r.size.x, "text": rec.label_texts[i], "max_w": r.size.x - 8.0,
				"pos": Vector2(max(r.position.x, 0.0) + 2.0, max(r.position.y, 0.0) + 1.0),
				"size": clampi(int(r.size.y * 0.85), 8, fs) if kind == 2 else fs})
	ViewCommon.draw_labels(o, _label_font, cand, Settings.get_value("labels.max"))


# ---------------------------------------------------------------- relations

func set_arcs(list: Array) -> void:
	arcs = list
	_overlay.queue_redraw()


func _draw_arcs() -> void:
	if arcs.is_empty():
		return
	var o := _overlay
	var view := Rect2(Vector2.ZERO, size).grow(200)
	var top_a: float = Settings.get_value("relations.opacity")
	var alpha: float = clamp(60.0 / arcs.size(), top_a * 0.2, top_a)
	var width: float = Settings.get_value("relations.width")
	for arc in arcs:
		var a := rect_to_screen(arc.a).get_center()
		var b := rect_to_screen(arc.b).get_center()
		if not view.has_point(a) and not view.has_point(b):
			continue
		var d := b - a
		var len := d.length()
		if len < 2.0:
			continue
		# bend every arc the same way, so in- and outgoing pairs separate
		var ctrl: Vector2 = (a + b) * 0.5 + Vector2(-d.y, d.x) / len * min(len * 0.22, 220.0)
		var pts := PackedVector2Array()
		for i in 21:
			var t := i / 20.0
			pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
		var c: Color = arc.color
		o.draw_polyline(pts, Color(c, alpha), width, true)
		# arrowhead at the imported/called end
		var tip := pts[20]
		var back := tip - pts[17]
		if back.length() > 0.5:
			var dir := back.normalized()
			var side := Vector2(-dir.y, dir.x)
			var ac := Color(c, min(alpha * 1.5, 1.0))
			o.draw_primitive(PackedVector2Array([tip, tip - dir * 8.0 + side * 3.5, tip - dir * 8.0 - side * 3.5]),
				PackedColorArray([ac, ac, ac]), PackedVector2Array())
		o.draw_circle(pts[0], 2.0, Color(c, alpha))


# ---------------------------------------------------------------- search

func set_search_results(files: Array, lines: Array) -> void:
	hit_files = files
	hit_lines = lines
	_overlay.queue_redraw()


func clear_search() -> void:
	hit_files = []
	hit_lines = []
	current_hit = []
	_overlay.queue_redraw()
