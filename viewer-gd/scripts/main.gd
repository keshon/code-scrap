extends Control
## App shell: toolbar + status line, the map, and the Inspector/Search panel.
##
## Command-line (after `--`):
##   --repo=<path>     folder to index when this viewer starts the server
##   --scrap=<exe>     scrap executable (default ../scrap/bin/scrap.exe)
##   --url=<ws url>    server address (default ws://127.0.0.1:7878/ws)
##   --shot=<png>      save a screenshot after --wait seconds, then quit
##   --wait=<sec>      (default 4)
##   --search=<q>      run a search once connected and step to the first hit
##   --focus=<substr>  fly to the first search hit's file instead of the line
##   --view=3d         switch to the 3D city once connected (--yaw, --pitch, --dist, --wheel=N)
##   --lens=height:churn,color:complexity,importance   apply lenses once git is loaded
##   --rel=imports,calls   turn relation arcs on (use with --search to select)
##   --nofly           select search hits without flying to them
##   --settings        open the settings panel

var client: ScrapClient
var map: MapView
var city: CityView
var _v2d: Button
var _v3d: Button
var _height_opt: OptionButton
var _color_opt: OptionButton
var _importance: CheckButton
var _legend: Label
var _syncing_view := false
var _imports_btn: CheckButton
var _calls_btn: CheckButton
var _selected_id := -1
var _rel_reqs := {}          # request id -> op
var _rel := {}               # op -> reply
var _node_info := {}

# arc color settings: [outgoing, incoming] per relation
const REL_COLORS := {
	"edges": ["relations.imports_out", "relations.imports_in"],
	"calls": ["relations.calls_out", "relations.calls_in"],
}

# lenses: [id, label, needs git]
const HEIGHTS := [["depth", "Nesting", false], ["flat", "Flat", false], ["lines", "Lines", false],
	["complexity", "Complexity", false], ["functions", "Functions", false], ["churn", "Churn", true],
	["age", "Recent change", true], ["authors", "Authors", true]]
const COLORS := [["area", "Area", false], ["lines", "Lines", false], ["complexity", "Complexity", false],
	["functions", "Functions", false], ["churn", "Churn", true], ["age", "Recent change", true],
	["authors", "Authors", true]]

var _status: Label
var _progress: Label
var _dot: ColorRect
var _inspector: RichTextLabel
var _tabs: TabContainer
var _search_edit: LineEdit
var _search_info: Label
var _results: Tree
var _more_btn: Button
var _open_dialog: FileDialog

var _hello := {}
var _search_q := ""
var _search_page := 0
var _search_hits := []          # hit dictionaries in display order
var _search_item_of := {}       # hit index -> TreeItem
var _hit_index := -1
var _search_req := -1
var _node_req := -1
var _search_timer: Timer

var _args := {}
var _frame: MarginContainer
var _settings: SettingsPanel
var _legend_box: PanelContainer
var _hints: Label
var _icon_buttons: Array[Button] = []
var _connected := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			_args[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)

	client = ScrapClient.new()
	add_child(client)
	_build_ui()
	map.attach(client)
	city.attach(client)
	city.hovered.connect(_on_hover)
	city.selected.connect(_on_selected)
	city.exited.connect(_on_city_exited)
	client.hello.connect(_on_hello)
	client.progress.connect(_on_progress)
	client.reply.connect(_on_reply)
	client.connection_changed.connect(_on_connection)
	map.hovered.connect(_on_hover)
	map.selected.connect(_on_selected)
	Settings.changed.connect(_on_setting_changed)
	Settings.reloaded.connect(func():
		_send_server_settings()
		_push_arcs())

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.06
	_search_timer.timeout.connect(_run_search)
	add_child(_search_timer)

	if _args.has("shot"):
		_automate()


