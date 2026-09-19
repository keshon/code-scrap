class_name CityView
extends Control
## The 3D city: the same map extruded — every directory is a plinth, every
## file a building standing on it, code projected onto the roofs.
##
## World units match the 2D map (x, y on the ground, heights up). Render space
## is world × S around a floating origin that follows the camera target, so
## float32 precision holds at street level.

signal hovered(info: Dictionary)
signal selected(node_id: int)
signal exited(cx: float, cy: float, zoom: float)

const S := 1000.0            # render units per world unit
const TILE_PX := 256.0
const MAX_TILES := 240
const MAX_CACHED := 600
const FOV := 50.0
const LABEL_FONT_SIZE := 12
const HIT_COLOR := Color(0.86, 0.9, 0.25)
const MIN_PITCH := 0.12
const MAX_PITCH := 1.56

var client: ScrapClient

# camera (world units, float64)
var tx := 0.5                # target on the ground
var ty := 0.3
var dist := 1.0              # camera distance from the target
var yaw := 0.0
var pitch := 0.95
var _goal := {}              # smoothed camera goal: tx, ty, dist, yaw, pitch
var _tween := {}             # timed transition (enter/exit/fly)

var gen := -1
var world := [0.0, 0.0, 1.0, 0.625]
var max_z := 24
var max_top := 0.05

var _vpc: SubViewportContainer
var _vp: SubViewport
var _root3d: Node3D
var _cam: Camera3D
var _env: Environment
var _tiles_root: Node3D
var _overlay: Control
var _cube: ArrayMesh
var _shader: Shader
var _origin := [0.5, 0.3]    # floating origin (world x, y)
var _tiles := {}             # Vector3i -> Rec
var _dirty := true
var _frame := 0
var _last_request := ""
var _label_font: Font

var _pressed := -1
var _dragging := false
var _press_pos := Vector2.ZERO
var _last_mouse := Vector2.ZERO
var _pick_pending := false
var _pick_at := 0.0
var hover := {}
var selection := {}          # {rect, top}
var hit_files := []          # [x, y, w, h, top]
var current_hit := {}        # {rect, top}


class Rec:
	var key: Vector3i
	var node: Node3D
	var gen: int
	var used: int
	var label_ids: PackedInt32Array
	var label_kinds: PackedByteArray
	var label_data: PackedFloat64Array  # world x, y, w, h, top
	var label_texts: PackedStringArray


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	_label_font = load("res://fonts/Go-Medium.ttf")
	_shader = load("res://shaders/city.gdshader")

	_vpc = SubViewportContainer.new()
	_vpc.stretch = true
	_vpc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vpc)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.anisotropic_filtering_level = Viewport.ANISOTROPY_8X
	_vpc.add_child(_vp)
	_root3d = Node3D.new()
	_vp.add_child(_root3d)

	_cam = Camera3D.new()
	_cam.fov = FOV
	_root3d.add_child(_cam)
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.086, 0.09, 0.106)
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_light_color = Color(0.086, 0.09, 0.106)
	_env.fog_density = 1.0
	var we := WorldEnvironment.new()
	we.environment = _env
	_root3d.add_child(we)
	_tiles_root = Node3D.new()
	_root3d.add_child(_tiles_root)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_cube = _make_cube()
	resized.connect(func(): _dirty = true)


func attach(c: ScrapClient) -> void:
	client = c
	client.hello.connect(_on_hello)
	client.tile_received.connect(_on_tile)
	client.reply.connect(_on_reply)


## Unit cube [0,1]³ without a bottom face; every face has its own 0..1 UVs
## (roof: u = x, v = z; walls: v = height, 1 at the top).
func _make_cube() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var faces := [
		# normal, corners (clockwise seen from outside), uvs
		[Vector3.UP, [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)], [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]],
		[Vector3.BACK, [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1)], [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]],
		[Vector3.FORWARD, [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, 0)], [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]],
		[Vector3.RIGHT, [Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(1, 0, 0)], [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]],
		[Vector3.LEFT, [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1)], [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]],
	]
	for f in faces:
		var c: Array = f[1]
		var t: Array = f[2]
		for i in [0, 1, 2, 0, 2, 3]:  # keep clockwise: Godot's front faces
			v.append(c[i])
			n.append(f[0])
			uv.append(t[i])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


# ---------------------------------------------------------------- camera

func _ppu(d: float) -> float:
	## pixels per world unit at distance d (world units) from the camera
	return size.y / (2.0 * d * tan(deg_to_rad(FOV) * 0.5))


