extends Control
## App shell: lays out the zones (toolbar, viewport, side panel, status bar)
## and wires them to the views and the server. The pieces live in
## scripts/ui/; scripted runs live in TestDriver.
##
## Command-line (after `--`):
##   --repo=<path>     folder to index when this viewer starts the server
##   --scrap=<exe>     scrap executable (default ../scrap/bin/scrap.exe)
##   --url=<ws url>    server address (default ws://127.0.0.1:7878/ws)
##   --shot=<png> …    scripted run, see test_driver.gd

# arc color settings: [outgoing, incoming] per relation
const REL_COLORS := {
	"edges": ["relations.imports_out", "relations.imports_in"],
	"calls": ["relations.calls_out", "relations.calls_in"],
}

var client: ScrapClient
var map: MapView
var city: CityView
var toolbar: Toolbar
var status: StatusBar
var inspector: Inspector
var search: SearchPanel
var settings_panel: SettingsPanel
var hud: Hud
var hello_info := {}
var args := {}

var _frame: MarginContainer
var _tabs: TabContainer
var _legend: Label
var _legend_box: PanelContainer
var _open_dialog: FileDialog
var _connected := false
var _selected_id := -1
var _rel_reqs := {}          # request id -> op
var _rel := {}               # op -> reply
var _node_req := -1
var _go_parent := false      # next node reply: select its parent
var _fly_after_node := false # next node reply: select it and fly there


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
		elif a.begins_with("--"):
			args[a.substr(2)] = "1"

	client = ScrapClient.new()
	add_child(client)
	_build_ui()
	map.attach(client)
	city.attach(client)
	map.hovered.connect(_on_hover)
	map.selected.connect(_on_selected)
	city.hovered.connect(_on_hover)
	city.selected.connect(_on_selected)
	city.exited.connect(_on_city_exited)
	client.hello.connect(_on_hello)
	client.progress.connect(_on_progress)
	client.reply.connect(_on_reply)
	client.connection_changed.connect(_on_connection)
	Settings.changed.connect(_on_setting_changed)
	Settings.reloaded.connect(func():
		_send_server_settings()
		_push_arcs())
	Style.theme_changed.connect(_apply_theme)
	_apply_theme()

	if args.has("shot"):
		add_child(TestDriver.new(self, args))


func _build_ui() -> void:
	_frame = MarginContainer.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	var root := VBoxContainer.new()
	_frame.add_child(root)

	toolbar = Toolbar.new()
	root.add_child(toolbar)
	toolbar.action.connect(_do_action)
	toolbar.open_folder.connect(func(): _open_dialog.popup_centered_ratio(0.6))
	toolbar.view_selected.connect(set_view)
	toolbar.lens_changed.connect(func(v):
		client.request("options", {"view": v})
		status.set_progress("applying view…"))
	toolbar.relations_changed.connect(_refresh_relations)

	# viewport zone + side panel zone
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	var views := Control.new()
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	views.clip_contents = true
	split.add_child(views)
	map = MapView.new()
	map.set_anchors_preset(Control.PRESET_FULL_RECT)
	views.add_child(map)
	city = CityView.new()
	city.set_anchors_preset(Control.PRESET_FULL_RECT)
	city.visible = false
	views.add_child(city)

	# viewport overlays; the map's tile levels use z up to 1000
	settings_panel = SettingsPanel.new()
	settings_panel.visible = false
	settings_panel.z_index = 2000
	settings_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	settings_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	views.add_child(settings_panel)
	_legend_box = PanelContainer.new()
	_legend_box.theme_type_variation = "Floating"
	_legend_box.z_index = 2000
	_legend_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_legend_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_legend_box.position += Vector2(12, -12)
	_legend_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend_box.visible = false
	_legend = Label.new()
	_legend.theme_type_variation = "SmallLabel"
	_legend_box.add_child(_legend)
	views.add_child(_legend_box)
	hud = Hud.new(map, city)
	hud.z_index = 2000
	hud.position = Vector2(12, 12)
	views.add_child(hud)

	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(340, 0)
	split.add_child(side)
	_tabs = TabContainer.new()
	side.add_child(_tabs)
	inspector = Inspector.new()
	_tabs.add_child(inspector)
	search = SearchPanel.new(client)
	_tabs.add_child(search)
	search.hit_chosen.connect(_go_to_hit)
	search.results_changed.connect(func(files, lines):
		map.set_search_results(files, lines)
		city.set_search_results(files))
	search.cleared.connect(func():
		map.clear_search()
		city.clear_search())
	search.escaped.connect(func(): (city if is_3d() else map).grab_focus())

	status = StatusBar.new()
	root.add_child(status)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.use_native_dialog = true
	_open_dialog.dir_selected.connect(func(d): client.request("open", {"path": d}))
	add_child(_open_dialog)


