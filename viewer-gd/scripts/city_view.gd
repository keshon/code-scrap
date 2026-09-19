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
const MIN_PITCH := 0.12
const MAX_PITCH := 1.56

var client: ScrapClient

# camera (world units, float64)
var tx := 0.5                # orbit target: ground position…
var ty := 0.3
var th := 0.0                # …and height (it rides on the roofs)
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
var _sky_mat: ShaderMaterial
var _ground: MeshInstance3D
var _reading := 0.0          # 0..1: how readable the code under the target is (reading assist)
var _reading_goal := 0.0
var _labels_root: Node3D
var _label_of := {}          # node id -> Label3D shown last frame
var _label_free: Array[Label3D] = []
var _text: TextLayer
var _plane: ArrayMesh
var _sel_xray: MeshInstance3D
var _sel_fill: MeshInstance3D
var _hov_xray: MeshInstance3D
var _HL_SHADERS := {
	"outline": preload("res://shaders/highlight_outline.gdshader"),
	"xray": preload("res://shaders/highlight_xray.gdshader"),
}
var _arcs_mesh: MeshInstance3D
var _arcs_origin := []
var arcs := []

var _drag := {}              # active mouse binding: {action, click, button}
var _dragging := false
var _f := 1.0                # physical pixels per UI pixel (UI scale)
var _fov := 50.0
var _press_pos := Vector2.ZERO
var _last_mouse := Vector2.ZERO
var _pick_pending := false
var _pick_at := 0.0
var hover := {}
var _hover_ray := []         # world ray of the pending pick: ox, oy, oz, dx, dy, dz
var _floor_cam := 0.0        # roof height under the camera (from the server)
var _floor_target := 0.0     # roof height under the target
var _heights_at := 0.0
var _heights_req := -1
var selection := {}          # {rect, top}

# diagnostics (HUD)
var stat_shown := 0
var stat_missing := 0
var stat_evicted := 0
var stat_gens := 0
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
	var label_colors: PackedColorArray
	var blocks: Array  # text blocks in world units: {file, col, seg, rows, x, y, w, h, top}


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	_label_font = Style.font("ui", 500)
	_shader = load("res://shaders/city.gdshader")
	_fov = Settings.get_value("camera.fov")

	# the 3D view renders at physical resolution: the container is f times
	# the control's size and scaled back down by 1/f, so a UI scale above 1
	# does not upscale (blur) the city
	_vpc = SubViewportContainer.new()
	_vpc.stretch = true
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
	_cam.fov = _fov
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
	var sky := Sky.new()
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = load("res://shaders/sky.gdshader")
	sky.sky_material = _sky_mat
	_env.sky = sky
	_ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	_ground.mesh = plane
	_ground.material_override = ShaderMaterial.new()
	(_ground.material_override as ShaderMaterial).shader = load("res://shaders/grid3d.gdshader")
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3d.add_child(_ground)
	_tiles_root = Node3D.new()
	_root3d.add_child(_tiles_root)
	_labels_root = Node3D.new()
	_root3d.add_child(_labels_root)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_cube = _make_cube()
	_plane = _make_plane()
	_sel_fill = _highlight("res://shaders/highlight_fill.gdshader", {})
	_sel_xray = _highlight("res://shaders/highlight_outline.gdshader", {})
	_hov_xray = _highlight("res://shaders/highlight_outline.gdshader", {})
	_apply_settings()
	var im := ImmediateMesh.new()
	_arcs_mesh = MeshInstance3D.new()
	_arcs_mesh.mesh = im
	var am := StandardMaterial3D.new()
	am.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	am.vertex_color_use_as_albedo = true
	am.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	am.no_depth_test = true  # arcs read through buildings, like the x-ray outline
	am.cull_mode = BaseMaterial3D.CULL_DISABLED
	_arcs_mesh.material_override = am
	_arcs_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root3d.add_child(_arcs_mesh)
	resized.connect(_fit_viewport)
	get_window().size_changed.connect(_fit_viewport)
	_fit_viewport()
	Settings.changed.connect(func(_id, _v): _apply_settings())
	Settings.reloaded.connect(_apply_settings)
	Style.theme_changed.connect(_apply_theme)
	_apply_theme()


