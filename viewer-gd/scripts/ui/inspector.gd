class_name Inspector
extends ScrollContainer
## The selection as a route map, read top to bottom: what reaches it, the
## thing itself with what is inside it, and what it reaches for. Every row
## is a button - it goes there; its icon opens the file in an editor.

signal node_clicked(node: int)
signal open_requested(path: String, line: int)

const SHOWN := 5         # rows per direction before "… n more"
const LIST_MAX := 25     # rows per direction once it is opened
const OUTLINE_MAX := 8

var targets: Array[int] = []   # relation endpoints in row order ([ and ] step)
var cursor := -1

var _node := {}
var _rel := {}
var _outline := []       # the selection's children (op "children" items)
var _outline_of := -1
var _anchor := ""        # whose relations are listed, while stepping
var _open_all := {}      # direction key -> showing the long list
var _box: VBoxContainer
var _rows: Array[InspectorRow] = []   # in targets order, for the cursor mark


func _ready() -> void:
	name = "Inspector"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 2)
	add_child(_box)
	Style.theme_changed.connect(_render)
	Settings.changed.connect(func(id, _v):
		if id.begins_with("relations."):
			_render())
	_render()


func show_node(n: Dictionary) -> void:
	_node = n
	if int(n.get("node", -1)) != _outline_of:
		_outline = []
		_outline_of = -1
	_open_all = {}
	_render()


func clear_node() -> void:
	_node = {}
	_rel = {}
	_outline = []
	_outline_of = -1
	_render()


## The selection's children, for the outline (op "children" reply).
func set_outline(node: int, items: Array) -> void:
	_outline_of = node
	_outline = items
	_render()


## rel: op ("edges" | "calls") -> relations reply. anchor: the name of the
## node they belong to when it is not the one shown (stepping through them).
func set_relations(rel: Dictionary, anchor := "") -> void:
	_rel = rel
	_anchor = anchor
	cursor = -1
	_render()


## Moves the relations cursor (1 next, -1 previous); returns the node to go
## to, or -1.
func step(d: int) -> int:
	if targets.is_empty():
		return -1
	cursor = posmod(cursor + d, targets.size())
	for i in _rows.size():
		_rows[i].mark(i == cursor)
	return targets[cursor]


func _render() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	targets = []
	_rows = []
	if _node.is_empty():
		_box.add_child(_note("Click a box on the map to inspect it."))
		return
	# what reaches this, the thing itself, what it reaches for - and only
	# then what it is made of, which is a list, not a route
	_incoming()
	_box.add_child(_card())
	_outgoing()
	_inside()


# ----------------------------------------------------------------- the card

## The selection: its name, where it is, its shape, and what is inside it.
func _card() -> PanelContainer:
	var n := _node
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	card.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	v.add_child(head)
	var title := Label.new()
	title.text = str(n.name)
	title.add_theme_font_override("font", Style.font("ui", 600))
	title.add_theme_font_size_override("font_size", Style.num("font", "size_title", 15))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(title)
	if n.kind != "dir":
		var open := Button.new()
		open.theme_type_variation = "SlimButton"
		open.icon = Style.icon("external", Color(0, 0, 0, 0), 14)
		open.tooltip_text = "Open in an editor"
		open.focus_mode = Control.FOCUS_NONE
		open.pressed.connect(func(): open_requested.emit(str(n.path), int(n.line)))
		head.add_child(open)

	var where := str(n.path)
	if n.kind == "scope":   # a file always starts at line 1: saying so is noise
		where += ":%d" % int(n.line)
	v.add_child(_note(where, "text2"))
	var shape := _note(_shape(n), "text3")
	shape.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	shape.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(shape)

	return card


## The outline: a file's functions, a folder's contents.
func _inside() -> void:
	var rows := _outline_rows(_node)
	if rows.is_empty():
		return
	var scopes: bool = _node.kind != "dir"
	var note := "lines each"
	if scopes:
		note = "" if _node.get("precise", false) else "read by pattern"
	_box.add_child(_head("Inside", rows.size(), Color(0, 0, 0, 0), note))
	for r in rows:
		_box.add_child(r)


## How big it is and what it is made of, in one line.
func _shape(n: Dictionary) -> String:
	var bits := ["%s lines" % Fmt.num(n.lines)]
	if n.kind == "dir":
		bits.append("%s items" % Fmt.num(n.children))
		bits.append("%s inside" % Fmt.num(n.descendants))
	if n.has("fileMetrics"):
		var fm: Dictionary = n.fileMetrics
		bits.append("%d functions" % int(fm.functions))
		bits.append("max complexity %d" % int(fm.maxComplexity))
		if fm.has("commits"):
			bits.append("%s commits" % Fmt.num(fm.commits))
	if n.has("metrics"):
		var m: Dictionary = n.metrics
		bits.append("%d params" % int(m.params))
		bits.append("complexity %d" % int(m.complexity))
	if n.has("lang"):
		bits.append(str(n.lang))
	return " · ".join(bits)


