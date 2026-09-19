class_name SearchPopup
extends PanelContainer
## The one search: a dropdown under the top bar's field, like an editor's
## quick-open. Plain text finds files and folders (path contains every
## word) and symbols (name starts with the text); ">" lists commands.
## Up/Down move, Enter or a click goes there, Esc closes. Files with symbol
## hits stay highlighted on the map while the text is in the field.

signal hit_chosen(hit: Dictionary, fly: bool)
signal path_chosen(node: int, fly: bool)
signal command_chosen(id: String)
signal results_changed(files: Array, lines: Array)
signal cleared
signal escaped                  # Esc or a choice: give focus back to the view

const SYMBOLS_SHOWN := 60

var client: ScrapClient
var field: LineEdit
var commands := []              # [{id, label, keys}] for ">" mode
var auto_step_first := false    # choose the first symbol hit when results arrive (automation)

var query := ""
var _req := -1
var _tree: Tree
var _info: Label
var _timer: Timer
var _rows := []                 # selectable TreeItems in display order


func _init(c: ScrapClient) -> void:
	client = c


func _ready() -> void:
	visible = false  # opaque panel: the map must not show through the list
	custom_minimum_size = Vector2(420, 0)
	var vb := VBoxContainer.new()
	add_child(vb)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, true)
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 2)
	_tree.focus_mode = Control.FOCUS_NONE  # typing stays in the field
	_tree.custom_minimum_size = Vector2(0, 360)
	_tree.item_mouse_selected.connect(func(_p, _b): _activate(_tree.get_selected()))
	vb.add_child(_tree)
	_info = Label.new()
	_info.theme_type_variation = "SmallLabel"
	vb.add_child(_info)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.06
	_timer.timeout.connect(_run)
	add_child(_timer)
	client.reply.connect(_on_reply)


## Attaches the text field that drives the popup (it lives in the top bar).
func bind_field(f: LineEdit) -> void:
	field = f
	field.text_changed.connect(func(_t): _timer.start())
	field.gui_input.connect(_on_key)
	field.focus_entered.connect(func():
		if field.text.strip_edges() != "":
			_show_popup())
	field.focus_exited.connect(func(): visible = false)


func focus() -> void:
	field.grab_focus()
	field.select_all()


## Sets the field text and searches right away (automation).
func search(q: String) -> void:
	field.text = q
	_run()


## Re-runs the current query (e.g. after a new map generation).
func refresh() -> void:
	if query != "":
		_request()


func clear() -> void:
	query = ""
	_tree.clear()
	_rows = []
	visible = false
	cleared.emit()


func _show_popup() -> void:
	var r := field.get_global_rect()
	position = Vector2(r.position.x, r.end.y + 4)
	size.x = max(r.size.x, custom_minimum_size.x)
	reset_size()
	size.x = max(r.size.x, custom_minimum_size.x)
	visible = true


func _run() -> void:
	var t := field.text.strip_edges()
	if t.begins_with(">"):
		if query != "":
			query = ""
			cleared.emit()
		_show_commands(t.substr(1).strip_edges().to_lower())
		return
	query = t
	if query == "":
		clear()
		return
	_request()


func _request() -> void:
	_req = client.request("search", {"q": query, "page": 0, "size": SYMBOLS_SHOWN})


func _on_reply(id: int, data: Dictionary) -> void:
	if data.get("op") == "search" and id == _req:
		_show(data)


# ---------------------------------------------------------------- rows

func _begin() -> TreeItem:
	_tree.clear()
	_rows = []
	return _tree.create_item()


func _section(root: TreeItem, title: String) -> void:
	var it := _tree.create_item(root)
	it.set_text(0, Style.text(title))
	it.set_custom_color(0, Style.color("text3"))
	it.set_selectable(0, false)
	it.set_selectable(1, false)


func _row(root: TreeItem, icon: Texture2D, text: String, detail: String, meta: Dictionary) -> void:
	var it := _tree.create_item(root)
	it.set_icon(0, icon)
	it.set_text(0, text)
	it.set_text(1, detail)
	it.set_custom_color(1, Style.color("text3"))
	it.set_tooltip_text(0, detail)
	it.set_metadata(0, meta)
	_rows.append(it)


func _show_commands(q: String) -> void:
	var root := _begin()
	for c in commands:
		if q == "" or c.label.to_lower().contains(q) or c.id.contains(q):
			_row(root, Style.icon("command"), c.label, c.get("keys", ""), {"command": c.id})
	_info.text = "%d commands" % _rows.size()
	_finish()


func _show(r: Dictionary) -> void:
	if r.q != query:
		return
	var root := _begin()
	var paths: Array = r.get("paths", [])
	if not paths.is_empty():
		_section(root, "Files and folders")
		for p in paths:
			var icon := Style.icon("folder" if p.kind == "dir" else "file")
			_row(root, icon, str(p.name), String(p.path).get_base_dir(), {"path": int(p.node)})
	if not r.hits.is_empty():
		_section(root, "Symbols")
		for h in r.hits:
			_row(root, Style.icon("symbol"), str(h.name), "%s:%d" % [Fmt.short_path(h.path, 40), int(h.line)], {"hit": h})
	var parts := []
	if int(r.get("pathTotal", 0)) > 0:
		parts.append("%d paths" % int(r.pathTotal))
	parts.append("%d%s symbols" % [int(r.total), "+" if r.more else ""])
	if int(r.total) > r.hits.size():
		parts.append("showing %d, keep typing to narrow" % r.hits.size())
	_info.text = "  ·  ".join(parts) + "  ·  %.1f ms" % r.ms
	if _rows.is_empty():
		_info.text = "No files, folders or symbols match “%s”" % query
	var lines := []
	for h in r.hits:
		lines.append(h.rect)
	results_changed.emit(r.files, lines)
	if auto_step_first and not r.hits.is_empty():
		auto_step_first = false
		hit_chosen.emit(r.hits[0], true)
		return
	_finish()


func _finish() -> void:
	if not _rows.is_empty():
		_rows[0].select(0)
		_tree.scroll_to_item(_rows[0])
	if field.has_focus():
		_show_popup()


# ---------------------------------------------------------------- keys

func _on_key(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed:
		return
	match k.keycode:
		KEY_DOWN, KEY_UP:
			_move(1 if k.keycode == KEY_DOWN else -1)
			field.accept_event()
		KEY_PAGEDOWN, KEY_PAGEUP:
			_move(10 if k.keycode == KEY_PAGEDOWN else -10)
			field.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_activate(_tree.get_selected())
			field.accept_event()
		KEY_ESCAPE:
			if visible:
				visible = false
			else:
				field.text = ""
				clear()
			escaped.emit()
			field.accept_event()


func _move(d: int) -> void:
	if _rows.is_empty():
		return
	if not visible:
		_show_popup()
	var cur := _rows.find(_tree.get_selected())
	var i: int = clamp(cur + d, 0, _rows.size() - 1)
	_rows[i].select(0)
	_tree.scroll_to_item(_rows[i])


func _activate(it: TreeItem) -> void:
	if it == null or it.get_metadata(0) == null:
		return
	var meta: Dictionary = it.get_metadata(0)
	var fly: bool = Settings.get_value("camera.fly_to_search")
	visible = false
	if meta.has("command"):
		field.text = ""
		_tree.clear()
		_rows = []
		escaped.emit()
		command_chosen.emit(meta.command)
		return
	escaped.emit()
	if meta.has("hit"):
		hit_chosen.emit(meta.hit, fly)
	elif meta.has("path"):
		path_chosen.emit(meta.path, fly)
