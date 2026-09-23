class_name Toolbar
extends PanelContainer
## Top bar: app-level things only. Explorer toggle, repository (open,
## recent), 2D/3D, preset, the one search/command field, settings.

signal action(name: String)             # keymap-style actions: frame_all, settings, …
signal open_folder
signal open_path(path: String)
signal view_mode(mode: String)          # "2d" · "3d" · "arch"

const SEARCH_W := 480.0

var search_field: LineEdit
var _repo_btn: MenuButton
var _v2d: Button
var _v3d: Button
var _varch: Button
var _preset_opt: OptionButton
var _preset_ids := []
var _icon_buttons: Array[Button] = []
var _recent := []


func _ready() -> void:
	theme_type_variation = "Bar"
	# two layers: the left and right groups, and the search field centred
	# over the whole bar (like an editor's command centre)
	var hb := HBoxContainer.new()
	add_child(hb)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	# left: app, repository, explorer, 2D / 3D
	var title := Label.new()
	title.theme_type_variation = "TitleLabel"
	title.text = "code-scrap"
	hb.add_child(title)
	hb.add_child(VSeparator.new())

	_repo_btn = MenuButton.new()
	_repo_btn.flat = false
	_repo_btn.icon = Style.icon("folder")
	_repo_btn.text = "Repository"
	_repo_btn.tooltip_text = "Open a folder or a recent repository"
	_repo_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_repo_btn.custom_minimum_size = Vector2(120, 0)
	_repo_btn.about_to_popup.connect(_fill_repo_menu)
	_repo_btn.get_popup().id_pressed.connect(func(i):
		if i == 0:
			open_folder.emit()
		elif i >= 100 and i - 100 < _recent.size():
			open_path.emit(_recent[i - 100]))
	hb.add_child(_repo_btn)

	var tree_btn := _icon_button("sidebar", "Explorer: the file tree", func(): pass)
	tree_btn.toggle_mode = true
	tree_btn.button_pressed = Settings.get_value("ui.explorer")
	tree_btn.toggled.connect(func(on): Settings.set_value("ui.explorer", on))
	Settings.changed.connect(func(id, v):
		if id == "ui.explorer":
			tree_btn.set_pressed_no_signal(v))
	hb.add_child(tree_btn)

	var seg := PanelContainer.new()
	seg.theme_type_variation = "Inset"
	hb.add_child(seg)
	var segs := HBoxContainer.new()
	segs.add_theme_constant_override("separation", 2)
	seg.add_child(segs)
	var group := ButtonGroup.new()
	_v2d = _segment("2D", "Flat map (Tab toggles)", group, func(): view_mode.emit("2d"))
	_v2d.button_pressed = true
	segs.add_child(_v2d)
	_v3d = _segment("3D", "3D city (Tab toggles)", group, func(): view_mode.emit("3d"))
	segs.add_child(_v3d)
	_varch = _segment("Arch", "Architecture: clusters, groups and the flow between them", group, func(): view_mode.emit("arch"))
	segs.add_child(_varch)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(spacer)

	# right: preset, settings
	_preset_opt = OptionButton.new()
	_preset_opt.tooltip_text = "Settings preset"
	_preset_opt.focus_mode = Control.FOCUS_NONE
	_preset_opt.custom_minimum_size = Vector2(120, 0)
	_preset_opt.item_selected.connect(func(i): Settings.load_preset(_preset_ids[i]))
	hb.add_child(_preset_opt)
	_fill_presets()
	Settings.reloaded.connect(_fill_presets)
	Settings.presets_changed.connect(_fill_presets)
	hb.add_child(_icon_button("settings", "Settings (Ctrl+,)", func(): action.emit("settings")))

	# centre: search
	search_field = LineEdit.new()
	search_field.placeholder_text = "Go to file, folder or symbol   ·   > command"
	search_field.tooltip_text = "Files and folders by path, symbols by name prefix. Start with > for commands. ( / or Ctrl+K )"
	search_field.clear_button_enabled = true
	search_field.right_icon = Style.icon("search")
	search_field.custom_minimum_size = Vector2(SEARCH_W, 0)
	center.add_child(search_field)
	resized.connect(_fit_search)

	Style.theme_changed.connect(func():
		for b in _icon_buttons:
			b.icon = Style.icon(b.get_meta("icon"))
		_repo_btn.icon = Style.icon("folder")
		search_field.right_icon = Style.icon("search"))


## The search field keeps its width but never covers the groups beside it.
func _fit_search() -> void:
	var left := 0.0
	var right := 0.0
	var hb: HBoxContainer = get_child(0)
	var past_spacer := false
	for c in hb.get_children():
		if c is Control and c.size_flags_horizontal == Control.SIZE_EXPAND_FILL:
			past_spacer = true
			continue
		if past_spacer:
			right += c.size.x + 8.0
		else:
			left += c.size.x + 8.0
	var room: float = size.x - 2.0 * max(left, right) - 32.0
	search_field.custom_minimum_size.x = clamp(room, 160.0, SEARCH_W)


## Shows the open repository's name.
func set_repo(name: String, root: String) -> void:
	_repo_btn.text = name
	_repo_btn.tooltip_text = root + "\nClick to open another folder or a recent repository"


## Mirrors the view switch without emitting.
func set_mode(mode: String) -> void:
	_v2d.set_pressed_no_signal(mode == "2d")
	_v3d.set_pressed_no_signal(mode == "3d")
	_varch.set_pressed_no_signal(mode == "arch")


func _fill_repo_menu() -> void:
	var pm := _repo_btn.get_popup()
	pm.clear()
	pm.add_item("Open folder…", 0)
	_recent = Settings.recent()
	if not _recent.is_empty():
		pm.add_separator("Recent")
		for i in _recent.size():
			pm.add_item(Fmt.short_path(_recent[i], 60), 100 + i)
			pm.set_item_tooltip(pm.item_count - 1, _recent[i])


func _fill_presets() -> void:
	_preset_opt.clear()
	_preset_ids = []
	for p in Settings.presets():
		_preset_opt.add_item(p.name + ("  (mine)" if p.user else ""))
		_preset_opt.set_item_tooltip(_preset_ids.size(), p.desc)
		if p.id == Settings.preset:
			_preset_opt.select(_preset_ids.size())
		_preset_ids.append(p.id)


func _icon_button(icon: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	b.icon = Style.icon(icon)
	b.set_meta("icon", icon)
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	_icon_buttons.append(b)
	return b


func _segment(text: String, tip: String, group: ButtonGroup, cb: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "SegmentButton"
	b.text = Style.text(text)
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b
