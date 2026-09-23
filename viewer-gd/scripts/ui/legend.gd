class_name Legend
extends PanelContainer
## Viewport corner: what the colors, arcs and highlights on screen mean.
## Rebuilt whenever the view, the overlays or the search change.

signal area_clicked(node: int)

const MAX_AREAS := 6
const MAX_CLUSTERS := 12

var _box: VBoxContainer
var _legend := {}       # hello.legend
var _lens := {}         # active color lens descriptor
var _rel := {}          # {imports: bool, calls: bool} with arcs on screen
var _search := false
var _height := {}       # active height lens descriptor (3D)
var _is3d := false
var _collapsed := false


func _ready() -> void:
	theme_type_variation = "Floating"
	custom_minimum_size = Vector2(220, 0)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 4)
	add_child(_box)
	Settings.changed.connect(func(id, _v):
		if id.begins_with("relations.") or id.begins_with("highlight.") or id.begins_with("viewport."):
			_rebuild())
	Style.theme_changed.connect(_rebuild)


func set_view(legend: Dictionary, lens: Dictionary, height := {}) -> void:
	_legend = legend
	_lens = lens
	_height = height
	_rebuild()


func set_3d(on: bool) -> void:
	_is3d = on
	_rebuild()


func set_relations(imports: bool, calls: bool) -> void:
	_rel = {"imports": imports, "calls": calls}
	_rebuild()


func set_search(active: bool) -> void:
	if _search != active:
		_search = active
		_rebuild()


func _rebuild() -> void:
	if _box == null:
		return
	for c in _box.get_children():
		c.queue_free()
	visible = Settings.get_value("viewport.legend")
	var head := HBoxContainer.new()
	var t := _title(_lens.get("long", "Top-level area") if not _collapsed else "Legend")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var fold := Button.new()
	fold.theme_type_variation = "FlatButton"
	fold.focus_mode = Control.FOCUS_NONE
	fold.icon = Style.icon("chevron")
	fold.tooltip_text = "Show the legend" if _collapsed else "Collapse the legend"
	fold.pressed.connect(func():
		_collapsed = not _collapsed
		_rebuild())
	head.add_child(fold)
	_box.add_child(head)
	if _collapsed:
		return
	if _legend.get("kind", "") == "metric":
		_metric()
	elif _legend.get("kind", "") == "cluster":
		_clusters()
	else:
		_areas()
	if _is3d and not _height.is_empty():
		_box.add_child(HSeparator.new())
		_box.add_child(_title("Height · " + str(_height.get("short", ""))))
		var d := _small(str(_height.get("long", "")) + ("" if _height.get("unit", "") == "" else ": taller = more " + str(_height.unit)))
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(200, 0)
		_box.add_child(d)
	var arcs: bool = Settings.get_value("viewport.arcs")
	if arcs and (_rel.get("imports", false) or _rel.get("calls", false)):
		_box.add_child(HSeparator.new())
		_box.add_child(_title("Relations"))
		if _rel.get("imports", false):
			_box.add_child(_swatch(Settings.get_value("relations.imports_out"), "imports", true))
			_box.add_child(_swatch(Settings.get_value("relations.imports_in"), "imported by", true))
		if _rel.get("calls", false):
			_box.add_child(_swatch(Settings.get_value("relations.calls_out"), "calls", true))
			_box.add_child(_swatch(Settings.get_value("relations.calls_in"), "called by", true))
	_box.add_child(HSeparator.new())
	_box.add_child(_swatch(Settings.get_value("highlight.selection"), "selection", true))
	if Settings.get_value("viewport.hover"):
		_box.add_child(_swatch(Settings.get_value("highlight.hover"), "under the cursor", true))
	if _search and Settings.get_value("viewport.search_hits"):
		_box.add_child(_swatch(Settings.get_value("highlight.search"), "search hits"))


