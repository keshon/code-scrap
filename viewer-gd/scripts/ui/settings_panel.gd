class_name SettingsPanel
extends PanelContainer
## Settings, generated from config/settings.schema.json: one foldable group
## per schema group, one row per setting with a control picked by its type.
## Changes apply live and persist; presets load or save whole sets.

var _groups := []            # [{box: FoldableContainer, rows: Array[SettingRow]}]
var _filter: LineEdit
var _preset_opt: OptionButton
var _preset_ids := []
var _save_row: HBoxContainer
var _save_name: LineEdit
var _save_btn: Button
var _shown_modified := false
var _body: VBoxContainer


func _ready() -> void:
	# opaque: the map's code text must not show through the form
	custom_minimum_size = Vector2(400, 0)
	var vb := VBoxContainer.new()
	add_child(vb)

	var head := HBoxContainer.new()
	vb.add_child(head)
	var title := Label.new()
	title.theme_type_variation = "TitleLabel"
	title.text = Style.text("Settings")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.theme_type_variation = "FlatButton"
	close.icon = Style.icon("close")
	close.tooltip_text = "Close (Esc)"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(hide)
	head.add_child(close)

	# presets
	var pr := HBoxContainer.new()
	vb.add_child(pr)
	var pl := Label.new()
	pl.theme_type_variation = "DimLabel"
	pl.text = Style.text("Preset")
	pr.add_child(pl)
	_preset_opt = OptionButton.new()
	_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_opt.focus_mode = Control.FOCUS_NONE
	_preset_opt.item_selected.connect(func(i): Settings.load_preset(_preset_ids[i]))
	pr.add_child(_preset_opt)
	# Save overwrites your own preset in one click; shipped presets can only
	# be saved under a new name
	_save_btn = Button.new()
	_save_btn.icon = Style.icon("save")
	_save_btn.tooltip_text = "Save the changes into this preset"
	_save_btn.focus_mode = Control.FOCUS_NONE
	_save_btn.pressed.connect(func():
		Settings.overwrite_preset()
		_refresh_presets())
	pr.add_child(_save_btn)
	var save := Button.new()
	save.text = "Save as…"
	save.tooltip_text = "Save the current values as a new preset, or type an existing name to replace it"
	save.focus_mode = Control.FOCUS_NONE
	save.pressed.connect(func():
		_save_row.visible = not _save_row.visible
		if _save_row.visible:
			_save_name.text = Settings.preset_name() if Settings.preset_is_user() else ""
			_save_name.grab_focus()
			_save_name.select_all())
	pr.add_child(save)
	var reset_all := Button.new()
	reset_all.theme_type_variation = "FlatButton"
	reset_all.text = "Reset"
	reset_all.tooltip_text = "Drop every change made on top of the preset"
	reset_all.focus_mode = Control.FOCUS_NONE
	reset_all.pressed.connect(Settings.reset_all)
	pr.add_child(reset_all)

	_save_row = HBoxContainer.new()
	_save_row.visible = false
	vb.add_child(_save_row)
	_save_name = LineEdit.new()
	_save_name.placeholder_text = "Preset name"
	_save_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_name.text_submitted.connect(func(_t): _save_preset())
	_save_row.add_child(_save_name)
	var ok := Button.new()
	ok.text = "Save"
	ok.pressed.connect(_save_preset)
	_save_row.add_child(ok)

	_filter = LineEdit.new()
	_filter.placeholder_text = "Find a setting…"
	_filter.tooltip_text = "Tunables only. Toggles live where they act: the viewport ☰ menu, the View tab and the top bar."
	_filter.clear_button_enabled = true
	_filter.right_icon = Style.icon("search")
	_filter.text_changed.connect(func(_t): _apply_filter())
	vb.add_child(_filter)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)

	for g in Settings.groups:
		# toggles with a home elsewhere (☰ menu, View tab, top bar) are
		# changed there only; this panel holds the tunables
		var own: Array = g.settings.filter(func(x): return not x.has("surface"))
		if own.is_empty():
			continue
		var fc := FoldableContainer.new()
		fc.title = Style.text(g.label)
		fc.folded = g.id in ["importance", "history", "performance"]
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 10)
		fc.add_child(box)
		_body.add_child(fc)
		var rows := []
		for s in own:
			var row := SettingRow.new(s.id)
			box.add_child(row)
			rows.append(row)
		_groups.append({"box": fc, "rows": rows})

	_refresh_presets()
	Settings.reloaded.connect(_refresh_presets)
	Settings.presets_changed.connect(_refresh_presets)
	# the "modified" mark: only rebuild when it flips (sliders fire often)
	Settings.changed.connect(func(_id, _v):
		if Settings.is_modified() != _shown_modified:
			_refresh_presets())
	Style.theme_changed.connect(func(): _filter.right_icon = Style.icon("search"))
	gui_input.connect(func(ev):
		if ev is InputEventMouseButton:
			accept_event())  # clicks on the panel never reach the map


func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if visible and k and k.pressed and k.keycode == KEY_ESCAPE:
		hide()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		_filter.grab_focus()


func _save_preset() -> void:
	var n := _save_name.text.strip_edges()
	if n == "":
		return
	Settings.save_preset(n)
	_save_name.text = ""
	_save_row.visible = false
	_refresh_presets()


func _refresh_presets() -> void:
	_preset_opt.clear()
	_preset_ids = []
	var modified := Settings.is_modified()
	_shown_modified = modified
	_save_btn.disabled = not (Settings.preset_is_user() and modified)
	for p in Settings.presets():
		var mark := "  •" if p.id == Settings.preset and modified else ""
		_preset_opt.add_item(p.name + ("  (mine)" if p.user else "") + mark)
		_preset_opt.set_item_tooltip(_preset_ids.size(), p.desc)
		if p.id == Settings.preset:
			_preset_opt.select(_preset_ids.size())
		_preset_ids.append(p.id)


# ------------------------------------------------------------------ filter

func _apply_filter() -> void:
	var q := _filter.text.strip_edges().to_lower()
	for g in _groups:
		var any := false
		for r: SettingRow in g.rows:
			var show: bool = q == "" or r.search_text.contains(q)
			r.visible = show
			any = any or show
		g.box.visible = any
		if q != "" and any:
			g.box.folded = false