## Theme values that are not theme items: the outer margin and zone gaps.
func _apply_theme() -> void:
	var gap := int(Style.num("shape", "gap", 10))
	for side in ["left", "top", "right", "bottom"]:
		_frame.add_theme_constant_override("margin_" + side, gap)
	_frame.get_child(0).add_theme_constant_override("separation", gap)


func show_search_tab() -> void:
	_tabs.current_tab = search.get_index()


# ---------------------------------------------------------------- views

func is_3d() -> bool:
	return city.visible


func set_view(three_d: bool) -> void:
	toolbar.set_3d(three_d)
	if three_d == is_3d():
		return
	if three_d:
		city.hit_files = map.hit_files
		city.selection = {} if map.selection_rect.is_empty() else {"rect": map.selection_rect, "top": 0.0}
		city.enter(map.cx, map.cy, map.zoom)
		city.visible = true
		map.visible = false
		city.grab_focus()
	else:
		city.leave()  # tilts up, then _on_city_exited swaps the views


func _on_city_exited(cx: float, cy: float, zoom: float) -> void:
	map.cx = cx
	map.cy = cy
	map.zoom = zoom
	map._zoom_target = zoom
	map._dirty = true
	map.visible = true
	city.visible = false
	map.grab_focus()


# ---------------------------------------------------------------- actions

func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null:
		return
	var action := Keymap.key_action(k)
	if action != "" and _do_action(action):
		get_viewport().set_input_as_handled()


## Runs a keymap action; false when it does not apply here.
func _do_action(action: String) -> bool:
	match action:
		"search":
			show_search_tab()
			search.focus()
		"frame_all":
			if is_3d():
				city.home()
			else:
				map.home()
		"frame_selected":
			if is_3d():
				city.frame_selected()
			else:
				map.frame_selected()
		"deselect":
			map.deselect()
			city.deselect()
		"toggle_view":
			set_view(not is_3d())
		"select_parent":
			if _selected_id >= 0:
				_node_req = client.request("node", {"node": _selected_id})
				_go_parent = true
		"clear":
			if settings_panel.visible:
				settings_panel.hide()
			else:
				search.clear()
		"settings":
			settings_panel.toggle()
		"toggle_hud":
			Settings.set_value("debug.hud", not Settings.get_value("debug.hud"))
		_:
			return false
	return true


# ---------------------------------------------------------------- server

## Settings that live on the server, sent on connect and on change.
func _send_server_settings() -> void:
	if not _connected:
		return
	var weights := {}
	for id in Settings.values_with_scope("server"):
		if id.begins_with("importance."):
			weights[id.substr(11)] = Settings.get_value(id)
	client.request("options", {"weights": weights, "gitSince": Settings.get_value("git.since")})


func _on_setting_changed(id: String, _v: Variant) -> void:
	if id.begins_with("relations."):
		_push_arcs()
	elif Settings.defs.get(id, {}).get("scope", "") == "server":
		_send_server_settings()


func _on_connection(ok: bool) -> void:
	var first := ok and not _connected
	_connected = ok
	if first:
		_send_server_settings()
	status.set_connected(ok)


