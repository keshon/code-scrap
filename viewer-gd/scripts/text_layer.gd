class_name TextLayer
extends RefCounted
## Streams GPU text blocks (one column of a file's text, ≤4096 lines) for a
## view. The view says which blocks it wants each frame and how to create
## and place their nodes; this class requests, caches and evicts them.

const MAX_CACHED := 700

var client: ScrapClient
var parent: Node
var make_node: Callable  # (material: ShaderMaterial) -> Node
var shader: Shader
var gen := -1

var _recs := {}          # "file:col:seg" -> {node, used}
var _frame := 0
var _last_request := ""


func _init(c: ScrapClient, p: Node, s: Shader, maker: Callable) -> void:
	client = c
	parent = p
	shader = s
	make_node = maker
	client.text_received.connect(_on_text)


static func key_of(b: Dictionary) -> String:
	return "%d:%d:%d" % [b.file, b.col, b.seg]


## wanted: block dictionaries, most important first. place(node, block)
## positions a node for the current camera.
func update(wanted: Array, place: Callable) -> void:
	_frame += 1
	var want := {}
	var missing := []
	for b in wanted:
		var k := key_of(b)
		want[k] = b
		if not _recs.has(k):
			missing.append([b.file, b.col, b.seg])
	if OS.get_environment("SCRAP_DEBUG") != "" and _frame % 30 == 0:
		var vis := 0
		for k in _recs:
			if _recs[k].node.visible:
				vis += 1
		print("text: wanted %d missing %d cached %d visible %d" % [wanted.size(), missing.size(), _recs.size(), vis])
	var sig := str(gen) + str(missing)
	if sig != _last_request and client.atlas_tex != null:
		_last_request = sig
		client.request_texts(gen, missing)
	for k in _recs:
		var rec: Dictionary = _recs[k]
		var node: Node = rec.node
		var vis := want.has(k)
		node.visible = vis
		if vis:
			rec.used = _frame
			place.call(node, want[k])
	if _recs.size() > MAX_CACHED:
		var keys := _recs.keys()
		keys.sort_custom(func(a, b): return _recs[a].used < _recs[b].used)
		for i in _recs.size() - int(MAX_CACHED * 0.8):
			var rec: Dictionary = _recs[keys[i]]
			if not rec.node.visible:
				rec.node.queue_free()
				_recs.erase(keys[i])


func reset(new_gen: int) -> void:
	gen = new_gen
	for k in _recs:
		_recs[k].node.queue_free()
	_recs.clear()
	_last_request = ""


func _on_text(t: Dictionary) -> void:
	if int(t.gen) != gen or client.atlas_tex == null:
		return
	var k := key_of(t)
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
	var node: Node = make_node.call(mat)
	node.visible = false
	parent.add_child(node)
	_recs[k] = {"node": node, "used": _frame}
