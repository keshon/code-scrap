class_name Minimap
extends PanelContainer
## Viewport corner: the whole repository, coarse, with the part in view
## marked (a rectangle on the flat map, the ground footprint of the camera
## in 3D). Click or drag to move there. Toggle: ☰ → Minimap.

signal jump(x: float, y: float)   # world point to centre the view on

const SIZE := Vector2(230, 150)

var client: ScrapClient
var map: MapView
var city: CityView
var _canvas: Control          # the map: redrawn only when new data arrives
var _view: Control            # the view outline: redrawn when the view moves
var _boxes := PackedFloat32Array()   # x, y, w, h, r, g, b, kind per box
var _world := [0.0, 0.0, 1.0, 0.625]
var _req := -1
var _gen := -1
var _sig := ""
var _drag := false


func _init(c: ScrapClient, m: MapView, ci: CityView) -> void:
	client = c
	map = m
	city = ci


func _ready() -> void:
	theme_type_variation = "Floating"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas = Control.new()
	_canvas.custom_minimum_size = SIZE
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.clip_contents = true   # the 3D footprint can reach far outside
	_canvas.draw.connect(_draw_map)
	add_child(_canvas)
	_view = Control.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.draw.connect(_draw_view)
	_canvas.add_child(_view)
	tooltip_text = "Click or drag to move the view"
	client.hello.connect(func(info):
		if int(info.gen) != _gen:
			_gen = int(info.gen)
			_req = client.request("overview", {}))
	client.reply.connect(func(id, data):
		if id == _req and data.get("op") == "overview":
			_boxes = PackedFloat32Array(data.boxes)
			_world = data.world
			_canvas.queue_redraw())
	visible = Settings.get_value("viewport.minimap")
	Settings.changed.connect(func(id, v):
		if id == "viewport.minimap":
			visible = v)
	Style.theme_changed.connect(_canvas.queue_redraw)


func _process(_dt: float) -> void:
	if not visible:
		return
	# redraw the outline only when the view moved by a visible amount
	var shape := _view_shape()
	var sig := ""
	for p in shape:
		var q := _to_canvas(p.x, p.y).round()
		sig += "%d,%d;" % [q.x, q.y]
	if sig != _sig:
		_sig = sig
		_view.queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_drag = ev.pressed
		if ev.pressed:
			_jump_to(ev.position)
		accept_event()
	elif ev is InputEventMouseMotion and _drag:
		_jump_to(ev.position)
		accept_event()


func _jump_to(p: Vector2) -> void:
	var w := _to_world(p - _canvas.position)
	jump.emit(w.x, w.y)


# ---------------------------------------------------------------- mapping

func _fit() -> Array:
	## [scale, offset] fitting the world into the canvas, aspect kept
	var s: float = min(SIZE.x / _world[2], SIZE.y / _world[3])
	var off := (SIZE - Vector2(_world[2], _world[3]) * s) * 0.5 - Vector2(_world[0], _world[1]) * s
	return [s, off]


func _to_canvas(x: float, y: float) -> Vector2:
	var f := _fit()
	return Vector2(x, y) * f[0] + f[1]


func _to_world(p: Vector2) -> Vector2:
	var f := _fit()
	return (p - f[1]) / f[0]


## The part of the world in view: 4 world points (a polygon), or 1 (the
## 3D target when the camera looks at the sky).
func _view_shape() -> Array:
	if city.visible:
		var pts := []
		for c in [Vector2.ZERO, Vector2(city.size.x, 0), city.size, Vector2(0, city.size.y)]:
			var g: Array = city._ground_point(c, 0.0)
			if g.is_empty():
				return [Vector2(city.tx, city.ty)]
			pts.append(Vector2(g[0], g[1]))
		return pts
	var a: Array = map.screen_to_world(Vector2.ZERO)
	var b: Array = map.screen_to_world(map.size)
	return [Vector2(a[0], a[1]), Vector2(b[0], a[1]), Vector2(b[0], b[1]), Vector2(a[0], b[1])]


func _draw_map() -> void:
	var o := _canvas
	o.draw_rect(Rect2(Vector2.ZERO, SIZE), Color(Style.color("bg"), 0.9))
	var f := _fit()
	var s: float = f[0]
	var off: Vector2 = f[1]
	var n := _boxes.size() / 8
	for i in n:
		var j := i * 8
		var r := Rect2(Vector2(_boxes[j], _boxes[j + 1]) * s + off, Vector2(_boxes[j + 2], _boxes[j + 3]) * s)
		if r.size.x < 0.6 or r.size.y < 0.6:
			continue
		var c := Color(_boxes[j + 4], _boxes[j + 5], _boxes[j + 6])
		if _boxes[j + 7] < 0.5:
			o.draw_rect(r, Color(c, 0.55), false, 1.0)
		else:
			o.draw_rect(r, Color(c * 0.45, 1.0))


func _draw_view() -> void:
	var o := _view
	var shape := _view_shape()
	var accent := Style.color("accent")
	if shape.size() == 1:
		o.draw_circle(_to_canvas(shape[0].x, shape[0].y), 3.0, accent)
		return
	var poly := PackedVector2Array()
	for p in shape:
		var q := _to_canvas(p.x, p.y)
		poly.append(Vector2(clamp(q.x, -SIZE.x, SIZE.x * 2.0), clamp(q.y, -SIZE.y, SIZE.y * 2.0)))
	if not Geometry2D.triangulate_polygon(poly).is_empty():
		o.draw_colored_polygon(poly, Color(accent, 0.12))
	poly.append(poly[0])
	o.draw_polyline(poly, accent, 1.5)
