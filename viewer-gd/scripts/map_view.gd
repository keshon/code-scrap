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
signal jumped   ## about to travel somewhere: one step for the history

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
var _grid: ColorRect
var _dim: ColorRect          # focus + context: darkens all but the mask
var _mask_vp: SubViewport
var _mask: Control
var _arc_lines := []         # drawn arcs this frame: {pts, text, aw, bw, key}
var _arc_hover := -1
var _arc_back := {}          # where the view was before following an arc
var _level := -1

# diagnostics (HUD)
var stat_shown := 0
var stat_missing := 0
var stat_evicted := 0
var stat_gens := 0
var stat_redraws := 0        # full view updates (tiles, text, labels) so far
var why := {}                # what asked for the last redraws (diagnostics)
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
var selection_header := []         # the selected folder's header band (folder headers mode)
var selection_id := -1

# search overlays
## A line thinner than this on screen cannot be told from its neighbours,
## so an arc aims at the whole box instead.
const LINE_ANCHOR_PX := 2.5

## Screen space the viewport header covers: framing keeps clear of it.
var top_inset := 0.0

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
	var label_colors: PackedColorArray
	var label_lines: PackedInt32Array
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

	_grid = ColorRect.new()
	_grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.z_index = -1
	_grid.material = ShaderMaterial.new()
	(_grid.material as ShaderMaterial).shader = load("res://shaders/grid2d.gdshader")
	add_child(_grid)
	_tiles_root = Node2D.new()
	add_child(_tiles_root)
	_mask_vp = SubViewport.new()
	_mask_vp.transparent_bg = false
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_mask_vp)
	_mask = Control.new()
	_mask.draw.connect(_draw_mask)
	_mask_vp.add_child(_mask)
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.z_index = 900  # over tiles and code text, under labels and arcs
	_dim.material = ShaderMaterial.new()
	(_dim.material as ShaderMaterial).shader = load("res://shaders/dim.gdshader")
	(_dim.material as ShaderMaterial).set_shader_parameter("mask", _mask_vp.get_texture())
	_dim.visible = false
	add_child(_dim)
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


## The camera target that shows rect r whole, centred in the space the
## header leaves free rather than under it.
func fit_rect(r: Array, margin := 1.12) -> Array:
	var free := maxf(size.y - top_inset, 40.0)
	var z: float = clamp(min(size.x / (r[2] * margin), free / (r[3] * margin)), min_zoom(), max_zoom())
	return [r[0] + r[2] * 0.5, r[1] + r[3] * 0.5 - top_inset * 0.5 / z, z]


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
## The camera, for bookmarks.
func camera_state() -> Dictionary:
	return {"cx": cx, "cy": cy, "zoom": _zoom_target}


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
		stat_redraws += 1
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
	_update_grid()


## Dots every 2^k world units, the level picked so they sit 20–40 px apart.
func _update_grid() -> void:
	_grid.visible = Settings.get_value("viewport.grid")
	if not _grid.visible:
		return
	var f := get_window().content_scale_factor
	var k: float = floor(log(28.0 / zoom) / log(2.0))
	var spacing := pow(2.0, k) * zoom * f
	var m := _grid.material as ShaderMaterial
	m.set_shader_parameter("spacing", spacing)
	m.set_shader_parameter("origin", (world_to_screen(0.0, 0.0) + get_global_rect().position) * f)
	m.set_shader_parameter("dot_color", Color(Style.color("text3"), 0.22))


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
		rec.label_colors.append(l.color)
		rec.label_lines.append(int(l.get("lines", 0)))
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
		var ah := _pick_arc(mm.position) if not _arc_lines.is_empty() else -1
		if ah != _arc_hover:
			_arc_hover = ah
			_overlay.queue_redraw()
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
	if _arc_hover >= 0 and _arc_hover < _arc_lines.size():
		follow_arc(_arc_hover)   # a click on an arc travels along it
		return
	if hover.is_empty() or int(hover.get("node", -1)) < 0:
		deselect()
		return
	select_node(int(hover.node), hover.rect, hover.get("header", []))


