class_name ScrapClient
extends Node
## Talks to the `scrap serve` process over a local WebSocket.
## Starts the server itself when nothing is listening yet.

signal hello(info: Dictionary)
signal progress(info: Dictionary)
signal tile_received(tile: Dictionary)
signal reply(id: int, data: Dictionary)
signal connection_changed(connected: bool)
signal text_received(block: Dictionary)
signal font_ready

const TILE_PX := 256
const PROTOCOL := 16   ## docs/protocol.md; must match the server's hello.protocol

var url := "ws://127.0.0.1:7878/ws"
var repo := ""        ## folder to index when we launch the server
var scrap_exe := ""   ## path to scrap(.exe)

var _ws := WebSocketPeer.new()
var _connected := false
var _next_id := 1
var _server_pid := -1
var _retry_at := 0.0
var _attempts := 0
var _connect_started := 0.0
var _repo_explicit := false
var _open_sent := false

# GPU text: the glyph atlas (shared by every text block) and block geometry
var atlas_tex: Texture2D
var atlas_grid := Vector2(32, 14)
var col_chars := 100
var tex_w := 128


func _ready() -> void:
	_parse_args()
	_connect()


func _parse_args() -> void:
	var root := ProjectSettings.globalize_path("res://").trim_suffix("/")
	repo = root.get_base_dir()  # default: the code-scrap repo itself
	scrap_exe = root.get_base_dir().path_join("scrap/bin/scrap.exe")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--repo="):
			repo = a.substr(7)
			_repo_explicit = true
		elif a.begins_with("--scrap="):
			scrap_exe = a.substr(8)
		elif a.begins_with("--url="):
			url = a.substr(6)


func _connect() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 64 * 1024 * 1024
	_ws.outbound_buffer_size = 1024 * 1024
	_ws.max_queued_packets = 8192
	_ws.connect_to_url(url)
	_connect_started = Time.get_ticks_msec() / 1000.0


func _launch_server() -> void:
	if _server_pid > 0:
		return
	if not FileAccess.file_exists(scrap_exe):
		push_error("scrap server not found at %s (build it: cd scrap && go build -o bin/scrap.exe ./cmd/scrap)" % scrap_exe)
		return
	var port := url.get_slice(":", 2).get_slice("/", 0)
	_server_pid = OS.create_process(scrap_exe, ["serve", "-addr", "127.0.0.1:" + port, "-parent", str(OS.get_process_id()), repo], false)
	print("started scrap serve (pid %d) for %s" % [_server_pid, repo])


func _exit_tree() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)


func _process(_dt: float) -> void:
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_attempts = 0
				connection_changed.emit(true)
			while _ws.get_available_packet_count() > 0:
				var pkt := _ws.get_packet()
				if _ws.was_string_packet():
					_on_text(pkt.get_string_from_utf8())
				else:
					_on_binary(pkt)
		WebSocketPeer.STATE_CONNECTING:
			# a refused localhost connection can linger; treat it as a failure
			if Time.get_ticks_msec() / 1000.0 - _connect_started > 1.0:
				_ws.close()
				_ws = WebSocketPeer.new()
				_retry_at = 0.0
				_fail()
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				connection_changed.emit(false)
			_fail()


func _fail() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _retry_at:
		return
	_attempts += 1
	if _attempts == 1:
		_launch_server()
	_retry_at = now + 0.3
	_connect()


func is_open() -> bool:
	return _connected


## Sends a request and returns its id; the answer arrives via `reply`.
func request(op: String, params: Dictionary = {}) -> int:
	var id := _next_id
	_next_id += 1
	var msg := params.duplicate()
	msg["op"] = op
	msg["id"] = id
	if _connected:
		_ws.send_text(JSON.stringify(msg))
	return id


## Replaces the server's text-block queue ([file node, column, segment]).
func request_texts(gen: int, keys: Array) -> void:
	if _connected:
		_ws.send_text(JSON.stringify({"op": "texts", "gen": gen, "texts": keys}))


## Replaces the server's tile queue (keys ordered by priority).
## dim 2 = flat boxes, 3 = extruded boxes for the city view.
func request_tiles(gen: int, keys: Array, dim := 2) -> void:
	if _connected:
		_ws.send_text(JSON.stringify({"op": "tiles", "gen": gen, "keys": keys, "dim": dim}))


