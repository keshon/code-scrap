class_name SettingRow
extends VBoxContainer
## One setting as a labelled control picked by its schema type, kept in sync
## with Settings both ways. Used by the settings panel and by panels that
## embed a few settings (Display panel).

var id: String
var def: Dictionary
var search_text: String  # label + description + id, lowercased (for filters)
var _refresh: Callable
var _reset: Button


## compact: for narrow panels. The description is a tooltip, there is no
## reset button, and anything but a switch sits below its label at full width.
func _init(setting_id: String, compact := false) -> void:
	id = setting_id
	def = Settings.defs.get(id, {})
	add_theme_constant_override("separation", 2)
	var line := HBoxContainer.new()
	add_child(line)
	var label := Label.new()
	label.text = def.get("label", id)
	label.tooltip_text = "%s\n%s" % [def.get("desc", ""), id]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	line.add_child(label)
	if compact and def.get("type", "") != "bool":
		label.theme_type_variation = "DimLabel"
		line = HBoxContainer.new()
		add_child(line)

	match def.get("type", "string"):
		"bool":
			var cb := CheckButton.new()
			cb.focus_mode = Control.FOCUS_NONE
			cb.toggled.connect(func(on): Settings.set_value(id, on))
			line.add_child(cb)
			_refresh = func(v): cb.set_pressed_no_signal(v)
		"int", "float":
			var sl := HSlider.new()
			sl.custom_minimum_size = Vector2(90 if compact else 120, 0)
			if compact:
				sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sl.focus_mode = Control.FOCUS_NONE
			var sp := SpinBox.new()
			sp.custom_minimum_size = Vector2(76 if compact else 84, 0)
			for r in [sl, sp]:
				r.min_value = def.get("min", 0)
				r.max_value = def.get("max", 100)
				r.step = def.get("step", 1 if def.type == "int" else 0.01)
			sl.value_changed.connect(func(v): Settings.set_value(id, v))
			sp.value_changed.connect(func(v): Settings.set_value(id, v))
			line.add_child(sl)
			line.add_child(sp)
			_refresh = func(v):
				sl.set_value_no_signal(v)
				sp.set_value_no_signal(v)
		"color":
			var cp := ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(64, 24)
			cp.edit_alpha = false
			cp.focus_mode = Control.FOCUS_NONE
			cp.color_changed.connect(func(c): Settings.set_value(id, c))
			line.add_child(cp)
			_refresh = func(v): cp.color = v
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
			_refresh = func(v):
				for i in opts.size():
					if opts[i].id == v:
						ob.select(i)
		_:
			var le := LineEdit.new()
			le.custom_minimum_size = Vector2(120 if compact else 160, 0)
			if compact:
				le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(t): Settings.set_value(id, t))
			le.focus_exited.connect(func(): Settings.set_value(id, le.text))
			line.add_child(le)
			_refresh = func(v): le.text = str(v)

	if not compact:
		_reset = Button.new()
		_reset.theme_type_variation = "FlatButton"
		_reset.icon = Style.icon("reset")
		_reset.tooltip_text = "Back to the preset value"
		_reset.focus_mode = Control.FOCUS_NONE
		_reset.pressed.connect(func(): Settings.reset(id))
		line.add_child(_reset)
		if def.get("desc", "") != "":
			var d := Label.new()
			d.theme_type_variation = "SmallLabel"
			d.text = def.desc
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.custom_minimum_size = Vector2(200, 0)
			add_child(d)

	search_text = ("%s %s %s" % [def.get("label", ""), def.get("desc", ""), id]).to_lower()
	refresh()
	Settings.changed.connect(func(changed_id, _v):
		if changed_id == id:
			refresh())
	Settings.reloaded.connect(refresh)


func refresh() -> void:
	_refresh.call(Settings.get_value(id))
	if _reset:
		# keep the column steady: hide the reset glyph without collapsing it
		_reset.modulate.a = 1.0 if Settings.is_overridden(id) else 0.0
		_reset.disabled = not Settings.is_overridden(id)
