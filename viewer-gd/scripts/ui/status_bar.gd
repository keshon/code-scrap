class_name StatusBar
extends PanelContainer
## Bottom zone: server state, index progress, what is under the cursor and
## the active keymap's navigation hints.

var _dot: ColorRect
var _progress: Label
var _status: Label
var _hints: Label
var _connected := false


func _ready() -> void:
	theme_type_variation = "Bar"
	var clip := ScrollContainer.new()
	clip.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	clip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(clip)
	var hb := HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clip.add_child(hb)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(_dot)
	_progress = _label()
	hb.add_child(_progress)
	hb.add_child(VSeparator.new())
	_status = _label()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(_status)
	_hints = _label()
	hb.add_child(_hints)
	_hints.text = Keymap.hints()
	Keymap.keymap_changed.connect(func(): _hints.text = Keymap.hints())
	Style.theme_changed.connect(func(): set_connected(_connected))
	set_connected(false)


func set_connected(ok: bool) -> void:
	_connected = ok
	_dot.color = Style.color("good") if ok else Style.color("bad")
	_dot.tooltip_text = "server: " + ("connected" if ok else "disconnected — starting scrap serve…")
	if not ok:
		_progress.text = "connecting…"


func set_progress(text: String) -> void:
	_progress.text = text


func set_status(text: String) -> void:
	_status.text = text


func _label() -> Label:
	var l := Label.new()
	l.theme_type_variation = "SmallLabel"
	return l