func deselect() -> void:
	if selection_id < 0 and selection_rect.is_empty():
		return
	selection_id = -1
	selection_header = []
	selection_rect = []
	current_hit = []
	selected.emit(-1)
	_overlay.queue_redraw()


func frame_selected() -> void:
	if selection_rect.size() == 4:
		var t := fit_rect(selection_rect)
		fly_to(t[0], t[1], t[2])


## Shows a selection made elsewhere (no signal).
func set_selection(id: int, rect: Array, header := []) -> void:
	selection_id = id
	selection_rect = rect
	selection_header = header
	_overlay.queue_redraw()


## Is the selection (mostly) on screen? Asked before a rebuild, to decide
## whether the view should follow it once the layout moves.
func selection_on_screen() -> bool:
	if selection_rect.size() != 4:
		return false
	var r := rect_to_screen(selection_rect)
	var v := Rect2(Vector2.ZERO, size)
	if not v.intersects(r):
		return false
	var shown := v.intersection(r)
	return shown.get_area() >= 0.5 * minf(r.get_area(), v.get_area())


func select_node(id: int, rect: Array, header := []) -> void:
	selection_id = id
	selection_rect = rect
	selection_header = header
	selected.emit(id)
	_overlay.queue_redraw()


func _focus_hovered() -> void:
	if hover.is_empty() or int(hover.get("node", -1)) < 0:
		return
	jumped.emit()
	var t := fit_rect(hover.rect)
	fly_to(t[0], t[1], t[2])


## Flies so the world rect r (e.g. a text line) is centered with its height
## shown at about `line_px` pixels.
func focus_line(r: Array, line_px := 16.0) -> void:
	var z: float = clamp(line_px / max(r[3], 1e-12), min_zoom(), max_zoom())
	fly_to(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5 - top_inset * 0.5 / z, z)


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
	_update_dim()
	_arc_lines = []
	_draw_arcs()
	_draw_arc_tip()
	var headers: bool = Settings.get_value("look.headers")
	var show_hover: bool = hover.has("rect") and int(hover.get("node", -1)) >= 0 and Settings.get_value("viewport.hover") 		and Settings.get_value("highlight.hover_style") != "off"
	if headers:
		# header bands light up under the names: the selected folder's in
		# the selection color, the hovered one (or the hovered file's
		# folder) a little
		if selection_header.size() == 4:
			o.draw_rect(rect_to_screen(selection_header), Color(sel_c, 0.55))
		if show_hover:
			var hh: Array = hover.get("header", hover.get("folder", {}).get("header", []))
			if hh.size() == 4 and hh != selection_header:
				o.draw_rect(rect_to_screen(hh), Color(1, 1, 1, 0.18))
	if Settings.get_value("viewport.labels"):
		_draw_labels()
	if headers and show_hover and hover.has("folder"):
		# the hovered file's folder: where am I?
		_outline(rect_to_screen(hover.folder.rect), Color(1, 1, 1, 0.35), 1.0)
	# hover + selection
	# on the flat map "outline" and "xray" look the same: nothing stands in front
	if show_hover:
		var hr := rect_to_screen(hover.rect)
		o.draw_rect(hr, Color(hover_c, 0.06))
		# folder headers: a white frame, as bright as the bands are colorful
		var frame := Color(1, 1, 1, 0.9) if headers else Color(hover_c, 0.7)
		_outline(hr, frame, Settings.get_value("lines.hover_width") + (1.0 if headers else 0.0))
		if hover.has("lineRect"):
			o.draw_rect(rect_to_screen(hover.lineRect), Color(hover_c, 0.12))
	if selection_rect.size() == 4:
		var sr := rect_to_screen(selection_rect)
		# on the flat map a box's silhouette is its outline; tint fills it
		var style: String = Settings.get_value("highlight.style")
		if style == "tint" or style == "both":
			o.draw_rect(sr, Color(sel_c, float(Settings.get_value("highlight.fill")) * 0.6))
		if style == "silhouette" or style == "both" or headers:
			_outline(sr, sel_c, Settings.get_value("lines.selected_width"))
	if headers and show_hover and _arc_hover < 0 and Settings.get_value("viewport.hover_tip"):
		_draw_hover_tip()