func _on_hello(info: Dictionary) -> void:
	var regen: bool = hello_info.has("gen") and int(hello_info.gen) != int(info.gen)
	hello_info = info
	toolbar.sync_view(info)
	var lens := toolbar.color_lens_label()
	_legend.text = "" if lens == "" else "blue = low · red = high " + lens.to_lower()
	_legend_box.visible = _legend.text != ""
	if regen:
		_refresh_relations()  # geometry may have moved with the new view
	var s: Dictionary = info.stats
	var pass_name := "precise" if info.precise else "fast"
	status.set_progress("%s · %s files · %s lines · %s pass" % [info.name, Fmt.num(s.Files), Fmt.num(s.Lines), pass_name])
	if int(info.get("protocol", 0)) != ScrapClient.PROTOCOL:
		status.set_progress("server protocol %d ≠ viewer %d — rebuild scrap" % [int(info.get("protocol", 0)), ScrapClient.PROTOCOL])
	get_window().title = "code-scrap — " + String(info.root)
	search.refresh()  # results may have changed with the precise pass


func _on_progress(p: Dictionary) -> void:
	if p.pass == "git":
		if int(p.done) < int(p.total):
			status.set_progress("reading git history…")
		return
	if int(p.total) > 0 and int(p.done) < int(p.total):
		status.set_progress("%s %s %d%%" % [p.pass, p.phase, int(100.0 * p.done / p.total)])


func _on_hover(h: Dictionary) -> void:
	if int(h.get("node", -1)) < 0:
		status.set_status("")
		return
	var path: String = h.get("path", "")
	var dir := path.get_base_dir()
	var line := int(h.get("line", -1))
	var s := "%s (%s/)" % [h.name, dir] if dir != "" else String(h.name)
	if line >= 0:
		s += "  ·  line %d" % (line + 1)
	status.set_status(s)


func _on_selected(id: int) -> void:
	_selected_id = id
	if id < 0:
		inspector.clear_node()
	else:
		_node_req = client.request("node", {"node": id})
	_refresh_relations()


func _on_reply(id: int, data: Dictionary) -> void:
	match data.get("op"):
		"node":
			if id != _node_req:
				return
			if _go_parent:
				_go_parent = false
				var parent := int(data.get("parent", -1))
				if parent >= 0:
					_node_req = client.request("node", {"node": parent})
					_fly_after_node = true
				return
			inspector.show_node(data)
			if _tabs.current_tab != search.get_index() or search.query == "":
				_tabs.current_tab = inspector.get_index()
			if _fly_after_node:
				_fly_after_node = false
				map.select_node(int(data.node), data.rect)
				var t := map.fit_rect(data.rect)
				map.fly_to(t[0], t[1], t[2])
		"edges", "calls":
			if _rel_reqs.get(id, "") == data.op:
				_rel[data.op] = data
				_push_arcs()


# ---------------------------------------------------------------- relations

## Asks for the active relations of the selection; arcs update on reply.
func _refresh_relations() -> void:
	_rel = {}
	_rel_reqs = {}
	_push_arcs()
	if _selected_id < 0:
		return
	if toolbar.imports.button_pressed:
		_rel_reqs[client.request("edges", {"node": _selected_id})] = "edges"
	if toolbar.calls.button_pressed:
		_rel_reqs[client.request("calls", {"node": _selected_id})] = "calls"


func _push_arcs() -> void:
	var list := []
	for op in _rel:
		var r: Dictionary = _rel[op]
		var nodes: Dictionary = r.nodes
		for dir in [0, 1]:
			var key := "out" if dir == 0 else "in"
			for e in r[key]:
				list.append({"a": nodes[str(int(e[0]))], "b": nodes[str(int(e[1]))], "color": Settings.get_value(REL_COLORS[op][dir])})
	map.set_arcs(list)
	city.set_arcs(list)
	inspector.set_relations(_rel)


# ---------------------------------------------------------------- search hits

func _fly_to_search() -> bool:
	return Settings.get_value("camera.fly_to_search") and not args.has("nofly")


func _go_to_hit(h: Dictionary) -> void:
	if is_3d():
		city.current_hit = {"rect": h.rect, "top": float(h.top)}
		city.select(int(h.node), h.rect, float(h.top), "scope" if h.kind != "block" else "file")
		if _fly_to_search():
			city.focus_line(h.rect, float(h.top), 16.0)
		return
	map.current_hit = h.rect
	map.select_node(int(h.node), h.rect)
	if not _fly_to_search():
		return
	if args.has("focus"):
		_node_req = client.request("node", {"node": int(h.fileNode)})
		_fly_after_node = true
	else:
		map.focus_line(h.rect, 16.0)
