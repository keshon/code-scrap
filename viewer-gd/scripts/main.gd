extends Control
## App shell: lays out the zones and wires them to the views and the server.
##
##   top bar      app · Explorer toggle · repository · 2D|3D · preset ·
##                search (dropdown: files, folders, symbols, > commands) · settings
##   left         Explorer: the file tree (optional)
##   viewport     islands: breadcrumb · camera · display ☰; map/city; legend; HUD
##   right        tabs: Inspector (with relations) · View (lenses, relations)
##   status bar   server · progress · hover · keymap hints · fps
##
## Every control has one home: display toggles in ☰, viewing modes in View,
## camera commands in Camera, tunables in Settings (docs/PLAN.md, UI map).
##
## The pieces live in scripts/ui/; scripted runs live in TestDriver.
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

# commands offered by the search field's ">" mode: [id, label, keys]
const COMMANDS := [
	["frame_all", "Frame all", "A"], ["frame_selected", "Frame selection", "F"],
	["deselect", "Deselect", "Q"], ["select_parent", "Select parent", "Backspace"],
	["toggle_view", "Switch 2D / 3D", "Tab"], ["toggle_imports", "Toggle import arcs", ""],
	["toggle_calls", "Toggle call arcs", ""], ["toggle_explorer", "Toggle Explorer", ""],
	["toggle_hud", "Toggle diagnostics overlay", "F12"], ["open_folder", "Open folder…", ""],
	["settings", "Settings", "Ctrl+,"], ["theme:calm", "Theme: Calm", ""], ["theme:fui", "Theme: FUI", ""],
	["keymap:maya", "Keymap: Maya", ""], ["keymap:classic", "Keymap: Classic", ""],
	["clear", "Clear search", "Esc"],
	["relation_next", "Next relation", "]"], ["relation_prev", "Previous relation", "["],
	["bookmark_1", "Go to bookmark 1", "1"], ["bookmark_save_1", "Save bookmark 1", "Ctrl+1"],
	["toggle_minimap", "Toggle minimap", ""], ["toggle_line_numbers", "Toggle line numbers", ""],
	["nav_back", "Back", "Alt+Left"], ["nav_forward", "Forward", "Alt+Right"],
]

var client: ScrapClient
var map: MapView
var city: CityView
var toolbar: Toolbar
var view_panel: ViewPanel
var explorer: Explorer
var header: ViewportHeader
var legend: Legend
var status: StatusBar
var inspector: Inspector
var search: SearchPopup
var settings_panel: SettingsPanel
var hud: Hud
var minimap: Minimap
var hello_info := {}
var args := {}

var _frame: MarginContainer
var _tabs: TabContainer
var _open_dialog: FileDialog
var _connected := false
var _selected_id := -1
var _shown_node := -1        # node the inspector shows
var _rel_reqs := {}          # request id -> op
var _rel := {}               # op -> reply
var _node_req := -1
var _pending := {}           # what to do with the next node reply: {parent, select, fly}
var _last_root := ""
var _tree_sig := ""          # root + index pass: when it changes, node ids did
var _selected_path := ""     # survives generations (ids do not)
var _rel_anchor := -1        # whose relations are listed
var _stepping := false       # selecting a relation target: keep the anchor's relations
var _bookmark_2d := {}       # camera to apply once the 3D view has tilted back
var _back: Array[Dictionary] = []   # places we came from, newest last
var _fwd: Array[Dictionary] = []    # places "back" came from
var _travelling := false            # inside a back/forward jump: record nothing


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
	map.jumped.connect(nav_push)
	city.hovered.connect(_on_hover)
	city.selected.connect(_on_selected)
	city.jumped.connect(nav_push)
	city.exited.connect(_on_city_exited)
	client.hello.connect(_on_hello)
	client.progress.connect(_on_progress)
	client.reply.connect(_on_reply)
	client.connection_changed.connect(_on_connection)
	Settings.changed.connect(_on_setting_changed)
	Settings.reloaded.connect(func():
		_send_server_settings()
		_apply_layout()
		_refresh_relations())
	Style.theme_changed.connect(_apply_theme)
	_apply_theme()
	_apply_layout()
	view_panel.set_3d(false)

	if args.has("shot"):
		add_child(TestDriver.new(self, args))


