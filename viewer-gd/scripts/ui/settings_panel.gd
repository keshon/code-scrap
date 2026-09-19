class_name SettingsPanel
extends PanelContainer
## Settings, generated from config/settings.schema.json: one foldable group
## per schema group, one row per setting with a control picked by its type.
## Changes apply live and persist; presets load or save whole sets.

var _rows := {}              # id -> {row: Control, refresh: Callable, reset: Button, text: String}
var _groups := []            # [{box: FoldableContainer, ids: Array}]
var _filter: LineEdit
var _preset_opt: OptionButton
var _preset_ids := []
var _save_row: HBoxContainer
var _save_name: LineEdit
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
	var save := Button.new()
	save.text = "Save as…"
	save.tooltip_text = "Save the current values as a new preset"
	save.focus_mode = Control.FOCUS_NONE
	save.pressed.connect(func():
		_save_row.visible = not _save_row.visible
		if _save_row.visible:
			_save_name.grab_focus())
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
		var fc := FoldableContainer.new()
		fc.title = Style.text(g.label)
		fc.folded = g.id in ["importance", "history", "performance"]
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 10)
		fc.add_child(box)
		_body.add_child(fc)
		var ids := []
		for s in g.settings:
			box.add_child(_make_row(s))
			ids.append(s.id)
		_groups.append({"box": fc, "ids": ids})

	_refresh_presets()
	Settings.changed.connect(func(id, _v): _refresh(id))
	Settings.reloaded.connect(func():
		for id in _rows:
			_refresh(id)
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
	for p in Settings.presets():
		_preset_opt.add_item(p.name + ("  (mine)" if p.user else ""))
		_preset_opt.set_item_tooltip(_preset_ids.size(), p.desc)
		if p.id == Settings.preset:
			_preset_opt.select(_preset_ids.size())
		_preset_ids.append(p.id)


# ------------------------------------------------------------------ rows

func _make_row(def: Dictionary) -> Control:
	var id: String = def.id
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var line := HBoxContainer.new()
	row.add_child(line)
	var label := Label.new()
	label.text = def.label
	label.tooltip_text = "%s\n%s" % [def.get("desc", ""), id]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)

	var refresh: Callable
	match def.type:
		"bool":
			var cb := CheckButton.new()
			cb.focus_mode = Control.FOCUS_NONE
			cb.toggled.connect(func(on): Settings.set_value(id, on))
			line.add_child(cb)
			refresh = func(v): cb.set_pressed_no_signal(v)
		"int", "float":
			var sl := HSlider.new()
			sl.custom_minimum_size = Vector2(120, 0)
			sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sl.focus_mode = Control.FOCUS_NONE
			var sp := SpinBox.new()
			sp.custom_minimum_size = Vector2(84, 0)
			for r in [sl, sp]:
				r.min_value = def.get("min", 0)
				r.max_value = def.get("max", 100)
				r.step = def.get("step", 1 if def.type == "int" else 0.01)
			sl.value_changed.connect(func(v): Settings.set_value(id, v))
			sp.value_changed.connect(func(v): Settings.set_value(id, v))
			line.add_child(sl)
			line.add_child(sp)
			refresh = func(v):
				sl.set_value_no_signal(v)
				sp.set_value_no_signal(v)
		"color":
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(64, 24)
			cp.edit_alpha = false
			cp.focus_mode = Control.FOCUS_NONE
			cp.color_changed.connect(func(c): Settings.set_value(id, c))
			line.add_child(cp)
			refresh = func(v): cp.color = v
		"enum":
			var ob := OptionButton.new()
			ob.custom_minimum_size = Vector2(160, 0)
			ob.focus_mode = Control.FOCUS_NONE
			var opts := Settings.options(id)
			for i in opts.size():
				ob.add_item(opts[i].name)
				ob.set_item_tooltip(i, opts[i].desc)
			ob.item_selected.connect(func(i): Settings.set_value(id, opts[i].id))
			line.add_child(ob)
			refresh = func(v):
				for i in opts.size():
					if opts[i].id == v:
						ob.select(i)
		_:
			var le := LineEdit.new()
			le.custom_minimum_size = Vector2(160, 0)
			le.text_submitted.connect(func(t): Settings.set_value(id, t))
			le.focus_exited.connect(func(): Settings.set_value(id, le.text))
			line.add_child(le)
			refresh = func(v): le.text = str(v)

	var reset := Button.new()
	reset.theme_type_variation = "FlatButton"
	reset.icon = Style.icon("reset")
	reset.tooltip_text = "Back to the preset value"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(func(): Settings.reset(id))
	line.add_child(reset)

	if def.get("desc", "") != "":
		var d := Label.new()
		d.theme_type_variation = "SmallLabel"
		d.text = def.desc
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(200, 0)
		row.add_child(d)

	_rows[id] = {"row": row, "refresh": refresh, "reset": reset,
		"text": ("%s %s %s" % [def.label, def.get("desc", ""), id]).to_lower()}
	_refresh(id)
	return row


func _refresh(id: String) -> void:
	var r: Dictionary = _rows.get(id, {})
	if r.is_empty():
		return
	r.refresh.call(Settings.get_value(id))
	# keep the column steady: hide the reset glyph without collapsing it
	r.reset.modulate.a = 1.0 if Settings.is_overridden(id) else 0.0
	r.reset.disabled = not Settings.is_overridden(id)


func _apply_filter() -> void:
	var q := _filter.text.strip_edges().to_lower()
	for g in _groups:
		var any := false
		for id in g.ids:
			var r: Dictionary = _rows[id]
			var show: bool = q == "" or r.text.contains(q)
			r.row.visible = show
			any = any or show
		g.box.visible = any
		if q != "" and any:
			g.box.folded = false
