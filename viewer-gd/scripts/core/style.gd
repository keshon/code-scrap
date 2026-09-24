extends Node
## Theme from design tokens (autoload "Style").
##
## A theme is a JSON token file in config/themes (fonts, colors, shape,
## depth, type, decor). This builds a Godot Theme from it and applies it to
## the whole window tree; components never hard-code colors or radii.
## Custom-drawn UI reads tokens through color(), num() and flag().
##
## Theme type variations used by the app shell:
##   PanelContainer: "Bar" (toolbar/status), "Card" (grouped content),
##                   "Inset" (wells, segmented backgrounds), "Floating"
##                   (overlays on the viewport)
##   Label:          "DimLabel", "SmallLabel", "TitleLabel", "SectionLabel"
##   Button:         "FlatButton", "SegmentButton"

signal theme_changed
signal scale_changed(factor: float)

var theme_id := ""
var tokens := {}
var theme: Theme
var fonts := {}  # "plex-sans" -> {400: Font, 500: Font, 600: Font}


# setting -> [shader global, how to convert]
#   "f" float · "px" pixels, scaled with the interface (physical on the GPU)
#   "b" bool as 0/1 · "c" color · "e" enum as its option index
const SHADER_GLOBALS := {
	"text.glyph_from_px": ["scrap_glyph_from", "f"],
	"text.glyph_full_px": ["scrap_glyph_full", "f"],
	"text.weight": ["scrap_text_weight", "f"],
	"text.color_mode": ["scrap_text_mode", "e"],
	"text.mono_tone": ["scrap_text_mono", "c"],
	"text.roof_tone": ["scrap_roof_tone", "f"],
	"lines.box_width": ["scrap_line_px", "px"],
	"lines.min_box_px": ["scrap_line_min_box", "px"],
	"lines.depth_tone": ["scrap_depth_tone", "f"],
	"scopes.opacity": ["scrap_scope_opacity", "f"],
	"scopes.fill": ["scrap_scope_fill", "b"],
	"scopes.radius": ["scrap_scope_radius", "px"],
	"scopes.dash": ["scrap_scope_dash", "b"],
	"scopes.nested_fade": ["scrap_scope_fade", "f"],
	"scopes.functions": ["scrap_scope_funcs", "b"],
	"scopes.containers": ["scrap_scope_containers", "b"],
	"look.light_strength": ["scrap_light_strength", "f"],
	"look.contact": ["scrap_contact", "f"],
	"look.bevel": ["scrap_bevel", "f"],
	"look.light": ["scrap_flat", "e"],
	"look.roof_fill": ["scrap_roof_fill", "e"],       # 0 auto, 1 dark, 2 colored
	"look.headers": ["scrap_headers", "b"],
	"look.light_space": ["scrap_light_space", "e"],   # 0 camera, 1 world
	"look.ambient": ["scrap_ambient", "f"],
	"look.specular": ["scrap_specular", "f"],
	"look.gloss": ["scrap_gloss", "f"],
	"look.roof_diffuse": ["scrap_roof_diffuse", "e"],  # 0 all, 1 selected, 2 none
	"look.light_yaw": ["", "light"],
	"look.light_pitch": ["", "light"],
}


func _ready() -> void:
	_load_fonts()
	apply(Settings.get_value("ui.theme"))
	apply_scale()
	_sync_shader_globals()
	Settings.changed.connect(func(id, v):
		if id == "ui.theme":
			apply(v)
		elif id == "ui.scale" or id == "ui.scale_auto":
			apply_scale()
			_sync_shader_globals()
		elif SHADER_GLOBALS.has(id):
			_sync_shader_globals())
	Settings.reloaded.connect(func():
		apply(Settings.get_value("ui.theme"))
		apply_scale()
		_sync_shader_globals())


func _sync_shader_globals() -> void:
	var f := get_tree().root.content_scale_factor
	for id in SHADER_GLOBALS:
		var g: Array = SHADER_GLOBALS[id]
		var v = Settings.get_value(id)
		match g[1]:
			"f":
				RenderingServer.global_shader_parameter_set(g[0], float(v))
			"px":
				RenderingServer.global_shader_parameter_set(g[0], float(v) * f)
			"b":
				RenderingServer.global_shader_parameter_set(g[0], 1.0 if v else 0.0)
			"c":
				RenderingServer.global_shader_parameter_set(g[0], v)
			"e":
				var opts: Array = Settings.defs[id].get("options", [])
				RenderingServer.global_shader_parameter_set(g[0], float(max(opts.find(v), 0)))
	# the light direction, pointing toward the light
	var yaw := deg_to_rad(float(Settings.get_value("look.light_yaw")))
	var pitch := deg_to_rad(float(Settings.get_value("look.light_pitch")))
	var d := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	RenderingServer.global_shader_parameter_set("scrap_light_dir", d)


