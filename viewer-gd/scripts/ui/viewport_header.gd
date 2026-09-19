class_name ViewportHeader
extends PanelContainer
## Strip across the top of the viewport: where the selection is (a
## clickable breadcrumb), camera commands, and the display menu (☰) with
## the viewport's toggles.

signal crumb_clicked(node: int)
signal action(name: String)

const DISPLAY := ["viewport.labels", "viewport.code_text", "viewport.hover", "viewport.search_hits",
	"viewport.arcs", "viewport.legend", "debug.hud"]
const CAMERA := [["Frame all", "frame_all", "A"], ["Frame selected", "frame_selected", "F"],
	["Deselect", "deselect", "Q"], ["Select parent", "select_parent", "Backspace"], ["", "", ""],
	["Switch 2D / 3D", "toggle_view", "Tab"]]

const MAX_CRUMBS := 4

var _crumbs: HBoxContainer
var _clip: ScrollContainer
var _repo := ""
var _camera: MenuButton
var _display: MenuButton


func _ready() -> void:
	theme_type_variation = "Floating"
	var hb := HBoxContainer.new()
	add_child(hb)
	# the breadcrumb clips instead of pushing the menus out
	_clip = ScrollContainer.new()
	_clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_clip)
	_crumbs = HBoxContainer.new()
	_crumbs.add_theme_constant_override("separation", 0)
	_clip.add_child(_crumbs)
	# when it overflows, keep the end (the current node) in view
	_crumbs.resized.connect(func():
		_clip.scroll_horizontal = int(max(_crumbs.size.x - _clip.size.x, 0.0)))

	_camera = MenuButton.new()
	_camera.text = "Camera"
	_camera.flat = true
	_camera.focus_mode = Control.FOCUS_NONE
	_camera.tooltip_text = "Camera commands"
	var cp := _camera.get_popup()
	for i in CAMERA.size():
		if CAMERA[i][0] == "":
			cp.add_separator()
		else:
			cp.add_item("%s\t%s" % [CAMERA[i][0], CAMERA[i][2]], i)
	cp.id_pressed.connect(func(i): action.emit(CAMERA[i][1]))
	hb.add_child(_camera)

	_display = MenuButton.new()
	_display.icon = Style.icon("menu")
	_display.flat = true
	_display.focus_mode = Control.FOCUS_NONE
	_display.tooltip_text = "Viewport display"
	var dp := _display.get_popup()
	dp.hide_on_checkable_item_selection = false
	for i in DISPLAY.size():
		dp.add_check_item(Settings.defs[DISPLAY[i]].label, i)
		dp.set_item_tooltip(i, Settings.defs[DISPLAY[i]].get("desc", ""))
	dp.id_pressed.connect(func(i): Settings.set_value(DISPLAY[i], not Settings.get_value(DISPLAY[i])))
	_display.about_to_popup.connect(_sync_display)
	hb.add_child(_display)
	Style.theme_changed.connect(func(): _display.icon = Style.icon("menu"))
	set_path("", [])


func set_repo(name: String) -> void:
	_repo = name
	if _crumbs.get_child_count() <= 1:
		set_path("", [])


## Shows root › … › parent › name. ancestors: [[id, name], …] from the root.
func set_path(name: String, ancestors: Array) -> void:
	for c in _crumbs.get_children():
		c.queue_free()
	if ancestors.is_empty() and name == "":
		var l := Label.new()
		l.theme_type_variation = "DimLabel"
		l.text = _repo if _repo != "" else "code-scrap"
		_crumbs.add_child(l)
		return
	# long paths keep the root and the last levels: root › … › a › b › here
	var shown := ancestors
	if ancestors.size() > MAX_CRUMBS:
		shown = [ancestors[0], null] + ancestors.slice(ancestors.size() - (MAX_CRUMBS - 1))
	for a in shown:
		if a == null:
			var dots := Label.new()
			dots.theme_type_variation = "DimLabel"
			dots.text = " …  › "
			dots.tooltip_text = " › ".join(ancestors.map(func(x): return str(x[1])))
			dots.mouse_filter = Control.MOUSE_FILTER_PASS
			_crumbs.add_child(dots)
			continue
		var b := Button.new()
		b.theme_type_variation = "FlatButton"
		b.text = str(a[1])
		b.tooltip_text = "Select and frame " + str(a[1])
		b.focus_mode = Control.FOCUS_NONE
		var id := int(a[0])
		b.pressed.connect(func(): crumb_clicked.emit(id))
		_crumbs.add_child(b)
		var sep := Label.new()
		sep.theme_type_variation = "DimLabel"
		sep.text = " › "
		_crumbs.add_child(sep)
	var here := Label.new()
	here.text = name
	here.add_theme_font_override("font", Style.font("ui", 600))
	_crumbs.add_child(here)


func _sync_display() -> void:
	var dp := _display.get_popup()
	for i in DISPLAY.size():
		dp.set_item_checked(i, Settings.get_value(DISPLAY[i]))