func _apply_theme() -> void:
	_label_font = Style.font("ui", 500)
	var bg := Style.color("bg")
	var horizon := bg.lerp(Style.color("text3"), 0.12)
	_env.background_color = bg
	_sky_mat.set_shader_parameter("top_color", bg)
	_sky_mat.set_shader_parameter("horizon_color", horizon)
	_apply_ground()
	_overlay.queue_redraw()


## Ground grid and horizon glow on, or the plain background.
func _apply_ground() -> void:
	var on: bool = Settings.get_value("viewport.grid")
	var bg := Style.color("bg")
	_env.background_mode = Environment.BG_SKY if on else Environment.BG_COLOR
	_env.fog_light_color = bg.lerp(Style.color("text3"), 0.12) if on else bg
	_ground.visible = on
	(_ground.material_override as ShaderMaterial).set_shader_parameter("dot_color", Color(Style.color("text3"), 0.3))


func _fit_viewport() -> void:
	var f := get_window().content_scale_factor
	_vpc.scale = Vector2.ONE / f
	_vpc.position = Vector2.ZERO
	_vpc.size = size * f
	if f != _f:
		_f = f
		_apply_settings()  # highlight widths are in physical pixels
	_dirty = true


## Re-reads the settings this view uses; cheap, so any change calls it.
func _apply_settings() -> void:
	_fov = Settings.get_value("camera.fov")
	_cam.fov = _fov
	if _ground:
		_apply_ground()
	var sel: Color = Settings.get_value("highlight.selection")
	var hov: Color = Settings.get_value("highlight.hover")
	# selection / hover styles: outline (depth tested), xray (through
	# everything) or off; the roof fill is a separate tint
	var sm := _sel_xray.material_override as ShaderMaterial
	var hm := _hov_xray.material_override as ShaderMaterial
	sm.shader = _HL_SHADERS.get(Settings.get_value("highlight.style"), _HL_SHADERS.outline)
	hm.shader = _HL_SHADERS.get(Settings.get_value("highlight.hover_style"), _HL_SHADERS.outline)
	sm.set_shader_parameter("color", sel)
	sm.set_shader_parameter("width_px", float(Settings.get_value("lines.selected_width")) * _f)
	sm.set_shader_parameter("face_alpha", 0.0)
	hm.set_shader_parameter("color", Color(hov, 0.55))
	hm.set_shader_parameter("width_px", float(Settings.get_value("lines.hover_width")) * _f)
	hm.set_shader_parameter("face_alpha", 0.0)
	(_sel_fill.material_override as ShaderMaterial).set_shader_parameter("color",
		Color(sel, float(Settings.get_value("highlight.fill")) * 0.6))
	_arcs_origin = []  # rebuild arcs with the current opacity
	_dirty = true
	if _overlay:
		_overlay.queue_redraw()


## Screen point (UI pixels) → viewport pixels, for camera rays.
func _vp_pt(p: Vector2) -> Vector2:
	return p * _f


## Render-space point → screen point in UI pixels.
func _unproject(p: Vector3) -> Vector2:
	return _cam.unproject_position(p) / _f


func set_arcs(list: Array) -> void:
	arcs = list
	_arcs_origin = []  # force a rebuild
	_dirty = true


## Arcs are rebuilt when they change or the floating origin moves.
func _update_arcs() -> void:
	_arcs_mesh.visible = Settings.get_value("viewport.arcs")
	if _arcs_origin == _origin:
		return
	_arcs_origin = _origin.duplicate()
	var im: ImmediateMesh = _arcs_mesh.mesh
	im.clear_surfaces()
	if arcs.is_empty():
		return
	var top_a: float = Settings.get_value("relations.opacity")
	var alpha: float = clamp(60.0 / arcs.size(), top_a * 0.25, top_a)
	var rise: float = Settings.get_value("relations.arc_height")
	(_arcs_mesh.material_override as StandardMaterial3D).no_depth_test = Settings.get_value("relations.through")
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for arc in arcs:
		var ra: Array = arc.a
		var rb: Array = arc.b
		var a := _world_to_render(ra[0] + ra[2] * 0.5, ra[4], ra[1] + ra[3] * 0.5)
		var b := _world_to_render(rb[0] + rb[2] * 0.5, rb[4], rb[1] + rb[3] * 0.5)
		var span := a.distance_to(b)
		var ctrl: Vector3 = (a + b) * 0.5 + Vector3.UP * (max(a.y, b.y) - (a.y + b.y) * 0.5 + span * rise)
		var c: Color = arc.color
		var prev := a
		for i in range(1, 25):
			var t := i / 24.0
			var p := a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t)
			# fade toward the target end so direction reads without arrowheads
			im.surface_set_color(Color(c, alpha * (1.0 - 0.6 * (t - 1.0 / 24.0))))
			im.surface_add_vertex(prev)
			im.surface_set_color(Color(c, alpha * (1.0 - 0.6 * t)))
			im.surface_add_vertex(p)
			prev = p
	im.surface_end()


