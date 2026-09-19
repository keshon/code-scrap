class_name TestDriver
extends Node
## Scripted runs for screenshots and checks, driven by command-line flags
## (after `--`). Active only with --shot.
##
##   --shot=<png>      save a screenshot after --wait seconds, then quit
##   --wait=<sec>      (default 4)
##   --search=<q>      run a search once connected and step to the first hit
##   --focus=1         fly to the first search hit's file instead of the line
##   --nofly           select search hits without flying to them
##   --view=3d         switch to the 3D city once connected (--yaw, --pitch, --dist, --home, --wheel=N)
##   --lens=height:churn,color:complexity,importance   apply lenses once git is loaded
##   --rel=imports,calls   turn relation arcs on (use with --search to select)
##   --settings=1      open the settings panel
##   --hud=1           show the diagnostics overlay

var shell: Node   # main.gd
var args := {}


func _init(s: Node, a: Dictionary) -> void:
	shell = s
	args = a


func _ready() -> void:
	var client: ScrapClient = shell.client
	if args.has("search"):
		shell.search.auto_step_first = true
		client.hello.connect(func(_i):
			if shell.search.query == "":
				shell.show_search_tab()
				shell.search.search(args.search), CONNECT_ONE_SHOT)
	if args.get("view", "") == "3d":
		client.hello.connect(func(_i): _enter_3d(), CONNECT_ONE_SHOT)
	if args.has("lens"):
		_apply_lens(args.lens)
	if args.has("rel"):
		shell.toolbar.imports.button_pressed = "imports" in args.rel
		shell.toolbar.calls.button_pressed = "calls" in args.rel
	if args.has("settings"):
		shell.settings_panel.show()
	if args.has("hud"):
		shell.hud.visible = true
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
	shell.toolbar.apply_lens_spec(spec)


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