func _dist_for_zoom(zoom: float) -> float:
	return size.y / (2.0 * zoom * tan(deg_to_rad(FOV) * 0.5))


## Enter from the 2D map: start straight above the same view, then tilt.
func enter(cx: float, cy: float, zoom: float) -> void:
	tx = cx
	ty = cy
	dist = _dist_for_zoom(zoom)
	pitch = MAX_PITCH
	_goal = {}
	_tween = {"from": {"pitch": MAX_PITCH, "yaw": yaw, "dist": dist}, "to": {"pitch": 0.95, "yaw": yaw, "dist": dist * 1.1}, "t": 0.0, "dur": 0.8}
	_dirty = true


## Leave to 2D: tilt back up, then report the equivalent flat camera.
func leave() -> void:
	_goal = {}
	_tween = {"from": {"pitch": pitch, "yaw": yaw, "dist": dist}, "to": {"pitch": MAX_PITCH, "yaw": _nearest_north(yaw), "dist": dist}, "t": 0.0, "dur": 0.6, "exit": true}


func _nearest_north(a: float) -> float:
	return round(a / TAU) * TAU


func home() -> void:
	var r: Array = world
	_fly_rect(r)


func _fly_rect(r: Array, margin := 1.25) -> void:
	var w: float = max(r[2], r[3] * size.x / max(size.y, 1.0)) * margin
	var d := _dist_for_zoom(size.x / w)
	_goal = {}
	_tween = {"from": {"tx": tx, "ty": ty, "dist": dist, "pitch": pitch, "yaw": yaw},
		"to": {"tx": r[0] + r[2] * 0.5, "ty": r[1] + r[3] * 0.5, "dist": d, "pitch": pitch, "yaw": yaw},
		"t": 0.0, "dur": 0.9, "arc": true}


func focus_rect(r: Array, _top: float) -> void:
	_fly_rect(r, 1.6)


## Flies to a text line so it reads at about line_px on a steep camera.
func focus_line(r: Array, line_px := 16.0) -> void:
	var d := _dist_for_zoom(line_px / max(r[3], 1e-12))
	_goal = {}
	_tween = {"from": {"tx": tx, "ty": ty, "dist": dist, "pitch": pitch, "yaw": yaw},
		"to": {"tx": r[0] + r[2] * 0.5, "ty": r[1] + r[3] * 0.5, "dist": d, "pitch": max(pitch, 1.15), "yaw": yaw},
		"t": 0.0, "dur": 1.1, "arc": true}


func _step(dt: float) -> void:
	if not _tween.is_empty():
		var tw := _tween
		tw.t = min(1.0, tw.t + dt / tw.dur)
		var e: float = tw.t * tw.t * (3.0 - 2.0 * tw.t)
		for k in tw.to:
			var a: float = tw.from[k]
			var b: float = tw.to[k]
			if k == "dist":
				set(k, exp(lerp(log(a), log(b), e)))
			else:
				set(k, lerp(a, b, e))
		if tw.get("arc", false):
			# rise while travelling so long flights keep context
			var travel: float = Vector2(tw.to.tx - tw.from.tx, tw.to.ty - tw.from.ty).length()
			dist *= 1.0 + sin(PI * e) * min(travel / max(min(tw.from.dist, tw.to.dist), 1e-12), 4.0) * 0.5
		if tw.t >= 1.0:
			_tween = {}
			if tw.get("exit", false):
				exited.emit(tx, ty, size.y / (2.0 * dist * tan(deg_to_rad(FOV) * 0.5)))
		_dirty = true
	elif not _goal.is_empty():
		var k := 1.0 - exp(-dt * 16.0)
		var done := true
		for key in _goal:
			var cur: float = get(key)
			var goal: float = _goal[key]
			var nv: float
			if key == "dist":
				nv = exp(lerp(log(cur), log(goal), k))
			else:
				nv = lerp(cur, goal, k)
			set(key, nv)
			if abs(nv - goal) > abs(goal) * 1e-4 + 1e-12:
				done = false
		if done:
			_goal = {}
		_dirty = true


func _goal_set(key: String, value: float) -> void:
	if _goal.is_empty():
		_goal = {"tx": tx, "ty": ty, "dist": dist, "yaw": yaw, "pitch": pitch}
	_goal[key] = value


func _goal_get(key: String) -> float:
	return _goal.get(key, get(key))