func _build_ui() -> void:
	_frame = MarginContainer.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	var root := VBoxContainer.new()
	_frame.add_child(root)

	# toolbar zone
	var bar := PanelContainer.new()
	bar.theme_type_variation = "Bar"
	root.add_child(bar)
	# the toolbar clips instead of forcing its width on the window
	var bar_clip := ScrollContainer.new()
	bar_clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	bar_clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bar.add_child(bar_clip)
	var hb := HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_clip.add_child(hb)
	var title := Label.new()
	title.theme_type_variation = "TitleLabel"
	title.text = "code-scrap"
	hb.add_child(title)
	hb.add_child(VSeparator.new())
	hb.add_child(_icon_button("home", "Frame all (A)", func(): _do_action("frame_all")))
	hb.add_child(_icon_button("frame", "Frame selected (F)", func(): _do_action("frame_selected")))
	hb.add_child(_icon_button("folder", "Open folder…", _open_folder))
	hb.add_child(VSeparator.new())
	var seg := PanelContainer.new()
	seg.theme_type_variation = "Inset"
	hb.add_child(seg)
	var segs := HBoxContainer.new()
	segs.add_theme_constant_override("separation", 2)
	seg.add_child(segs)
	var group := ButtonGroup.new()
	_v2d = _segment("2D", "Flat map (Tab toggles)", group, func(): set_view(false))
	_v2d.button_pressed = true
	segs.add_child(_v2d)
	_v3d = _segment("3D", "3D city (Tab toggles)", group, func(): set_view(true))
	segs.add_child(_v3d)
	hb.add_child(VSeparator.new())
	hb.add_child(_small_label("Height"))
	_height_opt = _lens_picker(HEIGHTS, "What building height encodes (3D). Git lenses need history, loaded in the background.")
	hb.add_child(_height_opt)
	hb.add_child(_small_label("Color"))
	_color_opt = _lens_picker(COLORS, "What box color encodes: the top-level area, or a metric as a cold (blue) → hot (red) percentile.")
	hb.add_child(_color_opt)
	_importance = CheckButton.new()
	_importance.text = "Importance"
	_importance.tooltip_text = "Shrink vendored, test, generated, asset and data files so the core code gets the space. Weights: Settings → Importance weights."
	_importance.focus_mode = Control.FOCUS_NONE
	_importance.toggled.connect(func(_on): _send_view())
	hb.add_child(_importance)
	hb.add_child(VSeparator.new())
	_imports_btn = _relation_toggle("Imports", "Show what the selection imports and what imports it.")
	hb.add_child(_imports_btn)
	_calls_btn = _relation_toggle("Calls", "Show what the selected function or file calls and who calls it. Syntax-level: ambiguous names are skipped.")
	hb.add_child(_calls_btn)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	hb.add_child(_icon_button("settings", "Settings (Ctrl+,)", func(): _do_action("settings")))

	# body: viewport zone + side panel zone
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
	_settings = SettingsPanel.new()
	_settings.visible = false
	_settings.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_settings.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_settings.z_index = 2000  # the map's tile levels use z up to 1000
	views.add_child(_settings)
	_legend = Label.new()
	_legend.theme_type_variation = "SmallLabel"
	var legend_box := PanelContainer.new()
	legend_box.theme_type_variation = "Floating"
	legend_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	legend_box.position += Vector2(12, -12)
	legend_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	legend_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	legend_box.visible = false
	legend_box.z_index = 2000
	legend_box.add_child(_legend)
	views.add_child(legend_box)
	_legend_box = legend_box

	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(340, 0)
	split.add_child(side)
	_tabs = TabContainer.new()
	side.add_child(_tabs)

	_inspector = RichTextLabel.new()
	_inspector.name = "Inspector"
	_inspector.bbcode_enabled = true
	_inspector.selection_enabled = true
	_tabs.add_child(_inspector)
	_inspector_hint()

	var sv := VBoxContainer.new()
	sv.name = "Search"
	_tabs.add_child(sv)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Symbol prefix…"
	_search_edit.tooltip_text = "Search symbol names · type a prefix; Enter steps through the hits · / or Ctrl+K"
	_search_edit.clear_button_enabled = true
	_search_edit.right_icon = Style.icon("search")
	_search_edit.text_changed.connect(func(_t): _search_timer.start())
	_search_edit.gui_input.connect(_on_search_key)
	sv.add_child(_search_edit)
	_search_info = Label.new()
	_search_info.theme_type_variation = "SmallLabel"
	_search_info.text = "Type in the filter to list its hits"
	sv.add_child(_search_info)
	_results = Tree.new()
	_results.hide_root = true
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.item_selected.connect(_on_result_selected)
	sv.add_child(_results)
	_more_btn = Button.new()
	_more_btn.text = "More results"
	_more_btn.visible = false
	_more_btn.pressed.connect(func():
		_search_page += 1
		_request_search(false))
	sv.add_child(_more_btn)

	# status zone
	var status_bar := PanelContainer.new()
	status_bar.theme_type_variation = "Bar"
	root.add_child(status_bar)
	var sb_clip := ScrollContainer.new()
	sb_clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sb_clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	status_bar.add_child(sb_clip)
	var sb := HBoxContainer.new()
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_clip.add_child(sb)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.tooltip_text = "server: disconnected"
	sb.add_child(_dot)
	_progress = Label.new()
	_progress.theme_type_variation = "SmallLabel"
	sb.add_child(_progress)
	sb.add_child(VSeparator.new())
	_status = Label.new()
	_status.theme_type_variation = "SmallLabel"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sb.add_child(_status)
	_hints = Label.new()
	_hints.theme_type_variation = "SmallLabel"
	sb.add_child(_hints)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.use_native_dialog = true
	_open_dialog.dir_selected.connect(func(d): client.request("open", {"path": d}))
	add_child(_open_dialog)

	_apply_theme()
	_on_connection(false)
	Style.theme_changed.connect(_apply_theme)
	Keymap.keymap_changed.connect(func(): _hints.text = Keymap.hints())
	_hints.text = Keymap.hints()