func _build_ui() -> void:
	_frame = MarginContainer.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	var root := VBoxContainer.new()
	_frame.add_child(root)

	# top bar
	toolbar = Toolbar.new()
	root.add_child(toolbar)
	toolbar.action.connect(_do_action)
	toolbar.open_folder.connect(func(): _do_action("open_folder"))
	toolbar.open_path.connect(func(p): client.request("open", {"path": p}))
	toolbar.view_selected.connect(set_view)

	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# left: explorer
	explorer = Explorer.new(client)
	body.add_child(explorer)
	explorer.node_chosen.connect(func(id): select_and_frame(id, true))

	var center := HSplitContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(center)

	# viewport
	# the viewport: a rounded frame that clips the map and its overlays to
	# its corners, like the other zones
	var views := Panel.new()
	views.theme_type_variation = "ViewportFrame"
	views.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	views.clip_contents = true
	center.add_child(views)
	map = MapView.new()
	map.set_anchors_preset(Control.PRESET_FULL_RECT)
	views.add_child(map)
	city = CityView.new()
	city.set_anchors_preset(Control.PRESET_FULL_RECT)
	city.visible = false
	views.add_child(city)

	# viewport overlays; the map's tile levels use z up to 1000
	header = ViewportHeader.new(client)
	header.resized.connect(_sync_top_inset)
	header.z_index = 2000
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = 10
	header.offset_right = -10
	header.offset_top = 10
	views.add_child(header)
	header.crumb_clicked.connect(func(id): select_and_frame(id, true))
	header.action.connect(_do_action)
	legend = Legend.new()
	legend.z_index = 2000
	legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	legend.grow_vertical = Control.GROW_DIRECTION_BEGIN
	legend.offset_right = -10
	legend.offset_bottom = -10
	views.add_child(legend)
	legend.area_clicked.connect(func(id): select_and_frame(id, true))
	hud = Hud.new(map, city)
	hud.z_index = 2000
	hud.position = Vector2(10, 64)
	views.add_child(hud)
	minimap = Minimap.new(client, map, city)
	minimap.z_index = 2000
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	minimap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	minimap.offset_left = 10
	minimap.offset_bottom = -10
	views.add_child(minimap)
	minimap.jump.connect(_jump_to)
	settings_panel = SettingsPanel.new()
	settings_panel.visible = false
	settings_panel.z_index = 2001
	settings_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	settings_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	views.add_child(settings_panel)

	# right: inspector + view
	var side := PanelContainer.new()
	side.theme_type_variation = "Side"
	side.custom_minimum_size = Vector2(320, 0)
	center.add_child(side)
	_tabs = TabContainer.new()
	side.add_child(_tabs)
	inspector = Inspector.new()
	_tabs.add_child(inspector)
	inspector.node_clicked.connect(func(id): select_and_frame(id, true))
	view_panel = ViewPanel.new()
	_tabs.add_child(view_panel)
	view_panel.lens_changed.connect(func(v):
		client.request("options", {"view": v})
		status.set_progress("applying view…"))

	# the search dropdown floats over everything, under the top bar field
	search = SearchPopup.new(client)
	search.z_index = 3000
	add_child(search)
	search.bind_field(toolbar.search_field)
	for c in COMMANDS:
		search.commands.append({"id": c[0], "label": c[1], "keys": c[2]})
	search.hit_chosen.connect(_go_to_hit)
	search.path_chosen.connect(select_and_frame)
	search.command_chosen.connect(_do_action)
	search.results_changed.connect(func(files, lines):
		map.set_search_results(files, lines)
		city.set_search_results(files)
		legend.set_search(true))
	search.cleared.connect(func():
		map.clear_search()
		city.clear_search()
		legend.set_search(false))
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


## Zone visibility from settings.
## The header floats over the map, so framing has to keep clear of it.
func _sync_top_inset() -> void:
	map.top_inset = (header.size.y + 10.0) if header.visible else 0.0


