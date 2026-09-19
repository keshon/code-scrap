class_name ViewportHeader
extends HBoxContainer
## Across the top of the viewport, three separate islands:
##   breadcrumb  like a file manager's address bar: each segment selects that
##               folder, the › after it lists what is inside to jump to
##   camera      camera commands
##   display     what the viewport draws: every setting whose schema
##               surface is "display" (labels, text, highlights, …)

signal crumb_clicked(node: int)
signal action(name: String)

const CAMERA := [["Frame all", "frame_all", "A"], ["Frame selected", "frame_selected", "F"],
	["Deselect", "deselect", "Q"], ["Select parent", "select_parent", "Backspace"], ["", "", ""],
	["Switch 2D / 3D", "toggle_view", "Tab"]]
const MAX_CRUMBS := 3
const MENU_MAX := 80

var client: ScrapClient
var _crumbs: HBoxContainer
var _clip: ScrollContainer
var _repo := ""
var _camera: MenuButton
var _display: MenuButton
var _menu: PopupMenu
var _menu_req := -1
var _menu_at: Control
var _menu_ids := []
var _display_ids := []   # settings listed in the display menu, in schema order


func _init(c: ScrapClient) -> void:
	client = c


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var crumb_island := _island()
	crumb_island.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(crumb_island)
	# the breadcrumb clips at its start, keeping the current node in view
	_clip = ScrollContainer.new()
	_clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	crumb_island.add_child(_clip)
	_crumbs = HBoxContainer.new()
	_crumbs.add_theme_constant_override("separation", 0)
	_clip.add_child(_crumbs)
	_crumbs.resized.connect(func():
		_clip.scroll_horizontal = int(max(_crumbs.size.x - _clip.size.x, 0.0)))

	var cam_island := _island()
	add_child(cam_island)
	_camera = MenuButton.new()
	_camera.icon = Style.icon("camera")
	_camera.flat = true
	_camera.focus_mode = Control.FOCUS_NONE
	_camera.tooltip_text = "Camera commands"
	var cp := _camera.get_popup()
	for i in CAMERA.size():
		if CAMERA[i][0] == "":
			cp.add_separator()
		else:
			cp.add_item("%s\t%s" % [CAMERA[i][0], CAMERA[i][2]], i)
	cp.add_separator("Bookmarks")
	cp.add_item("Save: Ctrl+1 … 9   ·   Go: 1 … 9", 99)
	cp.set_item_disabled(cp.item_count - 1, true)
	cp.id_pressed.connect(func(i):
		if i < CAMERA.size():
			action.emit(CAMERA[i][1]))
	cam_island.add_child(_camera)

	var disp_island := _island()
	add_child(disp_island)
	_display = MenuButton.new()
	_display.icon = Style.icon("eye")
	_display.flat = true
	_display.focus_mode = Control.FOCUS_NONE
	_display.tooltip_text = "What the viewport shows"
	var dp := _display.get_popup()
	dp.hide_on_checkable_item_selection = false
	for g in Settings.groups:
		for d in g.settings:
			if d.get("surface", "") == "display" and d.type == "bool":
				dp.add_check_item(d.label, _display_ids.size())
				dp.set_item_tooltip(dp.item_count - 1, d.get("desc", ""))
				_display_ids.append(d.id)
	dp.id_pressed.connect(func(i):
		var id: String = _display_ids[i]
		var on: bool = not Settings.get_value(id)
		Settings.set_value(id, on)
		dp.set_item_checked(dp.get_item_index(i), on))   # the menu stays open: show it now
	_display.about_to_popup.connect(_sync_display)
	disp_island.add_child(_display)

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(func(i):
		if i < _menu_ids.size():
			crumb_clicked.emit(_menu_ids[i]))
	add_child(_menu)
	client.reply.connect(_on_reply)
	Style.theme_changed.connect(func():
		_display.icon = Style.icon("eye")
		_camera.icon = Style.icon("camera"))
	set_path("", -1, [])


func set_repo(name: String) -> void:
	_repo = name
	if _crumbs.get_child_count() <= 2:
		set_path("", -1, [])


## Shows root › … › parent › name. ancestors: [[id, name], …] from the root.
func set_path(name: String, id: int, ancestors: Array) -> void:
	for c in _crumbs.get_children():
		c.queue_free()
	var chain := ancestors.duplicate()
	if id >= 0:
		chain.append([id, name])
	if chain.is_empty():
		chain = [[0, _repo if _repo != "" else "code-scrap"]]
	# long paths keep the root and the last levels: root › … › a › b › here
	var shown := chain
	if chain.size() > MAX_CRUMBS + 1:
		shown = [chain[0], null] + chain.slice(chain.size() - MAX_CRUMBS)
	for i in shown.size():
		var a = shown[i]
		if a == null:
			var dots := Label.new()
			dots.theme_type_variation = "DimLabel"
			dots.text = " … "
			dots.tooltip_text = " › ".join(chain.map(func(x): return str(x[1])))
			dots.mouse_filter = Control.MOUSE_FILTER_PASS
			_crumbs.add_child(dots)
			continue
		var nid := int(a[0])
		var last := i == shown.size() - 1
		var b := Button.new()
		b.theme_type_variation = "FlatButton"
		b.text = str(a[1])
		b.tooltip_text = "Select and frame " + str(a[1])
		b.focus_mode = Control.FOCUS_NONE
		if last and id >= 0:
			b.add_theme_font_override("font", Style.font("ui", 600))
		b.pressed.connect(func(): crumb_clicked.emit(nid))
		_crumbs.add_child(b)
		var chev := Button.new()
		chev.theme_type_variation = "FlatButton"
		chev.icon = Style.icon("chevron")
		chev.tooltip_text = "What is inside " + str(a[1])
		chev.focus_mode = Control.FOCUS_NONE
		chev.pressed.connect(func(): _open_menu(nid, chev))
		_crumbs.add_child(chev)


func _open_menu(id: int, at: Control) -> void:
	_menu_at = at
	_menu_req = client.request("children", {"node": id})


func _on_reply(rid: int, data: Dictionary) -> void:
	if rid != _menu_req or data.get("op") != "children":
		return
	_menu.clear()
	_menu_ids = []
	var items: Array = data.items
	for x in items.slice(0, MENU_MAX):
		var icon := "folder" if x.kind == "dir" else ("file" if x.kind == "file" else "symbol")
		_menu.add_icon_item(Style.icon(icon, Color(x.color[0], x.color[1], x.color[2])), str(x.name), _menu_ids.size())
		_menu_ids.append(int(x.node))
	if items.size() > MENU_MAX:
		_menu.add_separator("%d more — use the Explorer" % (items.size() - MENU_MAX))
	if items.is_empty():
		_menu.add_item("(empty)")
		_menu.set_item_disabled(0, true)
	# like MenuButton: open below the chevron
	var scale := _menu_at.get_global_transform_with_canvas().get_scale()
	var pos := _menu_at.get_screen_position() + Vector2(0, _menu_at.size.y * scale.y)
	_menu.reset_size()
	_menu.position = Vector2i(pos.round())
	_menu.popup()


func _sync_display() -> void:
	var dp := _display.get_popup()
	for i in _display_ids.size():
		dp.set_item_checked(dp.get_item_index(i), Settings.get_value(_display_ids[i]))


func _island() -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = "Floating"
	return p