## Re-reads theme-dependent pieces that are not theme items: outer margin,
## icons, dot colors, inspector colors.
func _apply_theme() -> void:
	var gap := int(Style.num("shape", "gap", 10))
	for side in ["left", "top", "right", "bottom"]:
		_frame.add_theme_constant_override("margin_" + side, gap)
	_frame.get_child(0).add_theme_constant_override("separation", gap)
	for b in _icon_buttons:
		b.icon = Style.icon(b.get_meta("icon"))
	_search_edit.right_icon = Style.icon("search")
	_on_connection(client != null and _connected)
	_render_inspector()


func _icon_button(icon: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FlatButton"
	b.icon = Style.icon(icon)
	b.set_meta("icon", icon)
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	_icon_buttons.append(b)
	return b


func _segment(text: String, tip: String, group: ButtonGroup, cb: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "SegmentButton"
	b.text = Style.text(text)
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _open_folder() -> void:
	_open_dialog.popup_centered_ratio(0.6)


func _relation_toggle(text: String, tip: String) -> CheckButton:
	var b := CheckButton.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.toggled.connect(func(_on): _refresh_relations())
	return b


## Asks for the active relations of the selection; arcs update on reply.
func _refresh_relations() -> void:
	_rel = {}
	_rel_reqs = {}
	_push_arcs()
	if _selected_id < 0:
		return
	if _imports_btn.button_pressed:
		_rel_reqs[client.request("edges", {"node": _selected_id})] = "edges"
	if _calls_btn.button_pressed:
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
	_render_inspector()


func _small_label(t: String) -> Label:
	var l := Label.new()
	l.theme_type_variation = "SmallLabel"
	l.text = Style.text(t)
	return l


func _lens_picker(items: Array, tip: String) -> OptionButton:
	var o := OptionButton.new()
	o.tooltip_text = tip
	o.focus_mode = Control.FOCUS_NONE
	for i in items.size():
		o.add_item(items[i][1], i)
	o.item_selected.connect(func(_i): _send_view())
	return o


func _send_view() -> void:
	if _syncing_view:
		return
	var v := {
		"height": HEIGHTS[_height_opt.selected][0],
		"color": COLORS[_color_opt.selected][0],
		"importance": _importance.button_pressed,
	}
	client.request("options", {"view": v})
	_progress.text = "applying view…"


## Mirrors the server's view in the controls (no requests while syncing).
func _sync_view(info: Dictionary) -> void:
	_syncing_view = true
	var v: Dictionary = info.get("view", {})
	var git: bool = info.get("git", false)
	for i in HEIGHTS.size():
		_height_opt.set_item_disabled(i, HEIGHTS[i][2] and not git)
		if HEIGHTS[i][0] == v.get("height", "") or (v.get("height", "") == "" and i == 0):
			_height_opt.select(i)
	for i in COLORS.size():
		_color_opt.set_item_disabled(i, COLORS[i][2] and not git)
		if COLORS[i][0] == v.get("color", "") or (v.get("color", "") == "" and i == 0):
			_color_opt.select(i)
	_importance.button_pressed = v.get("importance", false)
	var c: String = v.get("color", "")
	_legend.text = "" if c == "" or c == "area" else "blue = low · red = high " + COLORS[_color_opt.selected][1].to_lower()
	_legend_box.visible = _legend.text != ""
	_syncing_view = false


func is_3d() -> bool:
	return city.visible


func set_view(three_d: bool) -> void:
	_v2d.set_pressed_no_signal(not three_d)
	_v3d.set_pressed_no_signal(three_d)
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


# ---------------------------------------------------------------- events

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
			_tabs.current_tab = 1
			_search_edit.grab_focus()
			_search_edit.select_all()
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
			if _settings.visible:
				_settings.hide()
			else:
				_clear_search()
		"settings":
			_settings.toggle()
		_:
			return false
	return true


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


var _go_parent := false


func _on_connection(ok: bool) -> void:
	var first := ok and not _connected
	_connected = ok
	if first:
		_send_server_settings()
	_dot.color = Style.color("good") if ok else Style.color("bad")
	_dot.tooltip_text = "server: " + ("connected" if ok else "disconnected — starting scrap serve…")
	if not ok:
		_progress.text = "connecting…"


func _on_hello(info: Dictionary) -> void:
	var regen: bool = _hello.has("gen") and int(_hello.gen) != int(info.gen)
	_hello = info
	_sync_view(info)
	if regen:
		_refresh_relations()  # geometry may have moved with the new view
	var s: Dictionary = info.stats
	var pass_name := "precise" if info.precise else "fast"
	_progress.text = "%s · %s files · %s lines · %s pass" % [info.name, _num(s.Files), _num(s.Lines), pass_name]
	get_window().title = "code-scrap — " + String(info.root)
	if _search_q != "":
		_request_search(true)  # results may have changed with the precise pass


func _on_progress(p: Dictionary) -> void:
	if p.pass == "git":
		if int(p.done) < int(p.total):
			_progress.text = "reading git history…"
		return
	if int(p.total) > 0 and int(p.done) < int(p.total):
		_progress.text = "%s %s %d%%" % [p.pass, p.phase, int(100.0 * p.done / p.total)]


func _on_hover(h: Dictionary) -> void:
	if int(h.get("node", -1)) < 0:
		_status.text = ""
		return
	var path: String = h.get("path", "")
	var dir := path.get_base_dir()
	var line := int(h.get("line", -1))
	var s := "%s (%s/)" % [h.name, dir] if dir != "" else String(h.name)
	if line >= 0:
		s += "  ·  line %d" % (line + 1)
	_status.text = s


func _on_selected(id: int) -> void:
	_selected_id = id
	if id < 0:
		_node_info = {}
		_inspector_hint()
	else:
		_node_req = client.request("node", {"node": id})
	_refresh_relations()


func _inspector_hint() -> void:
	_inspector.text = "[color=%s]Click a box on the map to inspect it.[/color]" % _hex("text3")


func _hex(token: String) -> String:
	return "#" + Style.color(token).to_html(false)


func _on_reply(id: int, data: Dictionary) -> void:
	match data.get("op"):
		"node":
			if id == _node_req:
				if _go_parent:
					_go_parent = false
					var parent := int(data.get("parent", -1))
					if parent >= 0:
						_node_req = client.request("node", {"node": parent})
						_fly_after_node = true
					return
				_show_node(data)
				if _fly_after_node:
					_fly_after_node = false
					map.select_node(int(data.node), data.rect)
					var t := map.fit_rect(data.rect)
					map.fly_to(t[0], t[1], t[2])
		"search":
			if id == _search_req:
				_show_search(data)
		"edges", "calls":
			if _rel_reqs.get(id, "") == data.op:
				_rel[data.op] = data
				_push_arcs()


var _fly_after_node := false


func _show_node(n: Dictionary) -> void:
	_node_info = n
	_render_inspector()


func _render_inspector() -> void:
	var n := _node_info
	if n.is_empty():
		return
	var dim := _hex("text3")
	var t := "[font_size=%d][b]%s[/b][/font_size] [color=%s]· %s[/color]\n" % [int(Style.num("font", "size_title", 15)), _esc(n.name), dim, n.kind]
	t += "[color=%s]%s[/color]\n" % [_hex("text2"), _esc(n.path)]
	if n.kind != "dir":
		t += "line %d\n" % int(n.line)
	t += "%s source lines · %s bytes\n" % [_num(n.lines), _num(n.bytes)]
	t += "%s children · %s descendants\n" % [_num(n.children), _num(n.descendants)]
	if n.has("lang"):
		t += "\n[color=%s]language[/color]  %s%s\n" % [dim, n.lang, "" if not n.get("precise", false) else "  (tree-sitter)"]
	if n.has("classes") and n.classes != null and n.classes.size() > 0:
		t += "[color=%s]class[/color]  %s\n" % [dim, ", ".join(n.classes)]
	if n.has("scope"):
		t += "[color=%s]scope[/color]  %s\n" % [dim, n.scope]
	t += "\n"
	if n.has("fileMetrics"):
		var fm: Dictionary = n.fileMetrics
		t += "[b]File metrics[/b]\n"
		t += "functions  %d\nmax complexity  %d\n" % [int(fm.functions), int(fm.maxComplexity)]
		if fm.has("commits"):
			var last := "—"
			if int(fm.lastChange) > 0:
				last = Time.get_date_string_from_unix_time(int(fm.lastChange))
			t += "commits  %d\nauthors  %d\nlast change  %s\n" % [int(fm.commits), int(fm.authors), last]
		t += "\n"
	if n.has("metrics"):
		var m: Dictionary = n.metrics
		t += "[b]Function metrics[/b]\n"
		t += "cyclomatic complexity  %d\nparameters  %d\nmax nesting  %d\nlength  %d lines\n" % [int(m.complexity), int(m.params), int(m.nesting), int(m.lines)]
	else:
		t += "[color=%s]No function metrics for this selection.[/color]\n" % dim
	if _rel.has("edges"):
		var r: Dictionary = _rel.edges
		t += "\n[b]Imports[/b]\n[color=%s]imports %d[/color] · [color=%s]imported by %d[/color]\n" % [_set_hex("relations.imports_out"), int(r.outTotal), _set_hex("relations.imports_in"), int(r.inTotal)]
	if _rel.has("calls"):
		var r: Dictionary = _rel.calls
		t += "\n[b]Calls[/b] [color=%s](syntax-level)[/color]\n[color=%s]calls %d[/color] · [color=%s]called by %d[/color]\n" % [dim, _set_hex("relations.calls_out"), int(r.outTotal), _set_hex("relations.calls_in"), int(r.inTotal)]
	_inspector.text = t
	_tabs.current_tab = 0 if _search_q == "" else _tabs.current_tab


# ---------------------------------------------------------------- search

func _run_search() -> void:
	_search_q = _search_edit.text.strip_edges()
	_search_page = 0
	if _search_q == "":
		_clear_search()
		return
	_request_search(true)


func _request_search(reset: bool) -> void:
	if reset:
		_search_page = 0
	_search_req = client.request("search", {"q": _search_q, "page": _search_page, "size": 64})


func _clear_search() -> void:
	_search_q = ""
	_search_hits = []
	_hit_index = -1
	_results.clear()
	_more_btn.visible = false
	_search_info.text = "Type in the filter to list its hits"
	map.clear_search()
	city.clear_search()


func _show_search(r: Dictionary) -> void:
	if r.q != _search_q:
		return
	if int(r.page) == 0:
		_results.clear()
		_search_hits = []
		_search_item_of = {}
		_hit_index = -1
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
			file_item.set_text(0, _short_path(h.path))
			file_item.set_tooltip_text(0, h.path)
			file_item.set_metadata(0, h.path)
			file_item.set_custom_color(0, Style.color("text2"))
			file_item.set_selectable(0, false)
			last_path = h.path
		var it := _results.create_item(file_item)
		it.set_text(0, "%5d   %s" % [int(h.line), h.name])
		it.set_tooltip_text(0, "%s · %s:%d" % [h.kind, h.path, int(h.line)])
		it.set_metadata(0, _search_hits.size())
		_search_item_of[_search_hits.size()] = it
		_search_hits.append(h)
	var shown := _search_hits.size()
	_search_info.text = "%s · %d%s hits · %d files · %.1f ms" % [_search_q, int(r.total), "+" if r.more else "", r.files.size(), r.ms]
	_more_btn.visible = shown < int(r.total)
	var lines := []
	for h in _search_hits:
		lines.append(h.rect)
	map.set_search_results(r.files, lines)
	city.set_search_results(r.files)
	_status.text = "search: %d rows%s in %.1f ms" % [int(r.total), " (more)" if r.more else "", r.ms]
	if _args.has("search") and _hit_index < 0 and shown > 0:
		_step_hit(1)


func _on_search_key(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null or not k.pressed:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		_step_hit(-1 if k.shift_pressed else 1)
		_search_edit.accept_event()
	elif k.keycode == KEY_ESCAPE:
		_search_edit.text = ""
		_clear_search()
		map.grab_focus()
		_search_edit.accept_event()


func _step_hit(d: int) -> void:
	if _search_hits.is_empty():
		return
	_hit_index = posmod(_hit_index + d, _search_hits.size())
	var it: TreeItem = _search_item_of.get(_hit_index)
	if it != null:
		_results.set_selected(it, 0)
		_results.scroll_to_item(it)
	else:
		_go_to_hit(_hit_index)


func _on_result_selected() -> void:
	var it := _results.get_selected()
	if it == null or it.get_metadata(0) is String:
		return
	_hit_index = int(it.get_metadata(0))
	_go_to_hit(_hit_index)


func _fly_to_search() -> bool:
	return Settings.get_value("camera.fly_to_search") and not _args.has("nofly")


func _go_to_hit(i: int) -> void:
	var h: Dictionary = _search_hits[i]
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
	if _args.has("focus"):
		_node_req = client.request("node", {"node": int(h.fileNode)})
		_fly_after_node = true
	else:
		map.focus_line(h.rect, 16.0)


# ---------------------------------------------------------------- helpers

func _set_hex(id: String) -> String:
	return "#" + (Settings.get_value(id) as Color).to_html(false)


func _short_path(p: String) -> String:
	return p if p.length() <= 52 else "…" + p.right(51)


func _esc(s) -> String:
	return String(s).replace("[", "[lb]")


func _num(v) -> String:
	var s := str(int(v))
	var out := ""
	var n := s.length()
	for i in n:
		out += s[i]
		var left := n - 1 - i
		if left > 0 and left % 3 == 0:
			out += " "
	return out


# ---------------------------------------------------------------- automation

## --lens=height:churn,color:complexity,importance  (waits for git history)
func _apply_lens_when_ready(spec: String) -> void:
	for i in 100:
		if _hello.get("git", false):
			break
		await get_tree().create_timer(0.1).timeout
	for part in spec.split(","):
		var kv := part.split(":")
		if kv[0] == "importance":
			_syncing_view = true
			_importance.button_pressed = true
			_syncing_view = false
		for i in HEIGHTS.size():
			if kv[0] == "height" and HEIGHTS[i][0] == kv[1]:
				_height_opt.select(i)
		for i in COLORS.size():
			if kv[0] == "color" and COLORS[i][0] == kv[1]:
				_color_opt.select(i)
	_send_view()


func _enter_3d_when_ready() -> void:
	await get_tree().create_timer(0.8).timeout  # let the 2D camera settle
	set_view(true)
	if _args.has("yaw"):
		city.yaw = float(_args.yaw)
		city._tween.from.yaw = city.yaw
		city._tween.to.yaw = city.yaw
	if _args.has("pitch"):
		city._tween.to.pitch = float(_args.pitch)
	if _args.has("dist"):
		city._tween.to.dist = city.dist * float(_args.dist)
	if _args.has("home"):
		await get_tree().create_timer(1.0).timeout
		city.home()
	if _args.has("wheel"):
		# simulate zooming in at the view center, one notch at a time
		await get_tree().create_timer(1.2).timeout
		var c := city.size * 0.5
		for i in int(_args.wheel):
			var mm := InputEventMouseMotion.new()
			mm.position = c
			city._gui_input(mm)
			await get_tree().create_timer(0.15).timeout
			var wb := InputEventMouseButton.new()
			wb.button_index = MOUSE_BUTTON_WHEEL_UP
			wb.pressed = true
			wb.position = c
			city._gui_input(wb)
			await get_tree().create_timer(0.1).timeout

func _automate() -> void:
	var wait := float(_args.get("wait", "4"))
	if _args.has("search"):
		client.hello.connect(func(_i):
			if _search_q == "":
				_tabs.current_tab = 1
				_search_edit.text = _args.search
				_run_search(), CONNECT_ONE_SHOT)
	if _args.get("view", "") == "3d":
		client.hello.connect(func(_i): _enter_3d_when_ready(), CONNECT_ONE_SHOT)
	if _args.has("lens"):
		_apply_lens_when_ready(_args.lens)
	if _args.has("settings"):
		_settings.show()
	if _args.has("rel"):
		_imports_btn.button_pressed = "imports" in _args.rel
		_calls_btn.button_pressed = "calls" in _args.rel
	await get_tree().create_timer(wait).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_args.shot)
	print("saved ", _args.shot)
	get_tree().quit()
