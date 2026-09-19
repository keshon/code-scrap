class_name ViewCommon
## Pieces shared by the flat map and the 3D city: tile fallback while tiles
## stream in, and label placement.


## Covers a missing tile with what is loaded: the nearest ancestor (moving
## closer), else its children one or two levels down (moving away), so the
## view never shows holes while the right level streams in.
static func tile_fallback(tiles: Dictionary, key: Vector3i, shown: Dictionary) -> void:
	for up in range(1, 6):
		if key.x - up < 0:
			break
		var ak := Vector3i(key.x - up, key.y >> up, key.z >> up)
		if tiles.has(ak):
			shown[ak] = tiles[ak]
			return
	for down in [1, 2]:
		var n: int = 1 << down
		var found := false
		for j in n:
			for i in n:
				var ck := Vector3i(key.x + down, key.y * n + i, key.z * n + j)
				if tiles.has(ck):
					shown[ck] = tiles[ck]
					found = true
		if found:
			return


## Label placement. Each candidate: {prio (on-screen size), kind (0 dir,
## 1 file, 2 scope), color, pos (top-left), max_w, size, text}, optionally
## center (pos is the top-centre) and alts (fallback positions tried when
## pos collides, e.g. just below a folder tab). Directories win over files
## over scopes, then bigger boxes win; a label that fits nowhere is dropped.
## Returns [{c, text, rect, font}] in placement order.
static func place_labels(cand: Array, budget: int) -> Array:
	cand.sort_custom(func(a, b):
		if a.kind != b.kind:
			return a.kind < b.kind
		return a.prio > b.prio)
	var gap: float = Settings.get_value("labels.gap")
	var bold := Style.font("ui", 600)
	var regular := Style.font("ui", 500)
	var placed := []
	var rects: Array[Rect2] = []
	for c in cand:
		if placed.size() >= budget:
			break
		var fs: int = c.size
		var font: Font = bold if c.kind == 0 else regular
		var text: String = c.text
		var max_w: float = c.max_w
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if tw > max_w:
			var keep := int(text.length() * max_w / tw) - 1
			if keep < 3:
				continue
			text = text.substr(0, keep) + "…"
			tw = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pad := 14.0 if c.kind != 2 else 8.0   # dir stripe / file chip / scope gap
		var sz := Vector2(tw + pad, fs + 5.0)
		var r := Rect2()
		var ok := false
		for spot in [c.pos] + c.get("alts", []):
			r = Rect2(spot - Vector2(sz.x * 0.5, 0) if c.get("center", false) else spot, sz)
			ok = true
			for p in rects:
				if p.grow(gap).intersects(r):
					ok = false
					break
			if ok:
				break
		if not ok:
			continue
		rects.append(r)
		placed.append({"c": c, "text": text, "rect": r, "font": font})
	return placed


## Draws placed labels in their kind's style:
##   dir    a tab in the area's hue: tinted fill, bright stripe, bold name
##   file   quiet: dark fill, extension chip, secondary text
##   scope  a legend cut into the scope's border: knocked-out gap, hue text
static func draw_labels(o: CanvasItem, placed: Array) -> void:
	var bg := Style.color("bg")
	var text2 := Style.color("text2")
	for p in placed:
		var c: Dictionary = p.c
		var r: Rect2 = p.rect
		var fs: int = c.size
		var font: Font = p.font
		var col: Color = c.get("color", text2)
		var base := r.position + Vector2(0, fs * 0.95 + 1.5)
		match int(c.kind):
			0:
				o.draw_rect(r, Color(bg.lerp(col, 0.28), 0.94))
				o.draw_rect(Rect2(r.position, Vector2(3, r.size.y)), col)
				o.draw_string(font, base + Vector2(8, 0), p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col.lerp(Color.WHITE, 0.55))
			1:
				o.draw_rect(r, Color(bg, 0.82))
				var chip := Rect2(r.position + Vector2(4, r.size.y * 0.5 - 3), Vector2(6, 6))
				o.draw_rect(chip, ext_color(c.text))
				o.draw_string(font, base + Vector2(13, 0), p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, text2)
			_:
				o.draw_rect(r, Color(bg, 0.9))
				o.draw_string(font, base + Vector2(4, 0), p.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## A stable color per file extension (the chip on file labels).
static func ext_color(name: String) -> Color:
	var ext := name.get_extension().to_lower()
	if ext == "":
		return Color(0.5, 0.52, 0.56)
	return Color.from_hsv(float(ext.hash() % 360) / 360.0, 0.5, 0.92)
