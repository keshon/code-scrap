extends Node
## Input as named actions (autoload "Keymap").
##
## A keymap (config/keymaps/*.json) binds mouse buttons, wheel and keys, each
## with an exact set of modifiers, to actions. Views and the app shell ask
## for the action instead of reading raw events, so navigation schemes
## (Maya, Classic, …) are data.
##
## Mouse actions: orbit, pan, dolly, select. A mouse binding may also name a
## "click" action for a press that never turns into a drag.

signal keymap_changed

var keymap_id := ""
var keymap := {}

const BUTTONS := {"left": MOUSE_BUTTON_LEFT, "middle": MOUSE_BUTTON_MIDDLE, "right": MOUSE_BUTTON_RIGHT}
const BUTTON_NAMES := {"left": "LMB", "middle": "MMB", "right": "RMB"}


func _ready() -> void:
	_load(Settings.get_value("ui.keymap"))
	Settings.changed.connect(func(id, v):
		if id == "ui.keymap":
			_load(v))
	Settings.reloaded.connect(func(): _load(Settings.get_value("ui.keymap")))


func _load(id: String) -> void:
	var km := Settings.load_config("keymaps", id)
	if km.is_empty():
		push_warning("keymap not found: " + id)
		return
	keymap_id = id
	keymap = km
	keymap_changed.emit()


static func _mods_of(ev: InputEventWithModifiers) -> Array:
	var m := []
	if ev.alt_pressed:
		m.append("alt")
	if ev.ctrl_pressed:
		m.append("ctrl")
	if ev.shift_pressed:
		m.append("shift")
	if ev.meta_pressed:
		m.append("meta")
	return m


static func _same_mods(bound: Array, pressed: Array) -> bool:
	if bound.size() != pressed.size():
		return false
	for m in bound:
		if not m in pressed:
			return false
	return true


## The mouse binding for a button press: {action, click} or {} when unbound.
func mouse_binding(ev: InputEventMouseButton) -> Dictionary:
	var mods := _mods_of(ev)
	for b in keymap.get("mouse", []):
		if BUTTONS.get(b.button, -1) == ev.button_index and _same_mods(b.get("mods", []), mods):
			var click: String = b.get("click", "select" if b.action == "select" else "")
			return {"action": b.action, "click": click}
	return {}


## The wheel action ("zoom" …) for a wheel event, or "".
func wheel_action(ev: InputEventMouseButton) -> String:
	var mods := _mods_of(ev)
	for b in keymap.get("wheel", []):
		if _same_mods(b.get("mods", []), mods):
			return b.action
	return ""


## The action bound to a key press, or "".
func key_action(ev: InputEventKey) -> String:
	if not ev.pressed or ev.echo:
		return ""
	var mods := _mods_of(ev)
	for b in keymap.get("keys", []):
		if OS.find_keycode_from_string(b.key) == ev.keycode and _same_mods(b.get("mods", []), mods):
			return b.action
	return ""


## Short navigation help for the status bar, e.g.
## "Alt+LMB orbit · Alt+MMB pan · F frame · A all · Q deselect".
func hints() -> String:
	var parts := []
	for b in keymap.get("mouse", []):
		if b.action == "select":
			continue
		var mods: Array = b.get("mods", [])
		var chord := "+".join(mods.map(func(m): return m.capitalize()) + [BUTTON_NAMES.get(b.button, b.button)])
		parts.append("%s %s" % [chord, b.action])
	var keys := {"frame_selected": "frame", "frame_all": "all", "deselect": "deselect"}
	for b in keymap.get("keys", []):
		if keys.has(b.action) and b.get("mods", []).is_empty():
			parts.append("%s %s" % [b.key, keys[b.action]])
			keys.erase(b.action)
	return " · ".join(parts)