func _apply_layout() -> void:
	explorer.visible = Settings.get_value("ui.explorer")
	header.visible = Settings.get_value("viewport.header")
	_sync_top_inset()


# ---------------------------------------------------------------- views

func is_3d() -> bool:
	return city.visible


func set_view(three_d: bool) -> void:
	toolbar.set_3d(three_d)
	view_panel.set_3d(three_d)
	legend.set_3d(three_d)
	if three_d == is_3d():
		return
	if three_d:
		city.hit_files = map.hit_files
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
	if not _bookmark_2d.is_empty():
		map.fly_to(_bookmark_2d.cx, _bookmark_2d.cy, _bookmark_2d.zoom)
		_bookmark_2d = {}


## Minimap click/drag: centre the active view on a world point.
func _jump_to(x: float, y: float) -> void:
	if is_3d():
		city.tx = x
		city.ty = y
		city._goal = {}
		city._tween = {}
		city._dirty = true
	else:
		map._fly = {}
		map.cx = x
		map.cy = y
		map._zoom_target = map.zoom
		map._dirty = true


# ---------------------------------------------------------------- bookmarks

## Ctrl+1..9: remember the view, the camera and the selection for this repo.
func _save_bookmark(n: int) -> void:
	var root := String(hello_info.get("root", ""))
	if root == "":
		return
	var cam: Dictionary = city.camera_state() if is_3d() else map.camera_state()
	Settings.set_bookmark(root, n, {"view": "3d" if is_3d() else "2d", "cam": cam, "path": _selected_path})
	status.set_status("Bookmark %d saved · press %d to come back" % [n, n])


## 1..9: fly back to a bookmark (false when there is none).
func _go_bookmark(n: int) -> bool:
	var b: Dictionary = Settings.bookmarks(String(hello_info.get("root", ""))).get(str(n), {})
	if b.is_empty():
		status.set_status("No bookmark %d · Ctrl+%d saves one" % [n, n])
		return true
	nav_push()
	_nav_apply(b)
	status.set_status("Bookmark %d" % n)
	return true


# ------------------------------------------------------------------ history

const HISTORY_MAX := 64

## Remembers where we stand, before a jump takes us elsewhere. Like a
## browser: going somewhere new forgets the way forward.
func nav_push() -> void:
	if _travelling:
		return
	var here := _nav_state()
	if not _back.is_empty() and _same_place(_back[-1], here):
		return
	_back.append(here)
	if _back.size() > HISTORY_MAX:
		_back.pop_front()
	_fwd.clear()


## Back (or forward) one step: the mouse's own back/forward buttons, or
## Alt+Left / Alt+Right.
func nav_go(forward: bool) -> bool:
	var from := _fwd if forward else _back
	var to := _back if forward else _fwd
	if from.is_empty():
		status.set_status("Nothing to go " + ("forward to" if forward else "back to"))
		return true
	to.append(_nav_state())
	var there: Dictionary = from.pop_back()
	_travelling = true
	_nav_apply(there)
	_travelling = false
	var where := String(there.get("path", "")).get_file()
	status.set_status(("Forward" if forward else "Back") + ("" if where == "" else " · " + where))
	return true


## The view, the camera and the selection: enough to come back.
func _nav_state() -> Dictionary:
	return {"view": "3d" if is_3d() else "2d",
		"cam": city.camera_state() if is_3d() else map.camera_state(),
		"path": _selected_path}


## Flies to a remembered place. Bookmarks travel the same way.
func _nav_apply(s: Dictionary) -> void:
	var cam: Dictionary = s.get("cam", {})
	if s.get("view", "2d") == "3d":
		if not is_3d():
			set_view(true)
		city.fly_to_state(cam)
	elif is_3d():
		_bookmark_2d = cam
		set_view(false)
	else:
		map.fly_to(cam.cx, cam.cy, cam.zoom)
	if String(s.get("path", "")) != "":
		_pending = {"select": true, "fly": false}
		_node_req = client.request("node", {"path": s.path})


