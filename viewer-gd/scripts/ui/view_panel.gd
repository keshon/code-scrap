class_name ViewPanel
extends ScrollContainer
## Right pane "View" tab: how the map is shaped and colored (lenses, from
## the server's descriptors, with what each one means) and which relations
## are drawn. Display toggles (labels, text, highlights) live in the
## viewport's ☰ menu, tunables in Settings: each control has one home.

signal lens_changed(view: Dictionary)   # {height, color, importance}

var _height_opt: OptionButton
var _height_caption: Label
var _color_opt: OptionButton
var _height_info: Button
var _color_info: Button
var _importance: CheckButton
var _weights: FoldableContainer
var _heights := []    # lens descriptors
var _colors := []
var _git := false
var _syncing := false


func _ready() -> void:
	name = "View"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 10)
	add_child(vb)

	vb.add_child(_section("Lenses"))
	_height_caption = _caption("Height")
	_height_info = _info("")
	vb.add_child(_captioned(_height_caption, _height_info))
	_height_opt = _picker()
	_height_opt.item_selected.connect(func(_i): _emit())
	vb.add_child(_height_opt)
	_color_info = _info("")
	vb.add_child(_captioned(_caption("Color"), _color_info))
	_color_opt = _picker()
	_color_opt.item_selected.connect(func(_i): _emit())
	vb.add_child(_color_opt)

	_importance = CheckButton.new()
	_importance.text = "Importance weighting"
	_importance.focus_mode = Control.FOCUS_NONE
	_importance.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_importance.toggled.connect(func(_on): _emit())
	vb.add_child(_captioned(_importance, _info("Shrinks vendored, test, generated, asset and data files so the core code gets the space. The weights say how much area each kind keeps.")))
	_weights = FoldableContainer.new()
	_weights.title = Style.text("Weights")
	_weights.folded = true
	var wb := VBoxContainer.new()
	_weights.add_child(wb)
	for id in ["importance.vendored", "importance.test", "importance.minified", "importance.asset", "importance.data", "importance.rules"]:
		wb.add_child(SettingRow.new(id, true))
	vb.add_child(_weights)
	vb.add_child(SettingRow.new("git.since", true))
	vb.add_child(HSeparator.new())
	vb.add_child(_captioned(_section("Layout"), _info("How boxes are arranged inside each folder. Hover a setting's name for what it does.")))
	for id in ["layout.keep_chains", "look.merge_bands", "look.band_size", "layout.order", "layout.algorithm", "layout.cards_depth"]:
		vb.add_child(_captioned(SettingRow.new(id, true), _info(Settings.defs[id].desc)))

	vb.add_child(HSeparator.new())
	vb.add_child(_captioned(_section("Relations"), _info("Arcs from and to the selection. Colors and opacity: Settings → Relations.")))
	for id in ["relations.imports", "relations.calls", "relations.style"]:
		vb.add_child(_captioned(SettingRow.new(id, true), _info(Settings.defs[id].desc)))

	_set_lenses(_fallback_heights(), _fallback_colors())


## Mirrors the server's view and lens descriptors (no requests while syncing).
func sync(info: Dictionary) -> void:
	_syncing = true
	_git = info.get("git", false)
	var lenses: Dictionary = info.get("lenses", {})
	if lenses.has("height"):
		_set_lenses(lenses.height, lenses.color)
	var v: Dictionary = info.get("view", {})
	_select(_height_opt, _heights, v.get("height", ""))
	_select(_color_opt, _colors, v.get("color", ""))
	_importance.button_pressed = v.get("importance", false)
	_describe()
	_syncing = false


## Height only shapes the 3D city: grayed out on the flat map.
func set_3d(on: bool) -> void:
	_height_opt.disabled = not on
	_height_info.modulate.a = 1.0 if on else 0.5
	_height_caption.text = Style.text("Height") if on else Style.text("Height · 3D only")
	_height_opt.tooltip_text = "" if on else "Building height applies to the 3D city (Tab)"


func current_view() -> Dictionary:
	return {
		"height": _heights[max(_height_opt.selected, 0)].id,
		"color": _colors[max(_color_opt.selected, 0)].id,
		"importance": _importance.button_pressed,
	}


## The active height lens descriptor.
func height_lens() -> Dictionary:
	return _heights[max(_height_opt.selected, 0)]


## The active color lens descriptor.
func color_lens() -> Dictionary:
	return _colors[max(_color_opt.selected, 0)]


## "height:churn,color:complexity,importance" → controls, then one request.
func apply_lens_spec(spec: String) -> void:
	_syncing = true
	for part in spec.split(","):
		var kv := part.split(":")
		if kv[0] == "importance":
			_importance.button_pressed = true
		elif kv.size() == 2 and kv[0] == "height":
			_select(_height_opt, _heights, kv[1])
		elif kv.size() == 2 and kv[0] == "color":
			_select(_color_opt, _colors, kv[1])
	_syncing = false
	_emit()


func _emit() -> void:
	_describe()
	if not _syncing:
		lens_changed.emit(current_view())


func _describe() -> void:
	var h: Dictionary = _heights[max(_height_opt.selected, 0)]
	var c: Dictionary = _colors[max(_color_opt.selected, 0)]
	_height_info.tooltip_text = h.get("desc", "")
	_color_info.tooltip_text = c.get("desc", "")
	if c.get("high", "") != "":
		_color_info.tooltip_text += " Red = " + c.high + "."


func _set_lenses(heights: Array, colors: Array) -> void:
	_heights = heights
	_colors = colors
	for pair in [[_height_opt, _heights], [_color_opt, _colors]]:
		var o: OptionButton = pair[0]
		var sel := o.selected
		o.clear()
		for i in pair[1].size():
			var l: Dictionary = pair[1][i]
			o.add_item(l.short)
			o.set_item_tooltip(i, "%s\n%s" % [l.long, l.desc])
			o.set_item_disabled(i, l.get("needsGit", false) and not _git)
		if sel >= 0 and sel < o.item_count:
			o.select(sel)


func _select(o: OptionButton, lenses: Array, id: String) -> void:
	for i in lenses.size():
		if lenses[i].id == id or (id == "" and i == 0):
			o.select(i)
			return


func _picker() -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	return o


func _section(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SectionLabel"
	l.text = Style.text(t)
	return l


func _caption(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "DimLabel"
	l.text = Style.text(t)
	return l


## A row with its explanation folded into an "i" you can hover: the panel
## stays short enough to see at once instead of a wall of prose.
func _captioned(main: Control, info: Button) -> HBoxContainer:
	var hb := HBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(main)
	hb.add_child(info)
	return hb


func _info(text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	b.focus_mode = Control.FOCUS_NONE
	b.icon = Style.icon("info")
	b.tooltip_text = text
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.mouse_default_cursor_shape = Control.CURSOR_HELP
	return b


# Until the first hello (an older server) the panel still works.
static func _fallback_heights() -> Array:
	var out := []
	for l in [["depth", "Nesting"], ["flat", "Flat"], ["lines", "Lines"], ["complexity", "Complexity"], ["functions", "Functions"]]:
		out.append({"id": l[0], "short": l[1], "long": l[1], "desc": ""})
	return out


static func _fallback_colors() -> Array:
	var out := []
	for l in [["area", "Area"], ["lines", "Lines"], ["complexity", "Complexity"], ["functions", "Functions"]]:
		out.append({"id": l[0], "short": l[1], "long": l[1], "desc": ""})
	return out