func _highlight(shader_path: String, params: Dictionary) -> MeshInstance3D:
	var mat := ShaderMaterial.new()
	mat.shader = load(shader_path)
	for k in params:
		mat.set_shader_parameter(k, params[k])
	var mi := MeshInstance3D.new()
	mi.mesh = _cube
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	_root3d.add_child(mi)
	return mi


## Flat unit quad on the XZ plane, facing up, uv = (x, z).
func _make_plane() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var c := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	for i in [0, 1, 2, 0, 2, 3]:
		v.append(c[i])
		uv.append(Vector2(c[i].x, c[i].z))
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func attach(c: ScrapClient) -> void:
	client = c
	client.hello.connect(_on_hello)
	client.tile_received.connect(_on_tile)
	client.reply.connect(_on_reply)
	client.text_received.connect(func(_t): _dirty = true)
	client.font_ready.connect(func(): _dirty = true)
	var text_root := Node3D.new()
	_root3d.add_child(text_root)
	_text = TextLayer.new(client, text_root, load("res://shaders/text3d.gdshader"), func(mat):
		var mi := MeshInstance3D.new()
		mi.mesh = _plane
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return mi)


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
	## physical pixels per world unit at distance d (world units) from the
	## camera: tile and text detail follow the real resolution
	return size.y * _f / (2.0 * d * tan(deg_to_rad(_fov) * 0.5))


## Camera distance showing zoom UI pixels per world unit (as the 2D map).
func _dist_for_zoom(zoom: float) -> float:
	return size.y / (2.0 * zoom * tan(deg_to_rad(_fov) * 0.5))


## Enter from the 2D map: start straight above the same view, then tilt.
func enter(cx: float, cy: float, zoom: float) -> void:
	tx = cx
	ty = cy
	th = 0.0
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
	_fly_rect(r, 0.0)


func frame_selected() -> void:
	if not selection.is_empty():
		focus_rect(selection.rect, selection.top)


func _fly_dur(base: float) -> float:
	return base / float(Settings.get_value("camera.fly_speed"))


func _fly_rect(r: Array, top: float, margin := 1.25) -> void:
	var w: float = max(r[2], r[3] * size.x / max(size.y, 1.0)) * margin
	var d := _dist_for_zoom(size.x / w)
	_goal = {}
	_tween = {"from": {"tx": tx, "ty": ty, "th": th, "dist": dist, "pitch": pitch, "yaw": yaw},
		"to": {"tx": r[0] + r[2] * 0.5, "ty": r[1] + r[3] * 0.5, "th": top, "dist": d, "pitch": pitch, "yaw": yaw},
		"t": 0.0, "dur": _fly_dur(0.9), "arc": true}


func focus_rect(r: Array, top: float) -> void:
	_fly_rect(r, top, 1.6)


## Flies to a text line (on a roof at height top) so it reads at about
## line_px on a steep camera.
func focus_line(r: Array, top: float, line_px := 16.0) -> void:
	var d := _dist_for_zoom(line_px / max(r[3], 1e-12))
	_goal = {}
	_tween = {"from": {"tx": tx, "ty": ty, "th": th, "dist": dist, "pitch": pitch, "yaw": yaw},
		"to": {"tx": r[0] + r[2] * 0.5, "ty": r[1] + r[3] * 0.5, "th": top, "dist": d, "pitch": max(pitch, 1.15), "yaw": yaw},
		"t": 0.0, "dur": _fly_dur(1.1), "arc": true}


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
				exited.emit(tx, ty, size.y / (2.0 * dist * tan(deg_to_rad(_fov) * 0.5)))
		_dirty = true
	elif not _goal.is_empty():
		var k := 1.0 - exp(-dt * float(Settings.get_value("camera.smoothing")))
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
		_goal = {"tx": tx, "ty": ty, "th": th, "dist": dist, "yaw": yaw, "pitch": pitch}
	_goal[key] = value


