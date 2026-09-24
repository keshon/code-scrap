class_name TestDriver
extends Node
## Scripted runs for screenshots and checks, driven by command-line flags
## (after `--`). Active only with --shot.
##
##   --shot=<png>      save a screenshot after --wait seconds, then quit
##   --wait=<sec>      (default 4)
##   --search=<q>      run a search once connected and go to the first symbol hit
##   --type=<q>        type into the search field and leave the dropdown open
##   --focus=1         fly to the first search hit's file instead of the line
##   --nofly           select search hits without flying to them
##   --view=3d         switch to the 3D city once connected (--yaw, --pitch, --dist, --home, --wheel=N)
##   --lens=height:churn,color:complexity,importance   apply lenses once git is loaded
##   --rel=imports,calls   turn relation arcs on (use with --search to select)
##   --settings=1      open the settings panel
##   --tab=view        show the right pane's View tab
##   --hud=1           show the diagnostics overlay
##   --theme=<id>      use this theme for the run (nothing is saved)
##   --set=id:value,…  override settings for the run (nothing is saved)
##   --select=<path>   select a file or folder by path once connected (and fly to it)
##   --crumb=<n>       then open the n-th breadcrumb chevron menu
##   --hover=fx,fy     2D: point the cursor at this fraction of the map view
##                     (after --wait/2) and pick what is under it
##   --later=id:value  change a setting after --wait/2 (rebuilds the layout)
##   --arc=<i>         follow the i-th drawn arc after --wait/2 (and again at
##                     --wait*0.8 with --arcback=1, which should come back)

var shell: Node   # main.gd
var args := {}


func _init(s: Node, a: Dictionary) -> void:
	shell = s
	args = a
	Settings.persist = false  # scripted runs never touch the user's settings


func _ready() -> void:
	var client: ScrapClient = shell.client
	if args.has("theme"):
		Settings.set_value("ui.theme", args.theme)
	if args.has("set"):
		for kv in String(args.set).split(","):
			var id := kv.get_slice(":", 0)
			var raw := kv.substr(id.length() + 1)
			var def: Dictionary = Settings.defs.get(id, {})
			match def.get("type", ""):
				"bool":
					Settings.set_value(id, raw == "true" or raw == "1")
				"int", "float":
					Settings.set_value(id, float(raw))
				"color":
					Settings.set_value(id, Color.html(raw))
				_:
					Settings.set_value(id, raw)
	if args.has("search"):
		shell.search.auto_step_first = true
		client.hello.connect(func(_i):
			if shell.search.query == "":
				shell.search.search(args.search), CONNECT_ONE_SHOT)
	if args.has("type"):
		# type into the search field and leave the dropdown open
		client.hello.connect(func(_i):
			shell.search.focus()
			shell.search.search(args.type), CONNECT_ONE_SHOT)
	if args.has("select"):
		# a moment after connecting, so --set options that re-lay the map
		# out (and send a new hello) are in place first
		client.hello.connect(func(_i):
			await get_tree().create_timer(2.0).timeout
			shell._pending = {"select": true, "fly": true}
			shell._node_req = client.request("node", {"path": args.select}), CONNECT_ONE_SHOT)
	if args.get("view", "") == "3d":
		client.hello.connect(func(_i): _enter_3d(), CONNECT_ONE_SHOT)
	if args.has("arc"):
		var wait := float(args.get("wait", 4))
		get_tree().create_timer(wait * 0.5).timeout.connect(func():
			var m = shell.map
			print("arc follow: camera ", m.cx, " ", m.cy, " zoom ", m.zoom, " arcs ", m._arc_lines.size())
			if int(args.arc) < m._arc_lines.size():
				m.follow_arc(int(args.arc)))
		if args.has("arcback"):
			get_tree().create_timer(wait * 0.8).timeout.connect(func():
				var m = shell.map
				print("arc back:   camera ", m.cx, " ", m.cy, " zoom ", m.zoom)
				if int(args.arc) < m._arc_lines.size():
					m.follow_arc(int(args.arc)))
	if args.has("later"):
		var kv := String(args.later)
		var sid := kv.get_slice(":", 0)
		var raw := kv.substr(sid.length() + 1)
		get_tree().create_timer(float(args.get("wait", 4)) * 0.5).timeout.connect(
			func(): _apply_setting(sid, raw))
	if args.has("hover"):
		var f := String(args.hover).split(",")
		get_tree().create_timer(float(args.get("wait", 4)) * 0.5).timeout.connect(func():
			var map = shell.map
			map._last_mouse = Vector2(float(f[0]), float(f[1])) * map.size
			map._send_pick())
	if args.has("lens"):
		_apply_lens(args.lens)
	if args.has("rel"):
		Settings.set_value("relations.imports", "imports" in args.rel)
		Settings.set_value("relations.calls", "calls" in args.rel)
	if args.get("tab", "") == "view":
		get_tree().create_timer(0.5).timeout.connect(func(): shell._tabs.current_tab = 1)
	if args.has("settings"):
		shell.settings_panel.show()
	if args.has("hud"):
		shell.hud.visible = true
	if args.has("crumb"):
		get_tree().create_timer(float(args.get("wait", "4")) - 2.0).timeout.connect(func():
			var chevs: Array = shell.header._crumbs.get_children().filter(func(c): return c is Button and c.text == "")
			if chevs.size() > int(args.crumb):
				chevs[int(args.crumb)].pressed.emit())
	await get_tree().create_timer(float(args.get("wait", "4"))).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(args.shot)
	print("saved ", args.shot)
	get_tree().quit()


## Waits for git history (up to 10 s) so git lenses are available.
func _apply_lens(spec: String) -> void:
	for i in 100:
		if shell.hello_info.get("git", false):
			break
		await get_tree().create_timer(0.1).timeout
	shell.view_panel.apply_lens_spec(spec)


func _enter_3d() -> void:
	var city: CityView = shell.city
	await get_tree().create_timer(0.8).timeout  # let the 2D camera settle
	shell.set_view(true)
	if args.has("yaw"):
		city.yaw = float(args.yaw)
		city._tween.from.yaw = city.yaw
		city._tween.to.yaw = city.yaw
	if args.has("pitch"):
		city._tween.to.pitch = float(args.pitch)
	if args.has("dist"):
		city._tween.to.dist = city.dist * float(args.dist)
	if args.has("home"):
		await get_tree().create_timer(1.0).timeout
		city.home()
	if args.has("wheel"):
		# zoom in at the view center, one notch at a time
		await get_tree().create_timer(1.2).timeout
		var c := city.size * 0.5
		for i in int(args.wheel):
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


## One "--set"-style assignment, typed by the settings schema.
func _apply_setting(id: String, raw: String) -> void:
	var def: Dictionary = Settings.defs.get(id, {})
	match def.get("type", ""):
		"bool":
			Settings.set_value(id, raw == "true" or raw == "1")
		"int", "float":
			Settings.set_value(id, float(raw))
		"color":
			Settings.set_value(id, Color.html(raw))
		_:
			Settings.set_value(id, raw)