func _draw_labels() -> void:
	var o := _overlay
	var seen := {}
	var cand := []
	var view := Rect2(Vector2.ZERO, size)
	var fs: int = Settings.get_value("labels.font_size")
	var min_box: float = Settings.get_value("labels.min_box_px")
	var headers: bool = Settings.get_value("look.headers")
	# the cards layout leaves air around every box: room enough to say how
	# much code each one holds, which the packed treemap never has
	var counts: bool = Settings.get_value("layout.algorithm") == "cards"
	var heads := []   # folder names printed in their header bands
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
			if headers and kind == 0:
				# r is the header band: the name goes inside it, sized to fit
				if r.size.y >= 9.0 and r.size.x >= 30.0 and view.intersects(r):
					var head_text: String = rec.label_texts[i]
					if counts and rec.label_lines[i] > 0 and r.size.x >= 150.0:
						head_text += "   %s lines" % Fmt.num(rec.label_lines[i])
					heads.append({"rect": r, "text": head_text, "color": rec.label_colors[i]})
				continue
			if kind == 2:
				if r.size.y < 7.0 or r.size.x < 30.0:
					continue
			elif r.size.x < min_box:
				continue
			if not view.intersects(r):
				continue
			var text: String = rec.label_texts[i]
			if counts and kind == 1 and rec.label_lines[i] > 0 and r.size.x >= 150.0:
				text += "   %s lines" % Fmt.num(rec.label_lines[i])
			var c := {"prio": r.size.x, "kind": kind, "color": rec.label_colors[i], "text": text,
				"max_w": r.size.x - 8.0, "size": fs}
			if kind == 2:
				# a legend sitting on the scope's top border
				c.size = clampi(int(r.size.y * 0.85), 8, fs)
				c.pos = r.position
			else:
				c.pos = Vector2(max(r.position.x, 0.0) + 2.0, max(r.position.y, 0.0) + 1.0)
				if kind == 1:
					c.size = max(fs - 1, 8)
					c.plain = headers
					# hang the name off the box's right edge: code lines end
					# ragged there, so a label covers less of them
					c.right = true
					c.pos = Vector2(minf(r.end.x, size.x) - 4.0, c.pos.y)
					# zoomed out, the folder's tab sits where the first file's
					# name goes: then the name moves just below it (r is the
					# file's header strip, 2% of its shorter side, so the box
					# itself is always tall enough)
					c.alts = [c.pos + Vector2(0, fs + 7), c.pos + Vector2(0, 2 * (fs + 7))]
			cand.append(c)
	_draw_heads(heads, fs)
	ViewCommon.draw_labels(o, ViewCommon.place_labels(cand, Settings.get_value("labels.max")))