func _goal_get(key: String) -> float:
	return _goal.get(key, get(key))


func _update_camera() -> void:
	# floating origin: float32 error grows with |coordinate|, detail shrinks
	# with distance, so recentre long before the error nears a pixel
	if max(abs(tx - _origin[0]), abs(ty - _origin[1])) > dist * 500.0:
		_origin = [tx, ty]
	# reading assist: while code under the target is readable, lean toward
	# a top-down view; the user's own pitch is untouched and comes back
	var p := pitch
	var assist: float = Settings.get_value("camera.reading_assist")
	if assist > 0.0 and _tween.is_empty():
		p = lerp(pitch, max(pitch, 1.4), _reading * assist)
	var cp := cos(p)
	var offset := Vector3(sin(yaw) * cp, sin(p), cos(yaw) * cp) * dist * S
	var target := Vector3((tx - _origin[0]) * S, th * S, (ty - _origin[1]) * S)
	var pos := target + offset
	# stay above whatever stands under the camera
	var min_y := (_floor_cam + dist * 0.08) * S
	if pos.y < min_y:
		pos.y = min_y
	_cam.position = pos
	var up := Vector3.UP
	if abs((target - pos).normalized().dot(Vector3.UP)) > 0.999:
		up = Vector3(-sin(yaw), 0, -cos(yaw))
	_cam.look_at(target, up)
	var r := dist * S
	_cam.near = max(r * 0.002, 1e-6)
	_cam.far = r * 60.0 + 10.0
	_env.fog_depth_begin = r * 2.0
	_env.fog_depth_end = r * 14.0
	# the ground grid follows the target, dots every 2^k world units
	if _ground.visible:
		_ground.position = Vector3(target.x, -r * 0.0005, target.z)
		_ground.scale = Vector3.ONE * r * 30.0
		var gm := _ground.material_override as ShaderMaterial
		gm.set_shader_parameter("spacing", pow(2.0, floor(log(dist * 0.04) / log(2.0))) * S)
		gm.set_shader_parameter("center", target)
		gm.set_shader_parameter("radius", r * 12.0)


func _process(dt: float) -> void:
	if not visible:
		return
	_frame += 1
	_step(dt)
	_follow_floor(dt)
	if abs(_reading - _reading_goal) > 0.002:
		_reading = lerp(_reading, _reading_goal, 1.0 - exp(-dt * 3.0))
		_dirty = true
	if _pick_pending and Time.get_ticks_msec() / 1000.0 >= _pick_at:
		_pick_pending = false
		_send_pick()
	if _text != null and _text.animating():
		_dirty = true  # text fades in/out
	if _dirty and gen >= 0:
		_dirty = false
		_update_camera()
		_update_tiles()
		_overlay.queue_redraw()