func _update_camera() -> void:
	# floating origin: float32 error grows with |coordinate|, detail shrinks
	# with distance, so recentre long before the error nears a pixel
	if max(abs(tx - _origin[0]), abs(ty - _origin[1])) > dist * 500.0:
		_origin = [tx, ty]
	var cp := cos(pitch)
	var offset := Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp) * dist * S
	var target := Vector3((tx - _origin[0]) * S, 0.0, (ty - _origin[1]) * S)
	_cam.position = target + offset
	_cam.look_at(target, Vector3.UP if pitch < MAX_PITCH - 0.001 else Vector3(-sin(yaw), 0, -cos(yaw)))
	var r := dist * S
	_cam.near = max(r * 0.002, 1e-6)
	_cam.far = r * 60.0 + 10.0
	_env.fog_depth_begin = r * 2.0
	_env.fog_depth_end = r * 14.0


func _process(dt: float) -> void:
	if not visible:
		return
	_frame += 1
	_step(dt)
	if _pick_pending and Time.get_ticks_msec() / 1000.0 >= _pick_at:
		_pick_pending = false
		_send_pick()
	if _dirty and gen >= 0:
		_dirty = false
		_update_camera()
		_update_tiles()
		_overlay.queue_redraw()


# ---------------------------------------------------------------- tiles

func _on_hello(info: Dictionary) -> void:
	gen = int(info.gen)
	world = info.world
	max_z = int(info.maxZ)
	max_top = float(info.get("maxTop", 0.05))
	_last_request = ""
	_dirty = true


func _world_to_render(x: float, h: float, y: float) -> Vector3:
	return Vector3((x - _origin[0]) * S, h * S, (y - _origin[1]) * S)


func _update_tiles() -> void:
	var planes := _cam.get_frustum()
	var cam_pos := _cam.global_position
	var chosen := []
	var queue := [Vector3i(0, 0, 0)]
	var wx0: float = world[0]
	var wy0: float = world[1]
	var wx1: float = world[0] + world[2]
	var wy1: float = world[1] + world[3]
	while not queue.is_empty():
		var k: Vector3i = queue.pop_front()
		var ts := 1.0 / (1 << k.x)
		var x0: float = k.y * ts
		var y0: float = k.z * ts
		if x0 > wx1 or y0 > wy1 or x0 + ts < wx0 or y0 + ts < wy0:
			continue
		var a := _world_to_render(x0, 0.0, y0)
		var b := _world_to_render(x0 + ts, max_top, y0 + ts)
		if _outside(planes, a, b):
			continue
		var closest := Vector3(clamp(cam_pos.x, a.x, b.x), clamp(cam_pos.y, a.y, b.y), clamp(cam_pos.z, a.z, b.z))
		var d: float = max(cam_pos.distance_to(closest) / S, 1e-12)
		var px := ts * _ppu(d)
		if px > TILE_PX * 1.15 and k.x < max_z and chosen.size() + queue.size() + 4 <= MAX_TILES:
			for j in 2:
				for i in 2:
					queue.append(Vector3i(k.x + 1, k.y * 2 + i, k.z * 2 + j))
		else:
			chosen.append([d, k])
	chosen.sort_custom(func(p, q): return p[0] < q[0])

	var shown := {}
	var keys := []
	for c in chosen:
		var key: Vector3i = c[1]
		var rec: Rec = _tiles.get(key)
		if rec != null and rec.gen == gen:
			shown[key] = rec
			continue
		keys.append([key.x, key.y, key.z])
		if rec != null:
			shown[key] = rec
		else:
			for up in range(1, 6):
				if key.x - up < 0:
					break
				var ak := Vector3i(key.x - up, key.y >> up, key.z >> up)
				if _tiles.has(ak):
					shown[ak] = _tiles[ak]
					break
	var sig := str(gen) + ":" + str(keys)
	if sig != _last_request and client != null:
		_last_request = sig
		client.request_tiles(gen, keys, 3)

	for key: Vector3i in _tiles:
		var rec: Rec = _tiles[key]
		var vis := shown.has(key)
		rec.node.visible = vis
		if vis:
			rec.used = _frame
			var ts := 1.0 / (1 << key.x)
			rec.node.position = _world_to_render(key.y * ts, 0.0, key.z * ts)
			# finer levels stand a hair taller, so a coarse fallback tile under
			# them never z-fights with their coplanar roofs
			rec.node.scale = Vector3(ts * S, ts * S * (1.0 + key.x * 0.004), ts * S)
	if _tiles.size() > MAX_CACHED:
		var recs := _tiles.values()
		recs.sort_custom(func(p, q): return p.used < q.used)
		for i in _tiles.size() - int(MAX_CACHED * 0.8):
			var rec: Rec = recs[i]
			if not rec.node.visible:
				rec.node.queue_free()
				_tiles.erase(rec.key)


