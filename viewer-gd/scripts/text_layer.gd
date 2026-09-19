class_name TextLayer
extends RefCounted
## Streams GPU text blocks (one column of a file's text, ≤4096 lines) for a
## view. The view lists candidate blocks each frame and says how to create
## and place their nodes; this class picks which to show, requests, caches,
## fades and evicts them.
##
## Blocks are keyed by content (the server's TextKey: path + layout + place),
## not by node id, so text survives a new map generation (precise pass, git
## history, lens change) whenever its content did not change.

const MAX_CACHED := 700
const FADE_S := 0.15       # fade in / out time
const KEEP_BONUS := 1.5    # shown blocks win ties at the budget cutoff

var client: ScrapClient
var parent: Node
var make_node: Callable  # (material: ShaderMaterial) -> Node
var shader: Shader
var gen := -1

var _recs := {}          # key -> {node, mat, used, alpha, block, shown}
var _frame := 0
var _last_request := ""
var _last_t := 0.0

# diagnostics
var stat_wanted := 0
var stat_missing := 0
var stat_visible := 0


func _init(c: ScrapClient, p: Node, s: Shader, maker: Callable) -> void:
	client = c
	parent = p
	shader = s
	make_node = maker
	client.text_received.connect(_on_text)


static func key_of(b: Dictionary) -> int:
	return int(b.key)


## A new map generation: cached text stays (content-keyed); only requests
## start over, since node ids in requests belong to the new generation.
func set_gen(new_gen: int) -> void:
	gen = new_gen
	_last_request = ""


## candidates: [[priority, block]] where a bigger priority is more
## important (typically on-screen line height). budget: most blocks shown.
## place(node, block) positions a node for the current camera.
func update(candidates: Array, budget: int, place: Callable) -> void:
	_frame += 1
	var now := Time.get_ticks_msec() / 1000.0
	var dt: float = clamp(now - _last_t, 0.0, 0.1)
	_last_t = now
	# hysteresis: what is shown keeps a bonus, so blocks near the cutoff do
	# not swap every frame
	for c in candidates:
		var r: Dictionary = _recs.get(key_of(c[1]), {})
		if r.get("shown", false):
			c[0] *= KEEP_BONUS
	candidates.sort_custom(func(a, b): return a[0] > b[0])
	var want := {}
	var missing := []
	for c in candidates.slice(0, budget):
		var b: Dictionary = c[1]
		var k := key_of(b)
		if want.has(k):
			continue
		want[k] = b
		# only blocks of the current generation can be requested: their file
		# ids are the server's current ones
		if not _recs.has(k) and int(b.get("gen", gen)) == gen:
			missing.append([b.file, b.col, b.seg])
	stat_wanted = want.size()
	stat_missing = missing.size()
	var sig := str(gen) + str(missing)
	if sig != _last_request and client.atlas_tex != null:
		_last_request = sig
		client.request_texts(gen, missing)
	var step := dt / FADE_S
	var vis := 0
	for k in _recs:
		var rec: Dictionary = _recs[k]
		var shown := want.has(k)
		rec.shown = shown
		if shown:
			rec.block = want[k]
			rec.used = _frame
			rec.alpha = min(1.0, rec.alpha + step)
		else:
			rec.alpha = max(0.0, rec.alpha - step)
		var node: Node = rec.node
		node.visible = rec.alpha > 0.0 and not rec.block.is_empty()
		if node.visible:
			vis += 1
			rec.mat.set_shader_parameter("fade", rec.alpha)
			place.call(node, rec.block)
	stat_visible = vis
	if _recs.size() > MAX_CACHED:
		var keys := _recs.keys()
		keys.sort_custom(func(a, b): return _recs[a].used < _recs[b].used)
		for i in _recs.size() - int(MAX_CACHED * 0.8):
			var rec: Dictionary = _recs[keys[i]]
			if not rec.node.visible:
				rec.node.queue_free()
				_recs.erase(keys[i])


## True while a fade is running (the view should keep redrawing).
func animating() -> bool:
	for k in _recs:
		var r: Dictionary = _recs[k]
		if (r.shown and r.alpha < 1.0) or (not r.shown and r.alpha > 0.0):
			return true
	return false


func _on_text(t: Dictionary) -> void:
	if client.atlas_tex == null:
		return
	var k := int(t.key)
	if _recs.has(k):
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var color: Image = t.color
	color.generate_mipmaps()
	mat.set_shader_parameter("color_tex", ImageTexture.create_from_image(color))
	mat.set_shader_parameter("glyph_tex", ImageTexture.create_from_image(t.glyph))
	mat.set_shader_parameter("atlas_tex", client.atlas_tex)
	mat.set_shader_parameter("atlas_grid", client.atlas_grid)
	mat.set_shader_parameter("rows", float(t.rows))
	mat.set_shader_parameter("col_chars", float(client.col_chars))
	mat.set_shader_parameter("tex_w", float(client.tex_w))
	mat.set_shader_parameter("fade", 0.0)
	var node: Node = make_node.call(mat)
	node.visible = false
	parent.add_child(node)
	_recs[k] = {"node": node, "mat": mat, "used": _frame, "alpha": 0.0, "block": {}, "shown": false}