## Two places are the same when the camera and the selection are: pressing
## the same key twice should not fill the history with copies.
static func _same_place(a: Dictionary, b: Dictionary) -> bool:
	if a.get("view", "") != b.get("view", "") or a.get("path", "") != b.get("path", ""):
		return false
	var ca: Dictionary = a.get("cam", {})
	var cb: Dictionary = b.get("cam", {})
	for k in ca:
		if absf(float(ca[k]) - float(cb.get(k, 0.0))) > 1e-4:
			return false
	return true


## Selects a node by id in the active view (and mirrors it into the other),
## optionally flying there. Used by breadcrumbs, legend, relation lists and
## search file rows.
func select_and_frame(id: int, fly: bool) -> void:
	if id < 0:
		return
	if fly:
		nav_push()
	_pending = {"select": true, "fly": fly and not args.has("nofly")}
	_node_req = client.request("node", {"node": id})


# ---------------------------------------------------------------- actions

## The two extra mouse buttons are named back and forward by the hardware,
## so they are wired to exactly that and not left to the keymap.
func _unhandled_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_XBUTTON1 or mb.button_index == MOUSE_BUTTON_XBUTTON2:
		nav_go(mb.button_index == MOUSE_BUTTON_XBUTTON2)
		get_viewport().set_input_as_handled()


func _unhandled_key_input(ev: InputEvent) -> void:
	var k := ev as InputEventKey
	if k == null:
		return
	var action := Keymap.key_action(k)
	if action != "" and _do_action(action):
		get_viewport().set_input_as_handled()


## Runs a keymap action or command; false when it does not apply here.
func _do_action(action: String) -> bool:
	if action.begins_with("theme:"):
		Settings.set_value("ui.theme", action.substr(6))
		return true
	if action.begins_with("keymap:"):
		Settings.set_value("ui.keymap", action.substr(7))
		return true
	if action.begins_with("bookmark_save_"):
		_save_bookmark(int(action.substr(14)))
		return true
	if action.begins_with("bookmark_"):
		return _go_bookmark(int(action.substr(9)))
	match action:
		"search":
			search.focus()
		"frame_all":
			nav_push()
			if is_3d():
				city.home()
			else:
				map.home()
		"frame_selected":
			nav_push()
			if is_3d():
				city.frame_selected()
			else:
				map.frame_selected()
		"nav_back", "nav_forward":
			return nav_go(action == "nav_forward")
		"deselect":
			map.deselect()
			city.deselect()
		"toggle_view":
			set_view(not is_3d())
		"select_parent":
			if _selected_id >= 0:
				_pending = {"parent": true}
				_node_req = client.request("node", {"node": _selected_id})
		"clear":
			if settings_panel.visible:
				settings_panel.hide()
			else:
				toolbar.search_field.text = ""
				toolbar.search_field.text = ""
				search.clear()
		"settings":
			settings_panel.toggle()
		"toggle_hud":
			Settings.set_value("debug.hud", not Settings.get_value("debug.hud"))
		"toggle_imports", "toggle_calls":
			var id := "relations." + action.substr(7)
			Settings.set_value(id, not Settings.get_value(id))
		"relation_next", "relation_prev":
			var id := inspector.step(1 if action == "relation_next" else -1)
			if id < 0:
				return false
			_stepping = true
			select_and_frame(id, true)
		"toggle_minimap":
			Settings.set_value("viewport.minimap", not Settings.get_value("viewport.minimap"))
		"toggle_line_numbers":
			Settings.set_value("text.line_numbers", not Settings.get_value("text.line_numbers"))
		"toggle_explorer":
			Settings.set_value("ui.explorer", not Settings.get_value("ui.explorer"))
		"open_folder":
			_open_dialog.popup_centered_ratio(0.6)
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
	client.request("options", {"weights": weights, "rules": Settings.get_value("importance.rules"),
		"keepChains": Settings.get_value("layout.keep_chains"),
		"gitSince": Settings.get_value("git.since"),
		"look": {"order": Settings.get_value("layout.order"), "dirsFirst": Settings.get_value("layout.dirs_first"),
			"algorithm": Settings.get_value("layout.algorithm"),
			"palette": Settings.get_value("look.palette"), "lineNumbers": Settings.get_value("text.line_numbers"),
			"headers": Settings.get_value("look.headers"),
			"evenSteps": Settings.get_value("look.even_steps") == "even",
			"cardDepth": int(Settings.get_value("layout.cards_depth")),
			"mergeHeaders": Settings.get_value("look.merge_bands"),
			"bandSize": Settings.get_value("look.band_size")}})