func _outside(planes: Array[Plane], a: Vector3, b: Vector3) -> bool:
	for p in planes:
		var all_out := true
		for i in 8:
			var c := Vector3(b.x if i & 1 else a.x, b.y if i & 2 else a.y, b.z if i & 4 else a.z)
			if not p.is_point_over(c):
				all_out = false
				break
		if all_out:
			return true
	return false


func _on_tile(t: Dictionary) -> void:
	if int(t.gen) != gen or int(t.dim) != 3:
		return
	var key := Vector3i(t.z, t.x, t.y)
	var old: Rec = _tiles.get(key)
	if old != null:
		old.node.queue_free()
	var rec := Rec.new()
	rec.key = key
	rec.gen = gen
	rec.used = _frame
	var node := Node3D.new()
	var ids: PackedInt32Array = t.ids
	var ts := 1.0 / (1 << int(t.z))
	if ids.size() > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _cube
		mm.instance_count = ids.size()
		mm.buffer = t.buffer
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = _shader
		mat.set_shader_parameter("tile_scale", ts * S)
		if t.has("code"):
			var img: Image = t.code
			img.generate_mipmaps()
			mat.set_shader_parameter("code_tex", ImageTexture.create_from_image(img))
			mat.set_shader_parameter("has_code", true)
		mmi.material_override = mat
		node.add_child(mmi)
	var ox: float = t.x * ts
	var oy: float = t.y * ts
	for l in t.labels:
		var r: Rect2 = l.rect
		rec.label_ids.append(l.id)
		rec.label_kinds.append(l.kind)
		rec.label_data.append_array([ox + r.position.x * ts, oy + r.position.y * ts, r.size.x * ts, r.size.y * ts, l.top * ts])
		rec.label_texts.append(l.text)
	rec.node = node
	node.visible = false
	_tiles_root.add_child(node)
	_tiles[key] = rec
	_dirty = true


# ---------------------------------------------------------------- input

func _ground_point(p: Vector2) -> Array:
	## world (x, y) under a screen point on the ground plane, or [] if none
	var o := _cam.project_ray_origin(p)
	var n := _cam.project_ray_normal(p)
	if n.y > -1e-6:
		return []
	var t := -o.y / n.y
	var hit := o + n * t
	return [hit.x / S + _origin[0], hit.z / S + _origin[1]]


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var f := 1.0 / 1.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
			if mb.factor > 0.0:
				f = pow(f, mb.factor)
			_tween = {}
			var gp := _ground_point(mb.position)
			var d0 := _goal_get("dist")
			var d1: float = clamp(d0 * f, 1e-9, 20.0)
			_goal_set("dist", d1)
			if not gp.is_empty():
				# zoom toward the point under the cursor
				_goal_set("tx", gp[0] + (_goal_get("tx") - gp[0]) * d1 / d0)
				_goal_set("ty", gp[1] + (_goal_get("ty") - gp[1]) * d1 / d0)
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if mb.pressed:
				grab_focus()
				_pressed = mb.button_index
				_dragging = false
				_press_pos = mb.position
				if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT and hover.has("rect"):
					focus_rect(hover.rect, float(hover.get("top", 0.0)))
			else:
				if _pressed == MOUSE_BUTTON_LEFT and not _dragging and hover.has("rect"):
					select(int(hover.node), hover.rect, float(hover.get("top", 0.0)))
				_pressed = -1
				_dragging = false
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		var prev := _last_mouse
		_last_mouse = mm.position
		if _pressed >= 0:
			if not _dragging and mm.position.distance_to(_press_pos) > 4.0:
				_dragging = true
			if _dragging:
				_tween = {}
				_goal = {}
				if _pressed == MOUSE_BUTTON_LEFT and not mm.shift_pressed:
					var a := _ground_point(prev)
					var b := _ground_point(mm.position)
					if not a.is_empty() and not b.is_empty():
						tx -= b[0] - a[0]
						ty -= b[1] - a[1]
				else:
					yaw -= mm.relative.x * 0.006
					pitch = clamp(pitch + mm.relative.y * 0.005, MIN_PITCH, MAX_PITCH)
				_dirty = true
		_schedule_pick()


func _schedule_pick() -> void:
	if not _pick_pending:
		_pick_pending = true
		_pick_at = Time.get_ticks_msec() / 1000.0 + 0.04