## Folder names inside their header bands (folder headers mode). Bands
## never overlap, so no placement is needed: each name fits its band.
func _draw_heads(heads: Array, fs: int) -> void:
	var font := Style.font("ui", 600)
	var ink := Color(0.05, 0.055, 0.07)
	for h in heads:
		var r: Rect2 = h.rect
		var size := clampi(int(r.size.y * 0.7), 9, fs + 4)
		var left := maxf(r.position.x, 0.0) + 6.0
		var max_w := r.end.x - left - 6.0
		var text: String = h.text
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if tw > max_w:
			var keep := int(text.length() * max_w / tw) - 1
			if keep < 2:
				continue
			text = text.substr(0, keep) + "…"
		# centered in the band while it is name-sized; a tall band (zoomed
		# in far) keeps the name at its top, where headers read
		var band := minf(r.size.y, size * 2.2)
		var base_y := maxf(r.position.y, 0.0) + (band + size * 0.72) * 0.5
		base_y = minf(base_y, r.end.y - size * 0.25)  # never below the band
		_overlay.draw_string(font, Vector2(left, base_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)


# ---------------------------------------------------------------- relations

func set_arcs(list: Array) -> void:
	arcs = list
	_overlay.queue_redraw()


## Arcs as quadratic curves. Each end aims at the line it means — the
## import statement, the call, the declaration — while that line is still
## readable on screen; below that it aims at the whole box, and boxes
## smaller than relations.group_px snap to a grid, so arcs between the same
## small neighbourhoods merge into one thicker arc instead of a tangle.
func _draw_arcs() -> void:
	if arcs.is_empty():
		return
	var o := _overlay
	var view := Rect2(Vector2.ZERO, size).grow(200)
	var top_a: float = Settings.get_value("relations.opacity")
	var width: float = Settings.get_value("relations.width")
	var group: float = Settings.get_value("relations.group_px")
	var bend: float = Settings.get_value("relations.arc_height") * 0.5
	var arrows: bool = Settings.get_value("relations.arrows")
	var mark: bool = Settings.get_value("relations.line_marks")
	var bundles := {}
	var marks := {}
	for arc in arcs:
		var ea := _arc_end(arc.a, arc.get("box_a", arc.a), group)
		var eb := _arc_end(arc.b, arc.get("box_b", arc.b), group)
		var a: Vector2 = ea.point
		var b: Vector2 = eb.point
		if not view.has_point(a) and not view.has_point(b):
			continue
		if mark:
			for e in [ea, eb]:
				if e.precise:
					marks[[e.rect.position.x, e.rect.position.y, arc.color]] = {"r": e.rect, "c": arc.color}
		var key := [ea.key, eb.key, arc.color, arc.get("dashed", false)]
		if bundles.has(key):
			bundles[key].n += 1
		else:
			bundles[key] = {"a": a, "b": b, "c": arc.color, "n": 1, "kind": arc.get("kind", ""),
				"dashed": arc.get("dashed", false),
				"aw": arc.a, "bw": arc.b,
				# a sentence, so no one has to remember which way the arrow points
				"text": "%s %s %s" % [arc.get("an", "?"), arc.get("kind", "uses"), arc.get("bn", "?")]}
	# the lines an arc starts from and lands on, under the curves
	for m in marks.values():
		var r: Rect2 = m.r
		o.draw_rect(r, Color(m.c, 0.16))
		o.draw_rect(Rect2(r.position, Vector2(2.0, r.size.y)), Color(m.c, 0.75))
	var alpha: float = clamp(60.0 / max(bundles.size(), 1), top_a * 0.2, top_a)
	for bd in bundles.values():
		var a: Vector2 = bd.a
		var b: Vector2 = bd.b
		var d := b - a
		var len := d.length()
		if len < 2.0:
			continue
		# bend every arc the same way, so in- and outgoing pairs separate
		var ctrl: Vector2 = (a + b) * 0.5 + Vector2(-d.y, d.x) / len * min(len * bend, 220.0)
		var pts := PackedVector2Array()
		for i in 21:
			var t := i / 20.0
			pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
		var c: Color = bd.c
		var w: float = width * (1.0 + log(float(bd.n)) / log(2.0) * 0.6)
		var ca := Color(c, min(alpha * (1.0 + 0.15 * (bd.n - 1)), top_a))
		var hovered := _arc_lines.size() == _arc_hover
		_arc_lines.append({"pts": pts, "aw": bd.aw, "bw": bd.bw, "key": "%s|%s" % [bd.aw, bd.bw],
			"text": bd.text if bd.n == 1 else "%d %s arcs · %s" % [bd.n, bd.kind, bd.text]})
		if hovered:
			_stroke(pts, Color(c, 1.0), w + 2.0, bd.dashed)
		_stroke(pts, ca, w, bd.dashed)
		if arrows:
			# arrowhead at the imported/called end
			var tip := pts[20]
			var back := tip - pts[17]
			if back.length() > 0.5:
				var dir := back.normalized()
				var side := Vector2(-dir.y, dir.x)
				var ac := Color(c, min(ca.a * 1.5, 1.0))
				var s := 6.0 + w * 1.5
				o.draw_primitive(PackedVector2Array([tip, tip - dir * s + side * s * 0.45, tip - dir * s - side * s * 0.45]),
					PackedColorArray([ac, ac, ac]), PackedVector2Array())
		o.draw_circle(pts[0], 1.5 + w * 0.5, ca)


## Folder headers mode: what is under the cursor, like a file manager's
## tooltip — name, size, and for folders what they hold.
func _draw_hover_tip() -> void:
	var fs: int = Settings.get_value("labels.font_size")
	var bold := Style.font("ui", 600)
	var font := Style.font("ui", 500)
	var rows := [[str(hover.get("name", "")), bold, Style.color("text")]]
	var facts := "%s lines" % Fmt.num(hover.get("lines", 0))
	if hover.get("kind", "") == "dir":
		facts += " · %s files · %s folders" % [Fmt.num(hover.get("files", 0)), Fmt.num(hover.get("dirs", 0))]
	rows.append([facts, font, Style.color("text2")])
	if hover.has("folder"):
		rows.append(["in " + str(hover.folder.name), font, Style.color("text3")])
	rows.append(["double-click to zoom", font, Style.color("text3")])
	var w := 0.0
	for r in rows:
		w = maxf(w, (r[1] as Font).get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var lh := fs + 5.0
	var box := Rect2(_last_mouse + Vector2(16, 14), Vector2(w + 16, lh * rows.size() + 8))
	if box.end.x > size.x:
		box.position.x = _last_mouse.x - box.size.x - 10
	if box.end.y > size.y:
		box.position.y = _last_mouse.y - box.size.y - 10
	_overlay.draw_rect(box, Color(Style.color("raised"), 0.96))
	_outline(box, Color(Style.color("text3"), 0.5), 1.0)
	for i in rows.size():
		var r: Array = rows[i]
		_overlay.draw_string(r[1], box.position + Vector2(8, 4 + lh * i + fs), r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, r[2])


## Tooltip for the arc under the cursor: its ends and what kind it is.
func _draw_arc_tip() -> void:
	if _arc_hover < 0 or _arc_hover >= _arc_lines.size():
		return
	var text: String = _arc_lines[_arc_hover].text + "   ·   click to follow"
	var fs: int = Settings.get_value("labels.font_size")
	var font := Style.font("ui", 500)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var r := Rect2(_last_mouse + Vector2(14, 10), Vector2(tw + 14, fs + 10))
	if r.end.x > size.x:
		r.position.x = _last_mouse.x - r.size.x - 8
	_overlay.draw_rect(r, Color(Style.color("raised"), 0.96))
	_overlay.draw_string(font, r.position + Vector2(7, fs + 2), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Style.color("text"))


## Follows an arc to its far end; clicking the same arc again comes back.
## The view travels, the selection stays: an arc is a route, not a choice.
func follow_arc(i: int) -> void:
	var arc: Dictionary = _arc_lines[i]
	jumped.emit()
	if _arc_back.get("key", "") == arc.key:
		var back: Dictionary = _arc_back
		_arc_back = {}
		fly_to(back.cx, back.cy, back.zoom)
		return
	var here := Vector2(size.x * 0.5, size.y * 0.5)
	var a: Rect2 = rect_to_screen(arc.aw)
	var b: Rect2 = rect_to_screen(arc.bw)
	var far: Array = arc.bw if a.get_center().distance_to(here) < b.get_center().distance_to(here) else arc.aw
	_arc_back = {"key": arc.key, "cx": cx, "cy": cy, "zoom": zoom}
	# a line-sized end deserves reading distance, a box just fits the view
	if far[3] * zoom < 6.0 and far[3] > 0.0:
		focus_line(far)
	else:
		var t := fit_rect(far)
		fly_to(t[0], t[1], t[2])


## One arc's line: solid, or dashed when the kind is drawn as a style
## rather than a colour.
func _stroke(pts: PackedVector2Array, c: Color, w: float, dashed: bool) -> void:
	if not dashed:
		_overlay.draw_polyline(pts, c, w, true)
		return
	var on := 8.0
	var off := 6.0
	var walked := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		var at := 0.0
		while at < seg:
			var phase := fmod(walked + at, on + off)
			var run: float = minf(seg - at, (on - phase) if phase < on else (on + off - phase))
			if phase < on:
				_overlay.draw_line(a.lerp(b, at / seg), a.lerp(b, minf(at + run, seg) / seg), c, w, true)
			at += maxf(run, 0.5)
		walked += seg


## The arc nearest to the cursor, within a few pixels (-1 = none).
func _pick_arc(p: Vector2) -> int:
	var best := -1
	var best_d := 6.0
	for i in _arc_lines.size():
		var pts: PackedVector2Array = _arc_lines[i].pts
		for k in range(1, pts.size()):
			var d := Geometry2D.get_closest_point_to_segment(p, pts[k - 1], pts[k]).distance_to(p)
			if d < best_d:
				best_d = d
				best = i
	return best


## Focus + context: while search hits or relation arcs are on screen, dim
## everything but them (and the selection).
func _update_dim() -> void:
	var amount: float = Settings.get_value("look.focus_dim")
	var focus: bool = Settings.get_value("viewport.focus") and selection_rect.size() == 4
	var active: bool = amount > 0.0 and (focus \
		or (not hit_files.is_empty() and Settings.get_value("viewport.search_hits")) \
		or not arcs.is_empty())
	_dim.visible = active
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if not active:
		return
	var f := get_window().content_scale_factor
	_mask_vp.size = Vector2i((size * f).round())
	_mask.size = size * f
	(_dim.material as ShaderMaterial).set_shader_parameter("amount", amount)
	(_dim.material as ShaderMaterial).set_shader_parameter("tint", Style.color("bg"))
	_mask.queue_redraw()


func _draw_mask() -> void:
	var f := get_window().content_scale_factor
	var keep := func(r: Array):
		var s := rect_to_screen(r)
		_mask.draw_rect(Rect2(s.position * f, s.size * f).grow(2.0 * f), Color.WHITE)
	_mask.draw_rect(Rect2(Vector2.ZERO, _mask.size), Color.BLACK)
	if Settings.get_value("viewport.focus") and selection_rect.size() == 4:
		keep.call(selection_rect)   # the selection alone: everything else dims
		return
	if Settings.get_value("viewport.search_hits"):
		for r in hit_files:
			keep.call(r)
	if not arcs.is_empty():
		for arc in arcs:
			keep.call(arc.a)
			keep.call(arc.b)
	if selection_rect.size() == 4:
		keep.call(selection_rect)


## An endpoint's bundling key: its snapped cell centre when the box is
## small on screen, else null (drawn on its own).
## One end of an arc: the exact line while it is readable, else the box,
## else a grid cell shared with its small neighbours.
func _arc_end(line: Array, box: Array, group: float) -> Dictionary:
	var lr := rect_to_screen(line)
	if line != box and lr.size.y >= LINE_ANCHOR_PX and lr.size.x >= 6.0:
		return {"point": Vector2(lr.position.x + minf(lr.size.x, 14.0), lr.get_center().y),
			"rect": lr, "precise": true, "key": [lr.position.x, lr.position.y]}
	# no readable line: aim at the head of the box (where a function's name
	# and a file's first line are), not at the middle of its body
	var br := rect_to_screen(box)
	var head := Vector2(br.position.x + minf(br.size.x * 0.35, 30.0), br.position.y + minf(br.size.y * 0.25, 12.0))
	var k: Variant = _group_key(br.get_center(), br, group)
	return {"point": k if k is Vector2 else head, "rect": br, "precise": false, "key": k if k is Vector2 else head}


func _group_key(p: Vector2, r: Rect2, group: float) -> Variant:
	if group <= 0.0 or max(r.size.x, r.size.y) >= group:
		return null
	var cell := group * 2.0
	return ((p / cell).floor() + Vector2(0.5, 0.5)) * cell


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
