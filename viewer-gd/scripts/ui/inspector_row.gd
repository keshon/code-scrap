class_name InspectorRow
extends PanelContainer
## One route in the Inspector: a name, where it lives, and what it is joined
## to the selection by. The whole row is the button - clicking it goes there,
## and the icon on the right opens the file in an editor.

signal chosen
signal open_requested

const HEIGHT := 22.0

var _hovering := false
var _marked := false
var _accent := Color(0, 0, 0, 0)
var _open: Button


## lead: a line number or a size, right-aligned in a narrow gutter ("" for
## none). accent: the colour of the relation, transparent for an outline row.
func setup(lead: String, name: String, addr: String, accent: Color, openable: bool) -> void:
	_accent = accent
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	if lead != "":
		var g := Label.new()
		g.text = lead
		g.custom_minimum_size = Vector2(28, 0)
		g.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		g.add_theme_color_override("font_color", Style.color("text3"))
		g.add_theme_font_size_override("font_size", Style.num("font", "size_small", 12))
		box.add_child(g)
	var n := Label.new()
	n.text = name
	n.add_theme_color_override("font_color", Style.color("text"))
	n.add_theme_font_size_override("font_size", Style.num("font", "size_small", 12) + 1)
	box.add_child(n)
	if addr != "":
		var a := Label.new()
		a.text = addr
		a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		a.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		a.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		a.add_theme_color_override("font_color", Style.color("text3"))
		a.add_theme_font_size_override("font_size", Style.num("font", "size_small", 12))
		box.add_child(a)
	else:
		var pad := Control.new()
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(pad)
	if openable:
		_open = Button.new()
		_open.theme_type_variation = "SlimButton"
		_open.icon = Style.icon("external", Color(0, 0, 0, 0), 13)
		_open.flat = true
		_open.focus_mode = Control.FOCUS_NONE
		_open.tooltip_text = "Open in an editor"
		_open.modulate.a = 0.0   # kept in the layout so rows never shift
		_open.pressed.connect(func(): open_requested.emit())
		box.add_child(_open)
	mouse_entered.connect(func(): _set_hover(true))
	mouse_exited.connect(func(): _set_hover(false))
	_paint()


## Marks the row the relation cursor is on ([ and ] stepping).
func mark(on: bool) -> void:
	_marked = on
	_paint()


func _set_hover(on: bool) -> void:
	_hovering = on
	if _open != null:
		_open.modulate.a = 1.0 if on else 0.0
	_paint()


func _paint() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Style.color("surface2" if _hovering or _marked else "surface1")
	var r: float = Style.num("shape", "radius_control", 6) * 0.55
	sb.corner_radius_top_right = r
	sb.corner_radius_bottom_right = r
	sb.content_margin_left = 7.0
	sb.content_margin_right = 5.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	if _accent.a > 0.0:
		# the colour of the arc this row belongs to, as a spine on the left
		sb.border_width_left = 2
		sb.border_color = _accent
	add_theme_stylebox_override("panel", sb)


func _gui_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		chosen.emit()
		accept_event()
