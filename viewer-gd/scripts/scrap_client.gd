class_name ScrapClient
extends Node
## Talks to the `scrap serve` process over a local WebSocket.
## Starts the server itself when nothing is listening yet.

signal hello(info: Dictionary)
signal progress(info: Dictionary)
signal tile_received(tile: Dictionary)
signal reply(id: int, data: Dictionary)
signal connection_changed(connected: bool)

const TILE_PX := 256

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
	_server_pid = OS.create_process(scrap_exe, ["serve", "-addr", "127.0.0.1:" + port, repo], false)
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


## Replaces the server's tile queue (keys ordered by priority).
func request_tiles(gen: int, keys: Array) -> void:
	if _connected:
		_ws.send_text(JSON.stringify({"op": "tiles", "gen": gen, "keys": keys}))


func _on_text(s: String) -> void:
	var data = JSON.parse_string(s)
	if typeof(data) != TYPE_DICTIONARY:
		return
	match data.get("op", ""):
		"hello":
			# a server left over from another session may be mapping a
			# different folder: ask it to switch to ours
			if _repo_explicit and not _open_sent and _norm(data.get("root", "")) != _norm(repo):
				_open_sent = true
				request("open", {"path": repo})
			hello.emit(data)
		"progress":
			progress.emit(data)
		_:
			reply.emit(int(data.get("id", 0)), data)


func _norm(p: String) -> String:
	return p.replace("\\", "/").trim_suffix("/").to_lower()


func _on_binary(b: PackedByteArray) -> void:
	if b.size() < 24 or b.decode_u8(0) != 1:
		return
	var t := {}
	t.z = b.decode_u8(1)
	var flags := b.decode_u16(2)
	t.x = b.decode_s32(4)
	t.y = b.decode_s32(8)
	t.gen = b.decode_u32(12)
	var n := b.decode_u32(16)
	var off := 20
	t.buffer = b.slice(off, off + n * 64).to_float32_array()
	off += n * 64
	t.ids = b.slice(off, off + n * 4).to_int32_array()
	off += n * 4
	var nl := b.decode_u32(off)
	off += 4
	var labels := []
	for i in nl:
		var l := {}
		l.id = b.decode_s32(off)
		l.kind = b.decode_u8(off + 4)
		l.rect = Rect2(b.decode_float(off + 5), b.decode_float(off + 9), b.decode_float(off + 13), b.decode_float(off + 17))
		var ln := b.decode_u16(off + 21)
		l.text = b.slice(off + 23, off + 23 + ln).get_string_from_utf8()
		off += 23 + ln
		labels.append(l)
	t.labels = labels
	if flags & 1:
		t.code = Image.create_from_data(TILE_PX, TILE_PX, false, Image.FORMAT_RGBA8, b.slice(off, off + TILE_PX * TILE_PX * 4))
	tile_received.emit(t)