func _metric() -> void:
	var g := Gradient.new()
	var ramp: Array = _legend.get("ramp", [])
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i in ramp.size():
		offsets.append(float(i) / max(ramp.size() - 1, 1))
		colors.append(Color(ramp[i][0], ramp[i][1], ramp[i][2]))
	if ramp.size() >= 2:
		g.offsets = offsets
		g.colors = colors
	var tex := GradientTexture1D.new()
	tex.gradient = g
	var bar := TextureRect.new()
	bar.texture = tex
	bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar.stretch_mode = TextureRect.STRETCH_SCALE
	bar.custom_minimum_size = Vector2(200, 10)
	_box.add_child(bar)
	var q = _legend.get("quantiles")
	var row := HBoxContainer.new()
	if q is Array and q.size() == 5:
		for i in [0, 2, 4]:
			var l := _small(_fmt(q[i]))
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][i / 2]
			row.add_child(l)
		_box.add_child(row)
		_box.add_child(_small("%s · percentile, red = %s" % [_lens.get("unit", ""), _lens.get("high", "high")]))
	else:
		_box.add_child(_small("no values yet" + (" (waiting for git history)" if _lens.get("needsGit", false) else "")))
	_box.add_child(_swatch(Color(0.30, 0.31, 0.34), "no value"))


func _areas() -> void:
	var areas: Array = _legend.get("areas", [])
	var n: int = min(areas.size(), MAX_AREAS)
	for i in n:
		var a: Dictionary = areas[i]
		var row := _swatch(Color(a.color[0], a.color[1], a.color[2]), str(a.name))
		row.tooltip_text = "%s lines · click to select and frame" % Fmt.num(a.get("lines", 0))
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var id := int(a.node)
		row.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				area_clicked.emit(id))
		_box.add_child(row)
	var more: int = areas.size() - n + int(_legend.get("more", 0))
	if more > 0:
		_box.add_child(_small("+%d more" % more))
	_box.add_child(_swatch(Color(0.50, 0.52, 0.56), "binary / data (muted)"))
	_box.add_child(_swatch(Color(0.52, 0.60, 0.58), "vendored / generated (dimmed)"))


func _clusters() -> void:
	var list: Array = _legend.get("clusters", [])
	var n: int = min(list.size(), MAX_CLUSTERS)
	for i in n:
		var c: Dictionary = list[i]
		var row := _swatch(Color(c.color[0], c.color[1], c.color[2]), str(c.name) if str(c.name) != "" else "cluster %d" % (i + 1))
		row.tooltip_text = "%s files · %s lines
mostly in %s · click to frame it" % [
			Fmt.num(c.get("files", 0)), Fmt.num(c.get("lines", 0)), str(c.get("home", ""))]
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var id := int(c.node)
		row.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				area_clicked.emit(id))
		_box.add_child(row)
	var more: int = list.size() - n + int(_legend.get("more", 0))
	if more > 0:
		_box.add_child(_small("+%d smaller clusters" % more))
	var hc: Array = _legend.get("hubColor", [0.96, 0.95, 0.90])
	var nc: Array = _legend.get("noneColor", [0.30, 0.31, 0.34])
	_box.add_child(_swatch(Color(hc[0], hc[1], hc[2]), "hub · imported by much of the code (%d)" % int(_legend.get("hubs", 0))))
	_box.add_child(_swatch(Color(nc[0], nc[1], nc[2]), "unclustered (%s files)" % Fmt.num(_legend.get("unclustered", 0))))


func _title(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SectionLabel"
	l.text = Style.text(t)
	return l


func _small(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SmallLabel"
	l.text = t
	return l


func _swatch(c: Color, text: String, line := false) -> HBoxContainer:
	var hb := HBoxContainer.new()
	var r := ColorRect.new()
	r.color = c
	r.custom_minimum_size = Vector2(18, 3) if line else Vector2(10, 10)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(r)
	hb.add_child(_small(text))
	return hb


static func _fmt(v: float) -> String:
	if v >= 1000.0:
		return Fmt.num(v)
	if v == floor(v):
		return str(int(v))
	return String.num(v, 1)