func _on_setting_changed(id: String, _v: Variant) -> void:
	if id == "relations.imports" or id == "relations.calls":
		_refresh_relations()
	elif id.begins_with("relations."):
		_push_arcs()
	elif id == "ui.explorer" or id == "viewport.header":
		_apply_layout()
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
	view_panel.sync(info)
	legend.set_view(info.get("legend", {}), view_panel.color_lens(), view_panel.height_lens())
	toolbar.set_repo(info.name, info.root)
	header.set_repo(info.name)
	if info.root != _last_root:
		_last_root = info.root
		Settings.add_recent(info.root)
	var s: Dictionary = info.stats
	var sig := "%s|%s|%d|%d" % [info.root, info.precise, int(s.Files), int(s.Scopes)]
	if sig != _tree_sig:
		# a new tree (folder opened, precise pass): node ids changed
		_tree_sig = sig
		explorer.reload()
		if _selected_path != "":
			_pending = {"select": true, "fly": false, "follow": _follow_selection()}
			_node_req = client.request("node", {"path": _selected_path})
		elif _selected_id >= 0:
			map.deselect()
			city.deselect()
	elif regen:
		_refresh_relations()  # geometry may have moved with the new view
		if _selected_id >= 0:
			# a new layout moves the boxes: keep the selection in view when
			# it was in view before (lens, importance, headers, order…)
			_pending = {"follow": _follow_selection()}
			_node_req = client.request("node", {"node": _selected_id})  # fresh rect for the highlight
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


## A view selected something (click, search) or cleared its selection.
func _on_selected(id: int) -> void:
	var changed := id != _selected_id
	_selected_id = id
	if id < 0:
		_shown_node = -1
		inspector.clear_node()
		header.set_path("", -1, [])
		_selected_path = ""
		map.deselect()   # both return early when already clear
		city.deselect()
	elif id != _shown_node:
		_node_req = client.request("node", {"node": id})
	if _stepping:
		# stepping through a relation list: the list stays the anchor's
		_stepping = false
		return
	if changed:
		_refresh_relations()


func _on_reply(id: int, data: Dictionary) -> void:
	match data.get("op"):
		"node":
			if id == _node_req:
				_on_node(data)
		"error":
			status.set_status("Server: " + String(data.get("error", "")))
		"edges", "calls":
			if _rel_reqs.get(id, "") == data.op:
				_rel[data.op] = data
				_push_arcs()


## True when the selection is on screen in the flat map, so a rebuild that
## moves it should bring the view along.
func _follow_selection() -> bool:
	return not is_3d() and map.selection_on_screen()


func _on_node(data: Dictionary) -> void:
	var p := _pending
	_pending = {}
	if p.get("parent", false):
		select_and_frame(int(data.get("parent", -1)), true)
		return
	var nid := int(data.get("node", -1))
	if nid < 0:
		return
	var kind := "scope" if data.kind == "scope" else "file"
	if p.get("select", false):
		_shown_node = nid  # the select below re-emits selected: no second request
		if is_3d():
			city.select(nid, data.rect, float(data.top), kind, float(data.get("base", 0.0)))
			if p.fly:
				city.focus_rect(data.rect, float(data.top))
		else:
			map.select_node(nid, data.rect, data.get("header", []))
			if p.fly:
				var t := map.fit_rect(data.rect)
				map.fly_to(t[0], t[1], t[2])
	_shown_node = nid
	# mirror the selection into the other view
	map.set_selection(nid, data.rect, data.get("header", []))
	city.set_selection(data.rect, float(data.top), kind, float(data.get("base", 0.0)))
	if p.get("follow", false) and not is_3d() and not map.selection_on_screen():
		var f := map.fit_rect(data.rect)
		map.fly_to(f[0], f[1], f[2])
	inspector.show_node(data)
	var anc: Array = data.get("ancestors", [])
	header.set_path(String(data.name), nid, anc)
	explorer.reveal(anc.map(func(a): return int(a[0])) + [nid])
	_selected_path = String(data.path)  # a scope's path is its file's