## Asks the server for the roof heights under the camera and the target
## (throttled), and lets the orbit target settle onto the roof below it.
func _follow_floor(dt: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if client != null and gen >= 0 and now - _heights_at > 0.08:
		_heights_at = now
		var cam_w := [_cam.global_position.x / S + _origin[0], _cam.global_position.z / S + _origin[1]]
		_heights_req = client.request("heights", {"pts": [cam_w, [tx, ty]]})
	if _tween.is_empty() and _drag.is_empty() and abs(th - _floor_target) > dist * 1e-4:
		th = lerp(th, _floor_target, 1.0 - exp(-dt * 8.0))
		_dirty = true


# ---------------------------------------------------------------- tiles

func text_layer() -> TextLayer:
	return _text


func tile_count() -> int:
	return _tiles.size()


func _on_hello(info: Dictionary) -> void:
	gen = int(info.gen)
	stat_gens += 1
	world = info.world
	max_z = int(info.maxZ)
	max_top = float(info.get("maxTop", 0.05))
	_text.set_gen(gen)
	_last_request = ""
	_dirty = true


func _world_to_render(x: float, h: float, y: float) -> Vector3:
	return Vector3((x - _origin[0]) * S, h * S, (y - _origin[1]) * S)


func _update_tiles() -> void:
	var planes := _cam.get_frustum()
	var cam_pos := _cam.global_position
	var chosen := []
	var queue := [[INF, Vector3i(0, 0, 0)]]  # [on-screen px, key]
	var wx0: float = world[0]
	var wy0: float = world[1]
	var wx1: float = world[0] + world[2]
	var wy1: float = world[1] + world[3]
	var max_tiles: int = Settings.get_value("perf.tiles_3d")
	while not queue.is_empty():
		var best := 0
		for i in queue.size():
			if queue[i][0] > queue[best][0]:
				best = i
		var k: Vector3i = queue[best][1]
		queue.remove_at(best)
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
		if px > TILE_PX * 1.15 and k.x < max_z and chosen.size() + queue.size() + 4 <= max_tiles:
			for j in 2:
				for i in 2:
					queue.append([px * 0.5, Vector3i(k.x + 1, k.y * 2 + i, k.z * 2 + j)])
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
			ViewCommon.tile_fallback(_tiles, key, shown)
	stat_shown = shown.size()
	stat_missing = keys.size()
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
			rec.node.scale = Vector3.ONE * ts * S
	_update_text(cam_pos)
	_update_highlights()
	_update_arcs()
	var max_cached: int = Settings.get_value("perf.tile_cache")
	if _tiles.size() > max_cached:
		var recs := _tiles.values()
		recs.sort_custom(func(p, q): return p.used < q.used)
		for i in _tiles.size() - int(max_cached * 0.8):
			var rec: Rec = recs[i]
			if not rec.node.visible:
				rec.node.queue_free()
				_tiles.erase(rec.key)
				stat_evicted += 1


## Text blocks listed by the visible tiles, biggest text on screen first.
func _update_text(cam_pos: Vector3) -> void:
	var min_px: float = Settings.get_value("text.min_line_px")
	var reading := 0.0
	var seen := {}   # key -> index in wanted
	var wanted := []
	for key: Vector3i in _tiles:
		var rec: Rec = _tiles[key]
		if not rec.node.visible:
			continue
		for b in rec.blocks:
			var k := TextLayer.key_of(b)
			if seen.has(k):
				if int(b.gen) == gen and int(wanted[seen[k]][1].gen) != gen:
					wanted[seen[k]][1] = b  # prefer the current placement
				continue
			var c := _world_to_render(b.x + b.w * 0.5, b.top, b.y + b.h * 0.5)
			var near := Vector3(clamp(cam_pos.x, c.x - b.w * S * 0.5, c.x + b.w * S * 0.5), c.y,
				clamp(cam_pos.z, c.z - b.h * S * 0.5, c.z + b.h * S * 0.5))
			var d: float = max(cam_pos.distance_to(near) / S, 1e-12)
			var line_px: float = b.h / b.rows * _ppu(d)
			if line_px >= min_px:
				seen[k] = wanted.size()
				wanted.append([line_px, b])
			# how readable is the code at the orbit target?
			if tx >= b.x and tx <= b.x + b.w and ty >= b.y and ty <= b.y + b.h:
				reading = max(reading, smoothstep(5.0, 14.0, line_px))
	_reading_goal = reading
	if not Settings.get_value("viewport.code_text"):
		wanted = []
	_text.update(wanted, int(Settings.get_value("text.budget")), func(node: Node3D, b: Dictionary):
		node.position = _world_to_render(b.x, b.top, b.y)
		node.scale = Vector3(b.w * S, 1.0, b.h * S))


func _place_box(mi: MeshInstance3D, r: Array, top: float, kind := "") -> void:
	if kind == "scope":
		# a function lives on its file's roof: highlight a thin slab there
		var h: float = max(min(r[2], r[3]) * 0.03, 1e-9)
		mi.position = _world_to_render(r[0], top, r[1])
		mi.scale = Vector3(r[2] * S, h * S, r[3] * S)
		return
	mi.position = _world_to_render(r[0], 0.0, r[1])
	mi.scale = Vector3(r[2] * S, max(top, 1e-9) * S, r[3] * S)


func _update_highlights() -> void:
	var has_sel := not selection.is_empty()
	_sel_xray.visible = has_sel and Settings.get_value("highlight.style") != "off"
	_sel_fill.visible = has_sel and float(Settings.get_value("highlight.fill")) > 0.0
	if has_sel:
		_place_box(_sel_xray, selection.rect, selection.top, selection.get("kind", ""))
		_place_box(_sel_fill, selection.rect, selection.top, selection.get("kind", ""))
	var hv: bool = hover.has("rect") and int(hover.get("node", -1)) >= 0 and Settings.get_value("viewport.hover") 		and Settings.get_value("highlight.hover_style") != "off"
	_hov_xray.visible = hv
	if hv:
		_place_box(_hov_xray, hover.rect, float(hover.get("top", 0.0)), hover.get("kind", ""))


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
		mat.set_shader_parameter("level", float(t.z))
		mmi.material_override = mat
		node.add_child(mmi)
	var ox: float = t.x * ts
	var oy: float = t.y * ts
	for bl in t.blocks:
		var br: Rect2 = bl.rect
		rec.blocks.append({"file": bl.file, "col": bl.col, "seg": bl.seg, "rows": bl.rows, "key": bl.key, "gen": gen,
			"x": ox + br.position.x * ts, "y": oy + br.position.y * ts, "w": br.size.x * ts, "h": br.size.y * ts, "top": bl.top * ts})
	for l in t.labels:
		var r: Rect2 = l.rect
		rec.label_ids.append(l.id)
		rec.label_kinds.append(l.kind)
		rec.label_data.append_array([ox + r.position.x * ts, oy + r.position.y * ts, r.size.x * ts, r.size.y * ts, l.top * ts])
		rec.label_texts.append(l.text)
		rec.label_colors.append(l.color)
	rec.node = node
	node.visible = false
	_tiles_root.add_child(node)
	_tiles[key] = rec
	_dirty = true


# ---------------------------------------------------------------- input

func _ground_point(p: Vector2, h := NAN) -> Array:
	## world (x, y) where the ray under a screen point meets the horizontal
	## plane at height h (default: the target's height), or [] if it doesn't
	if is_nan(h):
		h = th
	var o := _cam.project_ray_origin(_vp_pt(p))
	var n := _cam.project_ray_normal(_vp_pt(p))
	if n.y > -1e-6:
		return []
	var t := (h * S - o.y) / n.y
	var hit := o + n * t
	return [hit.x / S + _origin[0], hit.z / S + _origin[1]]


## Mouse input goes through the active keymap (Settings → Mouse & keys).
func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			if Keymap.wheel_action(mb) == "zoom":
				var step: float = Settings.get_value("camera.zoom_step")
				var f := 1.0 / step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else step
				if mb.factor > 0.0:
					f = pow(f, mb.factor)
				_zoom_toward(mb.position, f)
				accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if mb.pressed:
				grab_focus()
				_drag = Keymap.mouse_binding(mb)
				_drag.button = mb.button_index
				_dragging = false
				_press_pos = mb.position
				if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT and hover.has("rect"):
					focus_rect(hover.rect, float(hover.get("top", 0.0)))
			elif _drag.get("button", -1) == mb.button_index:
				if not _dragging and _drag.get("click", "") == "select":
					_click_select()
				_drag = {}
				_dragging = false
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		var prev := _last_mouse
		_last_mouse = mm.position
		if _drag.has("action"):
			if not _dragging and mm.position.distance_to(_press_pos) > 4.0:
				_dragging = true
			if _dragging:
				_tween = {}
				_goal = {}
				match _drag.action:
					"pan":
						var a := _ground_point(prev)
						var b := _ground_point(mm.position)
						if not a.is_empty() and not b.is_empty():
							tx -= b[0] - a[0]
							ty -= b[1] - a[1]
					"orbit":
						var s: float = Settings.get_value("camera.orbit_speed")
						yaw -= mm.relative.x * 0.006 * s
						pitch = clamp(pitch + mm.relative.y * 0.005 * s, MIN_PITCH, MAX_PITCH)
					"dolly":
						dist = clamp(dist * exp(mm.relative.y * 0.01), 1e-9, 20.0)
				_dirty = true
		_schedule_pick()


## Wheel zoom toward the roof/wall under the cursor if the last pick is
## fresh, else toward the plane at the target's height.
func _zoom_toward(pos: Vector2, f: float) -> void:
	_tween = {}
	var p := []
	if hover.has("hit") and _last_mouse.distance_to(pos) < 3.0:
		p = hover.hit
	else:
		var gp := _ground_point(pos)
		if not gp.is_empty():
			p = [gp[0], th, gp[1]]
	var d0 := _goal_get("dist")
	var d1: float = clamp(d0 * f, 1e-9, 20.0)
	_goal_set("dist", d1)
	if not p.is_empty():
		var k := d1 / d0
		_goal_set("tx", p[0] + (_goal_get("tx") - p[0]) * k)
		_goal_set("th", p[1] + (_goal_get("th") - p[1]) * k)
		_goal_set("ty", p[2] + (_goal_get("ty") - p[2]) * k)


## A click selects what is under the cursor; a click on empty space
## deselects.
func _click_select() -> void:
	if hover.has("rect") and int(hover.get("node", -1)) >= 0:
		select(int(hover.node), hover.rect, float(hover.get("top", 0.0)), hover.get("kind", ""))
	else:
		deselect()


func deselect() -> void:
	if selection.is_empty():
		return
	selection = {}
	current_hit = {}
	selected.emit(-1)
	_update_highlights()
	_overlay.queue_redraw()


func _schedule_pick() -> void:
	if not _pick_pending:
		_pick_pending = true
		_pick_at = Time.get_ticks_msec() / 1000.0 + 0.04


func _send_pick() -> void:
	if client == null or gen < 0:
		return
	var o := _cam.project_ray_origin(_vp_pt(_last_mouse))
	var n := _cam.project_ray_normal(_vp_pt(_last_mouse))
	var ray := [o.x / S + _origin[0], o.y / S, o.z / S + _origin[1], n.x, n.y, n.z]
	_hover_ray = ray
	client.request("pickRay", {"ray": ray})


func _on_reply(id: int, data: Dictionary) -> void:
	if not visible:
		return
	if data.get("op") == "heights" and id == _heights_req:
		var h: Array = data.h
		var was := _floor_cam
		_floor_cam = h[0]
		_floor_target = h[1]
		if _floor_cam > was:
			_dirty = true
		return
	if data.get("op") == "pick":
		if data.has("t") and _hover_ray.size() == 6:
			var r := _hover_ray
			var t: float = data.t
			data["hit"] = [r[0] + r[3] * t, r[1] + r[4] * t, r[2] + r[5] * t]
		hover = data
		hovered.emit(data)
		_update_highlights()
		_overlay.queue_redraw()


## Shows a selection made elsewhere (no signal).
func set_selection(rect: Array, top: float, kind := "") -> void:
	selection = {"rect": rect, "top": top, "kind": kind}
	_update_highlights()
	_overlay.queue_redraw()


func select(id: int, rect: Array, top: float, kind := "") -> void:
	selection = {"rect": rect, "top": top, "kind": kind}
	selected.emit(id)
	_update_highlights()
	_overlay.queue_redraw()


# ---------------------------------------------------------------- overlay

func _project_roof(r: Array, top: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for c in [[0, 0], [1, 0], [1, 1], [0, 1]]:
		var p := _world_to_render(r[0] + r[2] * c[0], top, r[1] + r[3] * c[1])
		if _cam.is_position_behind(p):
			return PackedVector2Array()
		pts.append(_unproject(p))
	return pts


func _draw_overlay() -> void:
	var o := _overlay
	var HIT_COLOR: Color = Settings.get_value("highlight.search")
	var show_hits: bool = Settings.get_value("viewport.search_hits")
	for f in (hit_files if show_hits else []):
		var pts := _project_roof(f, f[4] if f.size() > 4 else 0.0)
		if pts.size() == 4:
			var extent := sqrt(max(Rect2(pts[0], Vector2.ZERO).expand(pts[1]).expand(pts[2]).expand(pts[3]).get_area(), 0.0))
			var fade: float = 1.0 - smoothstep(60.0, 400.0, extent)
			if fade > 0.02:
				o.draw_colored_polygon(pts, Color(HIT_COLOR, 0.35 * fade))
			var loop := pts.duplicate()
			loop.append(pts[0])
			o.draw_polyline(loop, Color(HIT_COLOR, 0.5 + 0.3 * fade), 1.0)
	if not current_hit.is_empty():
		var pts := _project_roof(current_hit.rect, current_hit.top)
		if pts.size() == 4:
			o.draw_colored_polygon(pts, Color(HIT_COLOR, 0.5))
	if Settings.get_value("viewport.labels"):
		_draw_labels()
	else:
		_place_labels_3d([])


func _draw_labels() -> void:
	var o := _overlay
	var seen := {}
	var cand := []
	var view := Rect2(Vector2.ZERO, size)
	var min_box: float = Settings.get_value("labels.min_box_px")
	var fs: int = Settings.get_value("labels.font_size")
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
			var s0 := _unproject(p0)
			var s1 := _unproject(p1)
			var w := s0.distance_to(s1)
			if w < min_box or not view.has_point(s0):
				continue
			var kind := int(rec.label_kinds[i])
			cand.append({"id": id, "prio": w, "kind": kind, "color": rec.label_colors[i], "text": rec.label_texts[i],
				"max_w": w - 8.0, "pos": s0 + Vector2(2, -fs - 6), "size": fs if kind == 0 else max(fs - 1, 8),
				"at": p0})
	_place_labels_3d(ViewCommon.place_labels(cand, Settings.get_value("labels.max")))


## 3D labels are Label3D nodes: depth tested, so buildings in front hide
## them (unless "Labels through buildings" is on), and pixel-sized.
func _place_labels_3d(placed: Array) -> void:
	var through: bool = Settings.get_value("viewport.labels_through")
	# at 1 render unit from the camera, one physical pixel is this big
	var px: float = 2.0 * tan(deg_to_rad(_fov) * 0.5) / max(_vp.size.y, 1.0)
	var bg := Style.color("bg")
	var bold := Style.font("ui", 600)
	var regular := Style.font("ui", 500)
	# labels stay attached to their node across frames, so an unchanged
	# label is never rebuilt
	var next := {}
	for p in placed:
		var id: int = p.c.id
		if _label_of.has(id):
			next[id] = _label_of[id]
			_label_of.erase(id)
	for id in _label_of:
		var old: Label3D = _label_of[id]
		old.visible = false
		_label_free.append(old)
	for p in placed:
		var c: Dictionary = p.c
		var l: Label3D = next.get(c.id)
		if l == null:
			if _label_free.is_empty():
				l = Label3D.new()
				l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				l.fixed_size = true
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
				l.render_priority = 10
				l.outline_render_priority = 9
				l.double_sided = true
				_labels_root.add_child(l)
			else:
				l = _label_free.pop_back()
			next[c.id] = l
		var fs := int(round(float(c.size) * _f))
		l.visible = true
		l.position = c.at
		# Label3D rebuilds its mesh on most property changes: only touch what
		# changed (the pool is reused every frame)
		var look := [p.text, c.kind, fs, c.color, through, px, Style.theme_id]
		if l.get_meta("look", []) == look:
			continue
		l.set_meta("look", look)
		l.no_depth_test = through
		l.text = p.text
		l.font = bold if c.kind == 0 else regular
		l.font_size = fs
		l.pixel_size = px
		l.outline_size = max(int(fs * 0.45), 4)
		l.offset = Vector2(2.0, 4.0) * _f
		var col: Color = c.color
		if c.kind == 0:
			l.modulate = col.lerp(Color.WHITE, 0.55)
			l.outline_modulate = Color(bg.lerp(col, 0.3), 0.95)
		else:
			l.modulate = Style.color("text2")
			l.outline_modulate = Color(bg, 0.9)
	_label_of = next


func set_search_results(files: Array) -> void:
	hit_files = files
	_overlay.queue_redraw()


func clear_search() -> void:
	hit_files = []
	current_hit = {}
	_overlay.queue_redraw()