func _send_pick() -> void:
	if client == null or gen < 0:
		return
	var o := _cam.project_ray_origin(_last_mouse)
	var n := _cam.project_ray_normal(_last_mouse)
	var ray := [o.x / S + _origin[0], o.y / S, o.z / S + _origin[1], n.x, n.y, n.z]
	client.request("pickRay", {"ray": ray})


func _on_reply(_id: int, data: Dictionary) -> void:
	if visible and data.get("op") == "pick":
		hover = data
		hovered.emit(data)
		_overlay.queue_redraw()


func select(id: int, rect: Array, top: float) -> void:
	selection = {"rect": rect, "top": top}
	selected.emit(id)
	_overlay.queue_redraw()


# ---------------------------------------------------------------- overlay

func _project_roof(r: Array, top: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in [[0, 0], [1, 0], [1, 1], [0, 1]]:
		var p := _world_to_render(r[0] + r[2] * c[0], top, r[1] + r[3] * c[1])
		if _cam.is_position_behind(p):
			return PackedVector2Array()
		pts.append(_cam.unproject_position(p))
	return pts


func _draw_overlay() -> void:
	var o := _overlay
	for f in hit_files:
		var pts := _project_roof(f, f[4] if f.size() > 4 else 0.0)
		if pts.size() == 4:
			o.draw_colored_polygon(pts, Color(HIT_COLOR, 0.35))
	if not current_hit.is_empty():
		var pts := _project_roof(current_hit.rect, current_hit.top)
		if pts.size() == 4:
			o.draw_colored_polygon(pts, Color(HIT_COLOR, 0.5))
	_draw_labels()
	if hover.has("rect") and int(hover.get("node", -1)) >= 0:
		var pts := _project_roof(hover.rect, float(hover.get("top", 0.0)))
		if pts.size() == 4:
			pts.append(pts[0])
			o.draw_polyline(pts, Color(0.55, 0.75, 1.0, 0.8), 1.0)
	if not selection.is_empty():
		var pts := _project_roof(selection.rect, selection.top)
		if pts.size() == 4:
			pts.append(pts[0])
			o.draw_polyline(pts, Color(0.3, 0.55, 1.0), 2.0)


func _draw_labels() -> void:
	var o := _overlay
	var seen := {}
	var cand := []
	var view := Rect2(Vector2.ZERO, size)
	for key: Vector3i in _tiles:
		var rec: Rec = _tiles[key]
		if not rec.node.visible:
			continue
		for i in rec.label_ids.size():
			var id := rec.label_ids[i]
			if seen.has(id) or rec.label_kinds[i] == 2:
				continue
			seen[id] = true
			var j := i * 5
			var p0 := _world_to_render(rec.label_data[j], rec.label_data[j + 4], rec.label_data[j + 1])
			var p1 := _world_to_render(rec.label_data[j] + rec.label_data[j + 2], rec.label_data[j + 4], rec.label_data[j + 1])
			if _cam.is_position_behind(p0) or _cam.is_position_behind(p1):
				continue
			var s0 := _cam.unproject_position(p0)
			var s1 := _cam.unproject_position(p1)
			var w := s0.distance_to(s1)
			if w < 40.0 or not view.has_point(s0):
				continue
			cand.append([w, s0, rec.label_texts[i], _cam.global_position.distance_to(p0)])
	cand.sort_custom(func(a, b): return a[0] > b[0])
	var placed: Array[Rect2] = []
	var budget := 350
	for c in cand:
		if budget <= 0:
			break
		var text: String = c[2]
		var fs := LABEL_FONT_SIZE
		var tw := _label_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var max_w: float = c[0] - 8.0
		if tw > max_w:
			var keep := int(text.length() * max_w / tw) - 1
			if keep < 3:
				continue
			text = text.substr(0, keep) + "…"
			tw = _label_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos: Vector2 = c[1] + Vector2(2, -fs - 6)
		var pill := Rect2(pos, Vector2(tw + 6.0, fs + 4.0))
		var hit := false
		for p in placed:
			if p.intersects(pill):
				hit = true
				break
		if hit:
			continue
		placed.append(pill)
		budget -= 1
		o.draw_rect(pill, Color(0.07, 0.075, 0.09, 0.85))
		o.draw_string(_label_font, pos + Vector2(3.0, fs * 0.95 + 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.93, 0.94, 0.96))


func set_search_results(files: Array) -> void:
	hit_files = files
	_overlay.queue_redraw()


func clear_search() -> void:
	hit_files = []
	current_hit = {}
	_overlay.queue_redraw()