# ---------------------------------------------------------------- relations

## Asks for the active relations of the selection; arcs update on reply.
func _refresh_relations() -> void:
	_rel = {}
	_rel_reqs = {}
	_push_arcs()
	var imports: bool = Settings.get_value("relations.imports")
	var calls: bool = Settings.get_value("relations.calls")
	legend.set_relations(imports and _selected_id >= 0, calls and _selected_id >= 0)
	_rel_anchor = _selected_id
	if _selected_id < 0:
		return
	if imports:
		_rel_reqs[client.request("edges", {"node": _selected_id})] = "edges"
	if calls:
		_rel_reqs[client.request("calls", {"node": _selected_id})] = "calls"


## An arc end for tooltips: the name, with the line it is anchored to.
func _end_name(names: Dictionary, node: int, line: int) -> String:
	var name := String(names.get(str(node), "?")).get_file()
	return name if line < 0 else "%s:%d" % [name, line + 1]


func _push_arcs() -> void:
	var list := []
	var direction: String = Settings.get_value("relations.direction")
	var most: int = Settings.get_value("relations.max")
	for op in _rel:
		var r: Dictionary = _rel[op]
		var nodes: Dictionary = r.nodes
		for dir in [0, 1]:
			var key := "out" if dir == 0 else "in"
			if direction != "both" and direction != key:
				continue
			var by_dir: bool = Settings.get_value("relations.style") == "direction"
			var col: Color = Settings.get_value("relations.dir_out" if dir == 0 else "relations.dir_in") 				if by_dir else Settings.get_value(REL_COLORS[op][dir])
			var lines: Dictionary = r.get("lines", {})
			var names: Dictionary = r.get("names", {})
			for e in r[key].slice(0, most):
				# aim at the import statement / the call and at the
				# declaration it lands on, not at the middle of the box
				var a: Array = lines.get("%d#%d" % [int(e[0]), int(e[2])], nodes[str(int(e[0]))])
				var b: Array = lines.get("%d#%d" % [int(e[1]), int(e[3])], nodes[str(int(e[1]))])
				list.append({"a": a, "b": b, "box_a": nodes[str(int(e[0]))], "box_b": nodes[str(int(e[1]))],
					"an": _end_name(names, int(e[0]), int(e[2])), "bn": _end_name(names, int(e[1]), int(e[3])),
					"kind": "imports" if op == "edges" else "calls",
					# in direction mode the kind is the line's style, not its colour
					"dashed": by_dir and op == "edges", "color": col})
	map.set_arcs(list)
	city.set_arcs(list)
	var anchor := ""
	if _rel_anchor >= 0 and _rel_anchor != _selected_id:
		for op in _rel:
			anchor = String(_rel[op].get("names", {}).get(str(_rel_anchor), ""))
	inspector.set_relations(_rel, anchor)


# ---------------------------------------------------------------- search hits

func _go_to_hit(h: Dictionary, fly: bool) -> void:
	fly = fly and not args.has("nofly")
	if fly:
		nav_push()
	if is_3d():
		city.current_hit = {"rect": h.rect, "top": float(h.top)}
		city.select(int(h.node), h.rect, float(h.top), "scope" if h.kind != "block" else "file")
		if fly:
			city.focus_line(h.rect, float(h.top), 16.0)
		return
	map.current_hit = h.rect
	map.select_node(int(h.node), h.rect)
	if not fly:
		return
	if args.has("focus"):
		select_and_frame(int(h.fileNode), true)
	else:
		map.focus_line(h.rect, 16.0)
