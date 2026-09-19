class_name SearchPanel
extends VBoxContainer
## Symbol search: a prefix filter, hits grouped by file, paging, stepping
## through hits with Enter / Shift+Enter.

signal hit_chosen(hit: Dictionary)          # a hit was picked (click or Enter)
signal results_changed(files: Array, lines: Array)
signal cleared
signal escaped                               # Esc in the field: give focus back

var client: ScrapClient
var auto_step_first := false  # step to the first hit when results arrive (automation)

var query := ""
var _page := 0
var _hits := []               # hit dictionaries in display order
var _item_of := {}            # hit index -> TreeItem
var _index := -1
var _req := -1
var _edit: LineEdit
var _info: Label
var _results: Tree
var _more: Button
var _timer: Timer


func _init(c: ScrapClient) -> void:
	client = c


func _ready() -> void:
	name = "Search"
	_edit = LineEdit.new()
	_edit.placeholder_text = "Symbol prefix…"
	_edit.tooltip_text = "Search symbol names · type a prefix; Enter steps through the hits · / or Ctrl+K"
	_edit.clear_button_enabled = true
	_edit.right_icon = Style.icon("search")
	_edit.text_changed.connect(func(_t): _timer.start())
	_edit.gui_input.connect(_on_key)
	add_child(_edit)
	_info = Label.new()
	_info.theme_type_variation = "SmallLabel"
	add_child(_info)
	_results = Tree.new()
	_results.hide_root = true
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.item_selected.connect(_on_selected)
	add_child(_results)
	_more = Button.new()
	_more.text = "More results"
	_more.visible = false
	_more.pressed.connect(func():
		_page += 1
		_request(false))
	add_child(_more)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.06
	_timer.timeout.connect(_run)
	add_child(_timer)
	client.reply.connect(_on_reply)
	Style.theme_changed.connect(func(): _edit.right_icon = Style.icon("search"))
	_reset_info()


func focus() -> void:
	_edit.grab_focus()
	_edit.select_all()


## Sets the filter text and searches right away.
func search(q: String) -> void:
	_edit.text = q
	_run()


## Re-runs the current query (e.g. after a new map generation).
func refresh() -> void:
	if query != "":
		_request(true)


func clear() -> void:
	query = ""
	_hits = []
	_index = -1
	_results.clear()
	_more.visible = false
	_reset_info()
	cleared.emit()


func _reset_info() -> void:
	_info.text = "Type in the filter to list its hits"


func _run() -> void:
	query = _edit.text.strip_edges()
	_page = 0
	if query == "":
		clear()
		return
	_request(true)


func _request(reset: bool) -> void:
	if reset:
		_page = 0
	_req = client.request("search", {"q": query, "page": _page, "size": 64})


func _on_reply(id: int, data: Dictionary) -> void:
	if data.get("op") == "search" and id == _req:
		_show(data)


func _show(r: Dictionary) -> void:
	if r.q != query:
		return
	if int(r.page) == 0:
		_results.clear()
		_hits = []
		_item_of = {}
		_index = -1
	var root := _results.get_root()
	if root == null:
		root = _results.create_item()
	var file_item: TreeItem = null
	var last_path := ""
	# continue the last file group across pages
	if root.get_child_count() > 0:
		file_item = root.get_child(root.get_child_count() - 1)
		last_path = file_item.get_metadata(0)
	for h in r.hits:
		if h.path != last_path:
			file_item = _results.create_item(root)
			file_item.set_text(0, Fmt.short_path(h.path))
			file_item.set_tooltip_text(0, h.path)
			file_item.set_metadata(0, h.path)
			file_item.set_custom_color(0, Style.color("text2"))
			file_item.set_selectable(0, false)
			last_path = h.path
		var it := _results.create_item(file_item)
		it.set_text(0, "%5d   %s" % [int(h.line), h.name])
		it.set_tooltip_text(0, "%s · %s:%d" % [h.kind, h.path, int(h.line)])
		it.set_metadata(0, _hits.size())
		_item_of[_hits.size()] = it
		_hits.append(h)
	_info.text = "%s · %d%s hits · %d files · %.1f ms" % [query, int(r.total), "+" if r.more else "", r.files.size(), r.ms]
	_more.visible = _hits.size() < int(r.total)
	var lines := []
	for h in _hits:
		lines.append(h.rect)
	results_changed.emit(r.files, lines)
	if auto_step_first and _index < 0 and not _hits.is_empty():
		step(1)


func _on_key(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		step(-1 if k.shift_pressed else 1)
		_edit.accept_event()
	elif k.keycode == KEY_ESCAPE:
		_edit.text = ""
		clear()
		escaped.emit()
		_edit.accept_event()


## Moves to the next (d = 1) or previous (d = -1) hit.
func step(d: int) -> void:
	if _hits.is_empty():
		return
	_index = posmod(_index + d, _hits.size())
	var it: TreeItem = _item_of.get(_index)
	if it != null:
		_results.set_selected(it, 0)  # emits item_selected → _on_selected
		_results.scroll_to_item(it)
	else:
		hit_chosen.emit(_hits[_index])


func _on_selected() -> void:
	var it := _results.get_selected()
	if it == null or it.get_metadata(0) is String:
		return
	_index = int(it.get_metadata(0))
	hit_chosen.emit(_hits[_index])