## A width in UI pixels as whole physical pixels (at least one), for lines
## that should look the same everywhere.
func line_px(ui_px: float) -> float:
	return max(1.0, round(ui_px * get_tree().root.content_scale_factor))


# ------------------------------------------------------------------ scale

## The operating system's display scale for the window's screen (1 = 96 dpi).
func display_scale() -> float:
	var screen := DisplayServer.window_get_current_screen()
	var f := DisplayServer.screen_get_scale(screen)  # macOS, Wayland
	if OS.get_name() == "Windows":
		f = DisplayServer.screen_get_dpi(screen) / 96.0
	return clampf(f, 0.5, 4.0)


## Interface scale = the user's scale × (display scale when following it).
func ui_scale() -> float:
	var f: float = Settings.get_value("ui.scale")
	if Settings.get_value("ui.scale_auto"):
		f *= display_scale()
	return f


func apply_scale() -> void:
	var f := ui_scale()
	var win := get_tree().root
	if is_equal_approx(win.content_scale_factor, f):
		return
	win.content_scale_factor = f
	scale_changed.emit(f)


# ------------------------------------------------------------------ tokens

func color(name: String) -> Color:
	return Color.html(str(tokens.get("color", {}).get(name, "#ff00ff")))


func num(group: String, name: String, fallback := 0.0) -> float:
	return float(tokens.get(group, {}).get(name, fallback))


func flag(name: String) -> bool:
	return bool(tokens.get("decor", {}).get(name, false))


func font(role := "ui", weight := 400) -> Font:
	var family: Dictionary = fonts.get(tokens.get("font", {}).get(role, "plex-sans"), fonts["plex-sans"])
	return family.get(weight, family[400])


## Label text in the theme's letter case (FUI themes use uppercase).
func text(s: String) -> String:
	return s.to_upper() if tokens.get("type", {}).get("label_case", "none") == "upper" else s


# ------------------------------------------------------------------ fonts

func _load_fonts() -> void:
	var fallback: Font = load("res://fonts/Go-Medium.ttf")
	for family in [["plex-sans", "ibm-plex-sans", [400, 500, 600]], ["plex-mono", "ibm-plex-mono", [400, 500]]]:
		var weights := {}
		for w in family[2]:
			var f: FontFile = load("res://fonts/%s-latin-%d-normal.woff2" % [family[1], w]).duplicate()
			var cyr: Font = load("res://fonts/%s-cyrillic-%d-normal.woff2" % [family[1], w])
			f.fallbacks = [cyr, fallback]
			weights[w] = f
		fonts[family[0]] = weights


# ------------------------------------------------------------------ building

func apply(id: String) -> void:
	var t := Settings.load_config("themes", id)
	if t.is_empty():
		push_warning("theme not found: " + id)
		return
	theme_id = id
	tokens = t
	theme = _build()
	get_tree().root.theme = theme
	RenderingServer.set_default_clear_color(color("bg"))
	theme_changed.emit()