## A file's functions in reading order, or a folder's contents: each row
## carries the line it starts on, or how many lines it holds.
func _outline_rows(n: Dictionary) -> Array[InspectorRow]:
	var out: Array[InspectorRow] = []
	if _outline.is_empty():
		return out
	var scopes: bool = n.kind != "dir"
	var items := _outline.duplicate()
	if scopes:
		items.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))
	var most := items.size() if _open_all.get("outline", false) else OUTLINE_MAX
	for i in mini(items.size(), most):
		var it: Dictionary = items[i]
		var lead := str(int(it.get("line", 0))) if scopes else Fmt.num(it.get("lines", 0))
		var addr := ""
		var kind := str(it.get("scope", it.kind))
		if kind != "func" and kind != "file":
			addr = kind
		elif int(it.get("complexity", 0)) >= 10:
			addr = "complexity %d" % int(it.complexity)
		var row := InspectorRow.new()
		var id := int(it.node)
		row.setup(lead, str(it.name), addr, Color(0, 0, 0, 0), false)
		row.chosen.connect(func(): node_clicked.emit(id))
		out.append(row)
	if items.size() > most:
		out.append(_more_row(items.size() - most, "outline"))
	return out


# ------------------------------------------------------------------- routes

## Above the card: what imports or calls the selection.
func _incoming() -> void:
	var quiet: Array[String] = []
	var any := _direction("edges", "in", "imported by", "relations.imports_in", quiet)
	any = _direction("calls", "in", "called by", "relations.calls_in", quiet) or any
	for q in quiet:
		_box.add_child(_note(q))
	if any:
		_box.add_child(_arrow())


## Below the card: what the selection imports or calls.
func _outgoing() -> void:
	var mark := _arrow()
	_box.add_child(mark)
	var quiet: Array[String] = []
	var any := _direction("edges", "out", "imports", "relations.imports_out", quiet)
	any = _direction("calls", "out", "calls", "relations.calls_out", quiet) or any
	if not any:
		mark.queue_free()
	for q in quiet:
		_box.add_child(_note(q))
	if not targets.is_empty():
		var of := (" of " + _anchor) if _anchor != "" else ""
		_box.add_child(_note("[ and ] step through them" + of))


## One direction of one relation kind. False when there is nothing to show,
## so an arrow only appears where something actually flows.
func _direction(op: String, dir: String, label: String, color_id: String,
		quiet: Array[String]) -> bool:
	if not _rel.has(op):
		return false
	var r: Dictionary = _rel[op]
	var total := int(r[dir + "Total"])
	if total == 0:
		quiet.append("nothing " + label)
		return false
	var color: Color = Settings.get_value(color_id)
	var key := op + dir
	var most := LIST_MAX if _open_all.get(key, false) else SHOWN
	_box.add_child(_head(label, total, color, ""))
	var names: Dictionary = r.get("names", {})
	var base: String = str(_node.get("path", ""))
	if _node.get("kind", "") != "dir":
		base = base.get_base_dir()
	var seen := {}
	for e in r[dir]:
		var other := int(e[1]) if dir == "out" else int(e[0])
		if seen.has(other) or seen.size() >= most:
			continue
		seen[other] = true
		var line := int(e[3]) if dir == "out" else int(e[2])
		var whole: String = str(names.get(str(other), "#%d" % other))
		var row_name := whole
		var addr := ""
		var sep := whole.find(" · ")
		var file := whole
		if sep > 0:   # a function: its name, then the file it lives in
			file = whole.substr(sep + 3)
			row_name = whole.substr(0, sep)
			addr = _near(file, base)
		elif whole.contains("/"):   # a file or a folder: its name, then the way there
			var near := _near(whole, base)
			row_name = near.get_file()
			addr = near.get_base_dir()
		if line >= 0:
			addr += ":%d" % (line + 1)
		var row := InspectorRow.new()
		row.setup("", row_name, addr, color, line >= 0)
		row.chosen.connect(func(): node_clicked.emit(other))
		row.open_requested.connect(func(): open_requested.emit(file, line + 1))
		_box.add_child(row)
		_rows.append(row)
		targets.append(other)
	if total > seen.size():
		_box.add_child(_more_row(total - seen.size(), key))
	return true


# ------------------------------------------------------------------- pieces

## A section heading: the direction, what it counts, in the arc's colour.
func _head(label: String, count: int, color: Color, note: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.add_child(_label(label, "text2" if color.a == 0.0 else "", color))
	if count >= 0:
		box.add_child(_label(str(count), "text3", color))
	if note != "":
		box.add_child(_label(note, "text3", Color(0, 0, 0, 0)))
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_child(box)
	return pad


func _label(text: String, token: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color if color.a > 0.0 else Style.color(token))
	l.add_theme_font_size_override("font_size", Style.num("font", "size_small", 12))
	return l


## The step between what flows in, the card, and what flows out.
func _arrow() -> Control:
	var l := Label.new()
	l.text = "↓"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Style.color("text3"))
	return l


## "… n more": opens the long list when there is one behind it.
func _more_row(n: int, key: String) -> InspectorRow:
	var row := InspectorRow.new()
	row.setup("", "… %d more" % n, "", Color(0, 0, 0, 0), false)
	if key != "":
		row.chosen.connect(func():
			_open_all[key] = true
			_render())
	return row


func _note(text: String, token := "text3") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Style.color(token))
	l.add_theme_font_size_override("font_size", Style.num("font", "size_small", 12))
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## A path as seen from base: the shared folders are dropped, so a file next
## door is just its name.
static func _near(path: String, base: String) -> String:
	if path == "" or base == "":
		return path
	var a := base.split("/")
	var b := path.split("/")
	var i := 0
	while i < a.size() and i < b.size() - 1 and a[i] == b[i]:
		i += 1
	if i == 0:
		return path
	return "/".join(Array(b).slice(i))
