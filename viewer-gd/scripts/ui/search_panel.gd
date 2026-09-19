class_name SearchPanel
extends VBoxContainer
## Results of the top bar's field: symbol hits grouped by file, or commands
## when the text starts with ">".
##
## Click a line to select its symbol, a file row to select the file;
## double-click or Enter also flies there ("Fly to result" flies on every
## click). Enter / Shift+Enter in the field step through the hits.

signal hit_chosen(hit: Dictionary, fly: bool)
signal file_chosen(node: int, fly: bool)
signal command_chosen(id: String)
signal results_changed(files: Array, lines: Array)
signal cleared
signal escaped                               # Esc in the field: give focus back

var client: ScrapClient
var field: LineEdit
var commands := []            # [{id, label, keys}] offered in command mode
var auto_step_first := false  # step to the first hit when results arrive (automation)

var query := ""
var _page := 0
var _hits := []               # hit dictionaries in display order
var _item_of := {}            # hit index -> TreeItem
var _index := -1
var _req := -1
var _info: Label
var _results: Tree
var _more: Button
var _timer: Timer
var _commands_shown := []


func _init(c: ScrapClient) -> void:
	client = c


func _ready() -> void:
	name = "Search"
	var head := HBoxContainer.new()
	add_child(head)
	_info = Label.new()
	_info.theme_type_variation = "SmallLabel"
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_info)
	var fly := CheckBox.new()
	fly.text = "Fly"
	fly.tooltip_text = "Fly to a result when it is clicked (double-click and Enter always fly)"
	fly.focus_mode = Control.FOCUS_NONE
	fly.button_pressed = _fly_default()
	fly.toggled.connect(func(on): Settings.set_value("camera.fly_to_search", on))
	Settings.changed.connect(func(id, v):
		if id == "camera.fly_to_search":
			fly.set_pressed_no_signal(v))
	head.add_child(fly)
	_results = Tree.new()
	_results.hide_root = true
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.item_selected.connect(_on_selected)
	_results.item_activated.connect(_on_activated)
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
	_reset_info()


## Attaches the text field that drives the panel (it lives in the top bar).
func bind_field(f: LineEdit) -> void:
	field = f
	field.text_changed.connect(func(_t): _timer.start())
	field.gui_input.connect(_on_key)


func focus() -> void:
	field.grab_focus()
	field.select_all()


## Sets the field text and searches right away.
func search(q: String) -> void:
	field.text = q
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
	_info.text = "Type a symbol prefix in the search field"


func _fly_default() -> bool:
	return Settings.get_value("camera.fly_to_search")


func _run() -> void:
	var t := field.text.strip_edges()
	if t.begins_with(">"):
		_show_commands(t.substr(1).strip_edges().to_lower())
		return
	query = t
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


# ---------------------------------------------------------------- commands

func _show_commands(q: String) -> void:
	if query != "":
		clear()
	_results.clear()
	_results.columns = 2
	_results.set_column_expand(1, false)
	_results.set_column_custom_minimum_width(1, 90)
	_commands_shown = []
	var root := _results.create_item()
	for c in commands:
		if q == "" or c.label.to_lower().contains(q) or c.id.contains(q):
			var it := _results.create_item(root)
			it.set_text(0, c.label)
			it.set_text(1, c.get("keys", ""))
			it.set_custom_color(1, Style.color("text3"))
			it.set_icon(0, Style.icon("command"))
			it.set_metadata(0, {"command": c.id})
			_commands_shown.append(c.id)
	_info.text = "%d commands · Enter runs the first" % _commands_shown.size()
	_more.visible = false


# ---------------------------------------------------------------- results

func _show(r: Dictionary) -> void:
	if r.q != query:
		return
	if int(r.page) == 0:
		_results.clear()
		_results.columns = 1
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
		last_path = file_item.get_metadata(0).path
	for h in r.hits:
		if h.path != last_path:
			file_item = _results.create_item(root)
			file_item.set_text(0, Fmt.short_path(h.path))
			file_item.set_tooltip_text(0, h.path + "\nClick to select the file, double-click to fly there")
			file_item.set_metadata(0, {"path": h.path, "file": int(h.fileNode)})
			file_item.set_icon(0, Style.icon("file"))
			file_item.set_custom_color(0, Style.color("text2"))
			last_path = h.path
		var it := _results.create_item(file_item)
		it.set_text(0, "%5d   %s" % [int(h.line), h.name])
		it.set_tooltip_text(0, "%s · %s:%d" % [h.kind, h.path, int(h.line)])
		it.set_metadata(0, {"hit": _hits.size()})
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
		if field.text.strip_edges().begins_with(">"):
			if not _commands_shown.is_empty():
				var id: String = _commands_shown[0]
				field.text = ""
				_results.clear()
				_reset_info()
				escaped.emit()
				command_chosen.emit(id)
		else:
			step(-1 if k.shift_pressed else 1)
		field.accept_event()
	elif k.keycode == KEY_DOWN and _results.get_root() != null:
		_results.grab_focus()
		field.accept_event()
	elif k.keycode == KEY_ESCAPE:
		field.text = ""
		clear()
		escaped.emit()
		field.accept_event()


## Moves to the next (d = 1) or previous (d = -1) hit and flies there.
func step(d: int) -> void:
	if _hits.is_empty():
		return
	_index = posmod(_index + d, _hits.size())
	var it: TreeItem = _item_of.get(_index)
	if it != null:
		_results.set_selected(it, 0)
		_results.scroll_to_item(it)
	hit_chosen.emit(_hits[_index], true)


func _on_selected() -> void:
	_choose(_fly_default(), false)


func _on_activated() -> void:
	_choose(true, true)


func _choose(fly: bool, activated: bool) -> void:
	var it := _results.get_selected()
	if it == null:
		return
	var meta: Dictionary = it.get_metadata(0)
	if meta.has("command"):
		command_chosen.emit(meta.command)
	elif meta.has("hit"):
		var i: int = meta.hit
		if i == _index and not activated:
			return  # already chosen by step()
		_index = i
		hit_chosen.emit(_hits[i], fly)
	elif meta.has("file"):
		file_chosen.emit(meta.file, fly)