func _sb(bg: Color, radius: float, margins := Vector4(8, 6, 8, 6), border := Color(0, 0, 0, 0), bw := 0, shadow := 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.corner_detail = 6
	s.content_margin_left = margins.x
	s.content_margin_top = margins.y
	s.content_margin_right = margins.z
	s.content_margin_bottom = margins.w
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	if shadow > 0.0:
		s.shadow_size = int(shadow)
		s.shadow_color = Color.html(str(tokens.get("depth", {}).get("shadow_color", "#00000066")))
		s.shadow_offset = Vector2(0, shadow * 0.3)
	s.anti_aliasing = true
	return s


func _empty(margins := Vector4(8, 6, 8, 6)) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = margins.x
	s.content_margin_top = margins.y
	s.content_margin_right = margins.z
	s.content_margin_bottom = margins.w
	return s


const ICONS := {
	"home": '<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/><path d="M10 20v-5h4v5"/>',
	"folder": '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2.5h8.5A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"/>',
	"settings": '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
	"search": '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>',
	"menu": '<path d="M4 7h16M4 12h16M4 17h16"/>',
	"command": '<path d="M6 9l3 3-3 3M11 15h7"/>',
	"file": '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4"/>',
	"symbol": '<path d="M9 7l-4 5 4 5M15 7l4 5-4 5"/>',
	"chevron": '<path d="M9 6l6 6-6 6"/>',
	"camera": '<path d="M4 8h3l2-2.5h6L17 8h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
	"sidebar": '<rect x="3.5" y="4.5" width="17" height="15" rx="1.5"/><path d="M9 4.5v15"/>',
	"eye": '<path d="M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
	"save": '<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
	"close": '<path d="M6 6l12 12M18 6L6 18"/>',
	"reset": '<path d="M4 12a8 8 0 1 0 2.3-5.6"/><path d="M4 4v4.5h4.5"/>',
	"info": '<circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 7.6v.1"/>',
	"frame": '<path d="M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4"/>',
}


## A stroked 18 px UI icon in the theme's secondary text color (or color).
func icon(name: String, tint := Color(0, 0, 0, 0), px := 18) -> DPITexture:
	var c := tint if tint.a > 0.0 else color("text2")
	return _svg('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">%s</svg>' % [px, px, _hex(c), ICONS.get(name, "")])


func _svg(src: String) -> DPITexture:
	return DPITexture.create_from_string(src)


func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


func _build() -> Theme:
	var th := Theme.new()
	var r := num("shape", "radius", 12)
	var rc := num("shape", "radius_control", 8)
	var bw := int(num("shape", "border_width", 0))
	var pad := num("shape", "padding", 12)
	var shadow := num("depth", "shadow_size", 0)
	var h := num("shape", "control_height", 30)
	var size := int(num("font", "size", 13))
	var small := int(num("font", "size_small", 12))
	var title := int(num("font", "size_title", 15))
	var s1 := color("surface1")
	var s2 := color("surface2")
	var s3 := color("surface3")
	var raised := color("raised")
	var border := color("border")
	var text := color("text")
	var text2 := color("text2")
	var text3 := color("text3")
	var accent := color("accent")
	var ctl := Vector4(12, (h - size * 1.4) * 0.5, 12, (h - size * 1.4) * 0.5)

	th.default_font = font("ui", 400)
	th.default_font_size = size

	# text
	th.set_color("font_color", "Label", text)
	for v in [["DimLabel", text2, size, 400], ["SmallLabel", text2, small, 400], ["TitleLabel", text, title, 600], ["SectionLabel", text, size, 600]]:
		th.set_type_variation(v[0], "Label")
		th.set_color("font_color", v[0], v[1])
		th.set_font_size("font_size", v[0], v[2])
		th.set_font("font", v[0], font("ui", v[3]))
	th.set_color("default_color", "RichTextLabel", text)
	th.set_font("normal_font", "RichTextLabel", font("ui", 400))
	th.set_font("bold_font", "RichTextLabel", font("ui", 600))
	th.set_font("mono_font", "RichTextLabel", font("mono", 400))
	th.set_color("selection_color", "RichTextLabel", Color(accent, 0.3))

	# panels
	th.set_stylebox("panel", "Panel", _sb(s1, r, Vector4(pad, pad, pad, pad), border, bw, shadow))
	th.set_stylebox("panel", "PanelContainer", _sb(s1, r, Vector4(pad, pad, pad, pad), border, bw, shadow))
	for v in [["Bar", s1, r, Vector4(pad, 6, pad, 6), shadow], ["Card", s2, rc, Vector4(pad, 10, pad, 10), 0.0],
			["Inset", s3, rc, Vector4(3, 3, 3, 3), 0.0],
			# panels whose content scrolls: the scrollbar sits close to the edge
			["Side", s1, r, Vector4(pad, pad, 4, 6), shadow]]:
		th.set_type_variation(v[0], "PanelContainer")
		th.set_stylebox("panel", v[0], _sb(v[1], v[2], v[3], border, bw, v[4]))
	# the viewport frame (a Panel: overlays inside are placed by anchors)
	th.set_type_variation("ViewportFrame", "Panel")
	th.set_stylebox("panel", "ViewportFrame", _sb(color("bg"), r, Vector4(0, 0, 0, 0)))
	# islands over the map: slim, no outline (a bright edge competes with the
	# boxes underneath), lifted off the map by a soft shadow instead
	th.set_type_variation("Floating", "PanelContainer")
	var fl := _sb(Color(s1, 0.92), rc, Vector4(10, 3, 10, 3), Color(0, 0, 0, 0), 0, max(shadow, 8.0))
	th.set_stylebox("panel", "Floating", fl)

	# buttons
	var bn := _sb(s3, rc, ctl, border, bw)
	var bh := _sb(raised, rc, ctl, border, bw)
	var bp := _sb(raised, rc, ctl, accent, max(bw, 1) if bw > 0 else 0)
	var focus := _sb(Color(0, 0, 0, 0), rc, ctl, Color(accent, 0.8), 1)
	for type in ["Button", "OptionButton", "MenuButton", "ColorPickerButton"]:
		th.set_stylebox("normal", type, bn)
		th.set_stylebox("hover", type, bh)
		th.set_stylebox("pressed", type, bp)
		th.set_stylebox("hover_pressed", type, bp)
		th.set_stylebox("focus", type, focus)
		th.set_stylebox("disabled", type, _sb(Color(s3, 0.5), rc, ctl))
		th.set_color("font_color", type, text)
		th.set_color("font_hover_color", type, text)
		th.set_color("font_pressed_color", type, text)
		th.set_color("font_hover_pressed_color", type, text)
		th.set_color("font_focus_color", type, text)
		th.set_color("font_disabled_color", type, text3)
		th.set_color("icon_normal_color", type, text2)
		th.set_color("icon_hover_color", type, text)
		th.set_color("icon_pressed_color", type, text)
	th.set_type_variation("FlatButton", "Button")
	th.set_stylebox("normal", "FlatButton", _empty(ctl))
	th.set_stylebox("hover", "FlatButton", _sb(s3, rc, ctl))
	th.set_stylebox("pressed", "FlatButton", _sb(raised, rc, ctl))
	th.set_stylebox("hover_pressed", "FlatButton", _sb(raised, rc, ctl))
	# one step down, for the islands that float over the map: less padding,
	# the small text size, so the bar can be slim without feeling cramped
	var slimpad := maxf((h * 0.72 - small * 1.4) * 0.5, 1.0)
	var slim := Vector4(8, slimpad, 8, slimpad)
	th.set_type_variation("SlimButton", "Button")
	th.set_stylebox("normal", "SlimButton", _empty(slim))
	th.set_stylebox("hover", "SlimButton", _sb(s3, rc, slim))
	th.set_stylebox("pressed", "SlimButton", _sb(raised, rc, slim))
	th.set_stylebox("hover_pressed", "SlimButton", _sb(raised, rc, slim))
	th.set_font_size("font_size", "SlimButton", small)
	th.set_color("font_color", "SlimButton", text2)
	th.set_color("font_hover_color", "SlimButton", text)
	th.set_color("font_pressed_color", "SlimButton", text)
	th.set_type_variation("FloatingSlim", "PanelContainer")
	th.set_stylebox("panel", "FloatingSlim", _sb(Color(s1, 0.92), rc, Vector4(6, 2, 6, 2), Color(0, 0, 0, 0), 0, max(shadow, 8.0)))
	th.set_type_variation("SegmentButton", "Button")
	var seg := Vector4(14, ctl.y - 3, 14, ctl.y - 3)
	th.set_stylebox("normal", "SegmentButton", _empty(seg))
	th.set_stylebox("hover", "SegmentButton", _empty(seg))
	th.set_stylebox("pressed", "SegmentButton", _sb(raised, max(rc - 2, 0), seg))
	th.set_stylebox("hover_pressed", "SegmentButton", _sb(raised, max(rc - 2, 0), seg))
	th.set_stylebox("focus", "SegmentButton", _empty())
	th.set_color("font_color", "SegmentButton", text2)
	th.set_color("font_hover_color", "SegmentButton", text)
	th.set_color("font_pressed_color", "SegmentButton", text)
	th.set_color("font_hover_pressed_color", "SegmentButton", text)
	var chevron := '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>' % _hex(text2)
	th.set_icon("arrow", "OptionButton", _svg(chevron))
	th.set_constant("arrow_margin", "OptionButton", 10)

	# toggles and check boxes
	var sw := func(on: bool) -> String:
		var knob_x := 24 if on else 10
		return '<svg xmlns="http://www.w3.org/2000/svg" width="34" height="20"><rect x="0" y="0" width="34" height="20" rx="10" fill="%s"/><circle cx="%d" cy="10" r="7" fill="%s"/></svg>' % [
			_hex(accent) if on else _hex(raised), knob_x, "#ffffff" if on else _hex(text2)]
	for type in ["CheckButton", "CheckBox"]:
		th.set_stylebox("normal", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("hover", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("pressed", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("hover_pressed", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("focus", type, _empty())
		th.set_color("font_color", type, text)
		th.set_color("font_hover_color", type, text)
		th.set_color("font_pressed_color", type, text)
		th.set_color("font_hover_pressed_color", type, text)
	th.set_icon("checked", "CheckButton", _svg(sw.call(true)))
	th.set_icon("unchecked", "CheckButton", _svg(sw.call(false)))
	var box := func(on: bool) -> String:
		var mark := '<path d="M4.5 9.5l3 3 6-7" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' if on else ""
		return '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18"><rect x="0.5" y="0.5" width="17" height="17" rx="%d" fill="%s" stroke="%s"/>%s</svg>' % [
			int(min(rc, 5)), _hex(accent) if on else _hex(s3), _hex(accent) if on else _hex(raised), mark]
	th.set_icon("checked", "CheckBox", _svg(box.call(true)))
	th.set_icon("unchecked", "CheckBox", _svg(box.call(false)))

	# text fields
	var le := _sb(s3, rc, Vector4(10, ctl.y, 10, ctl.y), border, bw)
	th.set_stylebox("normal", "LineEdit", le)
	th.set_stylebox("focus", "LineEdit", _sb(Color(0, 0, 0, 0), rc, Vector4(10, ctl.y, 10, ctl.y), accent, 1))
	th.set_stylebox("read_only", "LineEdit", _sb(Color(s3, 0.5), rc, Vector4(10, ctl.y, 10, ctl.y)))
	th.set_color("font_color", "LineEdit", text)
	th.set_color("font_placeholder_color", "LineEdit", text3)
	th.set_color("caret_color", "LineEdit", accent)
	th.set_color("selection_color", "LineEdit", Color(accent, 0.35))
	th.set_color("clear_button_color", "LineEdit", text2)

	# tabs
	th.set_stylebox("panel", "TabContainer", _empty(Vector4(0, 10, 0, 0)))
	th.set_stylebox("tabbar_background", "TabContainer", _sb(s3, rc, Vector4(3, 3, 3, 3)))
	var tab := Vector4(12, 5, 12, 5)
	th.set_stylebox("tab_selected", "TabContainer", _sb(raised, max(rc - 2, 0), tab))
	th.set_stylebox("tab_unselected", "TabContainer", _empty(tab))
	th.set_stylebox("tab_hovered", "TabContainer", _sb(s2, max(rc - 2, 0), tab))
	th.set_stylebox("tab_focus", "TabContainer", _empty())
	th.set_color("font_selected_color", "TabContainer", text)
	th.set_color("font_unselected_color", "TabContainer", text2)
	th.set_color("font_hovered_color", "TabContainer", text)
	th.set_constant("side_margin", "TabContainer", 0)

	# lists
	th.set_stylebox("panel", "Tree", _empty(Vector4(2, 2, 2, 2)))
	th.set_stylebox("focus", "Tree", _empty())
	th.set_stylebox("selected", "Tree", _sb(Color(accent, 0.18), 6))
	th.set_stylebox("selected_focus", "Tree", _sb(Color(accent, 0.22), 6))
	th.set_stylebox("hovered", "Tree", _sb(s3, 6))
	th.set_stylebox("hovered_selected", "Tree", _sb(Color(accent, 0.25), 6))
	th.set_stylebox("hovered_selected_focus", "Tree", _sb(Color(accent, 0.25), 6))
	th.set_stylebox("cursor", "Tree", _empty())
	th.set_stylebox("cursor_unfocused", "Tree", _empty())
	th.set_color("font_color", "Tree", text)
	th.set_color("font_hovered_color", "Tree", text)
	th.set_color("font_selected_color", "Tree", text)
	th.set_color("guide_color", "Tree", Color(0, 0, 0, 0))
	th.set_constant("draw_relationship_lines", "Tree", 0)
	th.set_constant("v_separation", "Tree", 4)
	th.set_constant("item_margin", "Tree", 14)

	# menus, tooltips, windows
	th.set_stylebox("panel", "PopupMenu", _sb(s2, rc, Vector4(6, 6, 6, 6), border, max(bw, 0), shadow))
	th.set_stylebox("hover", "PopupMenu", _sb(raised, max(rc - 2, 0)))
	th.set_color("font_color", "PopupMenu", text)
	th.set_color("font_hover_color", "PopupMenu", text)
	th.set_color("font_disabled_color", "PopupMenu", text3)
	th.set_constant("v_separation", "PopupMenu", 8)
	th.set_stylebox("panel", "TooltipPanel", _sb(raised, 6, Vector4(10, 6, 10, 6)))
	th.set_color("font_color", "TooltipLabel", text)
	var win := _sb(s1, r, Vector4(pad, pad, pad, pad), border, bw, shadow * 1.5)
	win.expand_margin_top = 30
	th.set_stylebox("embedded_border", "Window", win)
	th.set_stylebox("embedded_unfocused_border", "Window", win)
	th.set_color("title_color", "Window", text)
	th.set_font("title_font", "Window", font("ui", 600))
	th.set_constant("title_height", "Window", 30)
	th.set_stylebox("panel", "AcceptDialog", _sb(s1, 0, Vector4(pad, pad, pad, pad)))

	# scrollbars and sliders
	for type in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("scroll", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("scroll_focus", type, _empty(Vector4(4, 4, 4, 4)))
		th.set_stylebox("grabber", type, _sb(raised, 4))
		th.set_stylebox("grabber_highlight", type, _sb(Color(text2, 0.6), 4))
		th.set_stylebox("grabber_pressed", type, _sb(text2, 4))
	var track := _sb(s3, 2, Vector4(0, 2, 0, 2))
	var fill := _sb(accent, 2, Vector4(0, 2, 0, 2))
	var knob := _svg('<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14"><circle cx="7" cy="7" r="6" fill="#ffffff" stroke="%s" stroke-width="1.5"/></svg>' % _hex(accent))
	th.set_stylebox("slider", "HSlider", track)
	th.set_stylebox("grabber_area", "HSlider", fill)
	th.set_stylebox("grabber_area_highlight", "HSlider", fill)
	th.set_icon("grabber", "HSlider", knob)
	th.set_icon("grabber_highlight", "HSlider", knob)

	# separators
	for type in ["HSeparator", "VSeparator"]:
		var line := StyleBoxLine.new()
		line.color = Color(text3, 0.35) if bw == 0 else border
		line.vertical = type == "VSeparator"
		th.set_stylebox("separator", type, line)
		th.set_constant("separation", type, 12)

	# foldable groups (settings)
	var fold := Vector4(10, 7, 10, 7)
	th.set_stylebox("title_panel", "FoldableContainer", _sb(s2, rc, fold))
	th.set_stylebox("title_hover_panel", "FoldableContainer", _sb(s3, rc, fold))
	th.set_stylebox("title_collapsed_panel", "FoldableContainer", _sb(s2, rc, fold))
	th.set_stylebox("title_collapsed_hover_panel", "FoldableContainer", _sb(s3, rc, fold))
	th.set_stylebox("panel", "FoldableContainer", _empty(Vector4(4, 8, 4, 12)))
	th.set_stylebox("focus", "FoldableContainer", _empty())
	th.set_color("font_color", "FoldableContainer", text)
	th.set_color("collapsed_font_color", "FoldableContainer", text2)
	th.set_color("hover_font_color", "FoldableContainer", text)
	th.set_font("font", "FoldableContainer", font("ui", 600))
	th.set_icon("expanded_arrow", "FoldableContainer", _svg(chevron))
	th.set_icon("folded_arrow", "FoldableContainer", _svg('<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>' % _hex(text2)))
	th.set_icon("folded_arrow_mirrored", "FoldableContainer", _svg('<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="%s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg>' % _hex(text2)))

	# containers breathe with the theme
	th.set_constant("separation", "HBoxContainer", 8)
	th.set_constant("separation", "VBoxContainer", 8)
	th.set_constant("separation", "HSplitContainer", int(num("shape", "gap", 10)))
	th.set_stylebox("split_bar_background", "HSplitContainer", _empty(Vector4(0, 0, 0, 0)))
	return th
