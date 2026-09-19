extends Node
## Data-driven settings (autoload "Settings").
##
## Values resolve as: schema default < preset < user override. The schema,
## shipped presets, keymaps and themes live in the repo's config/ folder
## (shared with the C# viewer); user overrides and user presets live in
## user://. Anything that reads a setting either asks get_value() when it
## needs it or listens to `changed`.

signal changed(id: String, value: Variant)
signal reloaded  # a preset was loaded: treat every value as changed

const USER_FILE := "user://settings.json"
const USER_PRESETS := "user://presets"

var config_dir := ""
var groups: Array = []      # schema groups, in order
var defs := {}              # id -> setting definition
var preset := "default"

var _preset_values := {}    # id -> raw value from the active preset
var _overrides := {}        # id -> raw value set by the user
var _save_timer: Timer


func _ready() -> void:
	config_dir = _find_config_dir()
	var schema: Dictionary = read_json(config_dir.path_join("settings.schema.json"))
	groups = schema.get("groups", [])
	for g in groups:
		for s in g.settings:
			defs[s.id] = s
	_load_user()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.5
	_save_timer.timeout.connect(_save_user)
	add_child(_save_timer)


## The repo's config/ folder next to the Godot project (development), or a
## copy bundled into res://config (exports).
func _find_config_dir() -> String:
	var dev := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join("config")
	if DirAccess.dir_exists_absolute(dev):
		return dev
	return "res://config"


static func read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if typeof(data) == TYPE_DICTIONARY else {}


# ------------------------------------------------------------------ values

func get_value(id: String) -> Variant:
	var def: Dictionary = defs.get(id, {})
	if def.is_empty():
		push_warning("unknown setting " + id)
		return null
	var raw = _overrides.get(id, _preset_values.get(id, def.default))
	return _typed(def, raw)


func is_default(id: String) -> bool:
	return not _overrides.has(id) and not _preset_values.has(id)


## True when the user changed the value away from the preset/default.
func is_overridden(id: String) -> bool:
	return _overrides.has(id)


func set_value(id: String, value: Variant) -> void:
	var def: Dictionary = defs.get(id, {})
	if def.is_empty():
		return
	var raw = _raw(def, value)
	if _overrides.get(id) == raw:
		return
	_overrides[id] = raw
	_save_timer.start()
	changed.emit(id, get_value(id))


func reset(id: String) -> void:
	if _overrides.erase(id):
		_save_timer.start()
		changed.emit(id, get_value(id))


func reset_all() -> void:
	_overrides.clear()
	_save_timer.start()
	reloaded.emit()


## Values of every setting with the given scope ("server" ones go to scrap).
func values_with_scope(scope: String) -> Dictionary:
	var out := {}
	for id in defs:
		if defs[id].get("scope", "viewer") == scope:
			out[id] = get_value(id)
	return out


## Choices of an enum setting: [{id, name, desc}].
func options(id: String) -> Array:
	var def: Dictionary = defs.get(id, {})
	if def.has("options"):
		return def.options.map(func(o): return {"id": o, "name": o, "desc": ""})
	match def.get("options_from", ""):
		"themes":
			return list_config("themes")
		"keymaps":
			return list_config("keymaps")
	return []


func _typed(def: Dictionary, raw: Variant) -> Variant:
	match def.type:
		"bool":
			return bool(raw)
		"int":
			return int(raw)
		"float":
			return float(raw)
		"color":
			return Color.html(str(raw))
	return raw


func _raw(def: Dictionary, value: Variant) -> Variant:
	match def.type:
		"color":
			return "#" + (value as Color).to_html(true)
		"int":
			return int(value)
		"float":
			return snappedf(float(value), def.get("step", 0.0001))
	return value


# ------------------------------------------------------------------ config files

## JSON files of a config subfolder as [{id, name, desc, path}].
func list_config(sub: String) -> Array:
	var out := []
	var dir := config_dir.path_join(sub)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json"):
			var d := read_json(dir.path_join(f))
			out.append({"id": f.get_basename(), "name": d.get("name", f.get_basename()), "desc": d.get("desc", ""), "path": dir.path_join(f)})
	return out


func load_config(sub: String, id: String) -> Dictionary:
	return read_json(config_dir.path_join(sub).path_join(id + ".json"))


# ------------------------------------------------------------------ presets

## Shipped presets first, then the user's: [{id, name, desc, user}].
func presets() -> Array:
	var out := []
	for p in list_config("presets"):
		p.user = false
		out.append(p)
	if not DirAccess.dir_exists_absolute(USER_PRESETS):
		return out
	for f in DirAccess.get_files_at(USER_PRESETS):
		if f.ends_with(".json"):
			var d := read_json(USER_PRESETS.path_join(f))
			out.append({"id": "user:" + f.get_basename(), "name": d.get("name", f.get_basename()), "desc": d.get("desc", ""), "user": true})
	return out


## Loads a preset: its values replace the user's overrides.
func load_preset(id: String) -> void:
	var d: Dictionary
	if id.begins_with("user:"):
		d = read_json(USER_PRESETS.path_join(id.substr(5) + ".json"))
	else:
		d = load_config("presets", id)
	if d.is_empty():
		push_warning("preset not found: " + id)
		return
	preset = id
	_preset_values = d.get("values", {})
	_overrides.clear()
	_save_user()
	reloaded.emit()


## Saves the current effective values that differ from the schema as a user
## preset.
func save_preset(name: String, desc := "") -> String:
	DirAccess.make_dir_recursive_absolute(USER_PRESETS)
	var values := _preset_values.duplicate()
	values.merge(_overrides, true)
	var file_id := name.to_snake_case().validate_filename()
	var f := FileAccess.open(USER_PRESETS.path_join(file_id + ".json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"name": name, "desc": desc, "values": values}, "  "))
	preset = "user:" + file_id
	_preset_values = values
	_overrides.clear()
	_save_user()
	return preset


# ------------------------------------------------------------------ persistence

func _load_user() -> void:
	var d := read_json(USER_FILE)
	preset = d.get("preset", "default")
	if preset.begins_with("user:"):
		_preset_values = read_json(USER_PRESETS.path_join(preset.substr(5) + ".json")).get("values", {})
	else:
		_preset_values = load_config("presets", preset).get("values", {})
	_overrides = d.get("values", {})
	# drop values the schema no longer knows
	for id in _overrides.keys():
		if not defs.has(id):
			_overrides.erase(id)


func _save_user() -> void:
	var f := FileAccess.open(USER_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"preset": preset, "values": _overrides}, "  "))