func _on_text(s: String) -> void:
	var data = JSON.parse_string(s)
	if typeof(data) != TYPE_DICTIONARY:
		return
	match data.get("op", ""):
		"hello":
			if int(data.get("protocol", 0)) != PROTOCOL:
				push_error("scrap server speaks protocol %d, this viewer %d: rebuild scrap (build.cmd) or stop the old server" % [int(data.get("protocol", 0)), PROTOCOL])
			# a server left over from another session may be mapping a
			# different folder: ask it to switch to ours
			if _repo_explicit and not _open_sent and _norm(data.get("root", "")) != _norm(repo):
				_open_sent = true
				request("open", {"path": repo})
			if data.has("text"):
				col_chars = int(data.text.colChars)
				tex_w = int(data.text.texW)
			if atlas_tex == null and _connected:
				_ws.send_text(JSON.stringify({"op": "font"}))
			hello.emit(data)
		"progress":
			progress.emit(data)
		_:
			reply.emit(int(data.get("id", 0)), data)


func _norm(p: String) -> String:
	return p.replace("\\", "/").trim_suffix("/").to_lower()


func _on_binary(b: PackedByteArray) -> void:
	var typ := b.decode_u8(0)
	if typ == 3:
		_on_text_block(b)
		return
	if typ == 4:
		_on_font(b)
		return
	if b.size() < 24 or (typ != 1 and typ != 2):
		return
	var t := {}
	t.dim = 2 if typ == 1 else 3
	var stride := 16 if typ == 1 else 20
	t.z = b.decode_u8(1)
	var flags := b.decode_u16(2)
	t.x = b.decode_s32(4)
	t.y = b.decode_s32(8)
	t.gen = b.decode_u32(12)
	var n := b.decode_u32(16)
	var off := 20
	t.buffer = b.slice(off, off + n * stride * 4).to_float32_array()
	off += n * stride * 4
	t.ids = b.slice(off, off + n * 4).to_int32_array()
	off += n * 4
	var nl := b.decode_u32(off)
	off += 4
	var labels := []
	for i in nl:
		var l := {}
		l.id = b.decode_s32(off)
		var k := b.decode_u8(off + 4)
		l.kind = k & 15          # 0 dir, 1 file, 2 scope
		l.scope = k >> 4         # scope kind: 0 block, 1 func, 2 type, 3 namespace
		l.color = Color8(b.decode_u8(off + 5), b.decode_u8(off + 6), b.decode_u8(off + 7))
		l.rect = Rect2(b.decode_float(off + 8), b.decode_float(off + 12), b.decode_float(off + 16), b.decode_float(off + 20))
		l.top = b.decode_float(off + 24)
		l.lines = b.decode_u32(off + 28)
		var ln := b.decode_u16(off + 32)
		l.text = b.slice(off + 34, off + 34 + ln).get_string_from_utf8()
		off += 34 + ln
		labels.append(l)
	t.labels = labels
	var blocks := []
	var nb := b.decode_u32(off)
	off += 4
	for i in nb:
		blocks.append({
			"file": b.decode_s32(off), "col": b.decode_u16(off + 4), "seg": b.decode_u16(off + 6),
			"rows": b.decode_u16(off + 8),
			"rect": Rect2(b.decode_float(off + 10), b.decode_float(off + 14), b.decode_float(off + 18), b.decode_float(off + 22)),
			"top": b.decode_float(off + 26), "key": b.decode_u32(off + 30),
		})
		off += 34
	t.blocks = blocks
	tile_received.emit(t)


func _on_text_block(b: PackedByteArray) -> void:
	var t := {}
	t.col = b.decode_u16(2)
	t.file = b.decode_s32(4)
	t.seg = b.decode_u16(8)
	t.rows = b.decode_u16(10)
	t.gen = b.decode_u32(12)
	t.key = b.decode_u32(16)
	var n: int = tex_w * t.rows
	t.color = Image.create_from_data(tex_w, t.rows, false, Image.FORMAT_RGBA8, b.slice(20, 20 + n * 4))
	t.glyph = Image.create_from_data(tex_w, t.rows, false, Image.FORMAT_RG8, b.slice(20 + n * 4, 20 + n * 6))
	text_received.emit(t)


func _on_font(b: PackedByteArray) -> void:
	var cols := b.decode_u16(2)
	var rows := b.decode_u16(4)
	var cw := b.decode_u16(6)
	var ch := b.decode_u16(8)
	var img := Image.create_from_data(cols * cw, rows * ch, false, Image.FORMAT_L8, b.slice(10))
	img.generate_mipmaps()
	atlas_tex = ImageTexture.create_from_image(img)
	atlas_grid = Vector2(cols, rows)
	font_ready.emit()
