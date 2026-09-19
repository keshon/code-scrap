class_name Toolbar
extends PanelContainer
## Top zone: commands, view switch, lenses and relation toggles. It emits
## intents; the shell decides what they do.

signal action(name: String)             # keymap-style actions: frame_all, settings, …
signal open_folder
signal view_selected(three_d: bool)
signal lens_changed(view: Dictionary)   # {height, color, importance}
signal relations_changed

# lenses: [id, label, needs git]
const HEIGHTS := [["depth", "Nesting", false], ["flat", "Flat", false], ["lines", "Lines", false],
	["complexity", "Complexity", false], ["functions", "Functions", false], ["churn", "Churn", true],
	["age", "Recent change", true], ["authors", "Authors", true]]
const COLORS := [["area", "Area", false], ["lines", "Lines", false], ["complexity", "Complexity", false],
	["functions", "Functions", false], ["churn", "Churn", true], ["age", "Recent change", true],
	["authors", "Authors", true]]

var importance: CheckButton
var imports: CheckButton
var calls: CheckButton
var _v2d: Button
var _v3d: Button
var _height_opt: OptionButton
var _color_opt: OptionButton
var _syncing := false
var _icon_buttons: Array[Button] = []


func _ready() -> void:
	theme_type_variation = "Bar"
	# the toolbar clips instead of forcing its width on the window
	var clip := ScrollContainer.new()
	clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(clip)
	var hb := HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip.add_child(hb)

	var title := Label.new()
	title.theme_type_variation = "TitleLabel"
	title.text = "code-scrap"
	hb.add_child(title)
	hb.add_child(VSeparator.new())
	hb.add_child(_icon_button("home", "Frame all (A)", func(): action.emit("frame_all")))
	hb.add_child(_icon_button("frame", "Frame selected (F)", func(): action.emit("frame_selected")))
	hb.add_child(_icon_button("folder", "Open folder…", func(): open_folder.emit()))
	hb.add_child(VSeparator.new())

	var seg := PanelContainer.new()
	seg.theme_type_variation = "Inset"
	hb.add_child(seg)
	var segs := HBoxContainer.new()
	segs.add_theme_constant_override("separation", 2)
	seg.add_child(segs)
	var group := ButtonGroup.new()
	_v2d = _segment("2D", "Flat map (Tab toggles)", group, func(): view_selected.emit(false))
	_v2d.button_pressed = true
	segs.add_child(_v2d)
	_v3d = _segment("3D", "3D city (Tab toggles)", group, func(): view_selected.emit(true))
	segs.add_child(_v3d)
	hb.add_child(VSeparator.new())

	hb.add_child(_small_label("Height"))
	_height_opt = _lens_picker(HEIGHTS, "What building height encodes (3D). Git lenses need history, loaded in the background.")
	hb.add_child(_height_opt)
	hb.add_child(_small_label("Color"))
	_color_opt = _lens_picker(COLORS, "What box color encodes: the top-level area, or a metric as a cold (blue) → hot (red) percentile.")
	hb.add_child(_color_opt)
	importance = _toggle("Importance", "Shrink vendored, test, generated, asset and data files so the core code gets the space. Weights: Settings → Importance weights.")
	importance.toggled.connect(func(_on): _emit_lens())
	hb.add_child(importance)
	hb.add_child(VSeparator.new())
	imports = _toggle("Imports", "Show what the selection imports and what imports it.")
	imports.toggled.connect(func(_on): relations_changed.emit())
	hb.add_child(imports)
	calls = _toggle("Calls", "Show what the selected function or file calls and who calls it. Syntax-level: ambiguous names are skipped.")
	calls.toggled.connect(func(_on): relations_changed.emit())
	hb.add_child(calls)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	hb.add_child(_icon_button("settings", "Settings (Ctrl+,)", func(): action.emit("settings")))
	Style.theme_changed.connect(func():
		for b in _icon_buttons:
			b.icon = Style.icon(b.get_meta("icon")))


## Mirrors the 2D/3D switch without emitting.
func set_3d(on: bool) -> void:
	_v2d.set_pressed_no_signal(not on)
	_v3d.set_pressed_no_signal(on)


func current_view() -> Dictionary:
	return {
		"height": HEIGHTS[_height_opt.selected][0],
		"color": COLORS[_color_opt.selected][0],
		"importance": importance.button_pressed,
	}


## Label of the active color lens ("" for the plain area colors).
func color_lens_label() -> String:
	var c: String = COLORS[_color_opt.selected][0]
	return "" if c == "area" else COLORS[_color_opt.selected][1]


## Mirrors the server's view in the controls (no requests while syncing).
func sync_view(info: Dictionary) -> void:
	_syncing = true
	var v: Dictionary = info.get("view", {})
	var git: bool = info.get("git", false)
	for i in HEIGHTS.size():
		_height_opt.set_item_disabled(i, HEIGHTS[i][2] and not git)
		if HEIGHTS[i][0] == v.get("height", "") or (v.get("height", "") == "" and i == 0):
			_height_opt.select(i)
	for i in COLORS.size():
		_color_opt.set_item_disabled(i, COLORS[i][2] and not git)
		if COLORS[i][0] == v.get("color", "") or (v.get("color", "") == "" and i == 0):
			_color_opt.select(i)
	importance.button_pressed = v.get("importance", false)
	_syncing = false


## "height:churn,color:complexity,importance" → controls, then one request.
func apply_lens_spec(spec: String) -> void:
	_syncing = true
	for part in spec.split(","):
		var kv := part.split(":")
		if kv[0] == "importance":
			importance.button_pressed = true
		for i in HEIGHTS.size():
			if kv[0] == "height" and HEIGHTS[i][0] == kv[1]:
				_height_opt.select(i)
		for i in COLORS.size():
			if kv[0] == "color" and COLORS[i][0] == kv[1]:
				_color_opt.select(i)
	_syncing = false
	_emit_lens()


func _emit_lens() -> void:
	if not _syncing:
		lens_changed.emit(current_view())


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


func _toggle(text: String, tip: String) -> CheckButton:
	var b := CheckButton.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	return b


func _small_label(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SmallLabel"
	l.text = Style.text(t)
	return l


func _lens_picker(items: Array, tip: String) -> OptionButton:
	var o := OptionButton.new()
	o.tooltip_text = tip
	o.focus_mode = Control.FOCUS_NONE
	for i in items.size():
		o.add_item(items[i][1], i)
	o.item_selected.connect(func(_i): _emit_lens())
	return o
