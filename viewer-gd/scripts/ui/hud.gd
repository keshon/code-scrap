class_name Hud
extends PanelContainer
## Diagnostics overlay (Settings → Diagnostics, or F12): frame time, tile and
## text streaming counters, generation changes. Confirms flicker fixes and
## catches regressions.

var map: MapView
var city: CityView
var _label: Label
var _acc := 0.0
var _frames := 0
var _worst := 0.0
var _last := {}   # previous counter values, for per-second rates


func _init(m: MapView, c: CityView) -> void:
	map = m
	city = c


func _ready() -> void:
	theme_type_variation = "Floating"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.theme_type_variation = "SmallLabel"
	_label.add_theme_font_override("font", Style.font("mono", 400))
	add_child(_label)
	visible = Settings.get_value("debug.hud")
	Settings.changed.connect(func(id, v):
		if id == "debug.hud":
			visible = v)
	Settings.reloaded.connect(func(): visible = Settings.get_value("debug.hud"))
	Style.theme_changed.connect(func(): _label.add_theme_font_override("font", Style.font("mono", 400)))


func _process(dt: float) -> void:
	if not visible:
		return
	_acc += dt
	_frames += 1
	_worst = max(_worst, dt)
	if _acc < 0.5:
		return
	var three := city.visible
	var v: Variant = city if three else map
	var tl: TextLayer = v.text_layer()
	var ev: int = v.stat_evicted
	var rate := (ev - int(_last.get("ev", ev))) / _acc
	_last.ev = ev
	var lines := [
		"%s · %.1f ms avg · %.1f ms worst · %d fps" % ["3D" if three else "2D", _acc / _frames * 1000.0, _worst * 1000.0, int(_frames / _acc)],
		"tiles   shown %d · pending %d · cached %d · evicted %.0f/s" % [v.stat_shown, v.stat_missing, v.tile_count(), rate],
		"text    wanted %d · pending %d · drawn %d" % [tl.stat_wanted, tl.stat_missing, tl.stat_visible],
		"map     gen %d · %d generations seen" % [v.gen, v.stat_gens],
	]
	if not three:
		lines.append("level   %d · zoom %s px/unit" % [map._level, String.num(map.zoom, 1)])
	_label.text = "\n".join(lines)
	_acc = 0.0
	_frames = 0
	_worst = 0.0
