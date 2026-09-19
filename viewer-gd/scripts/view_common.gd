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


## Draws label pills, most important first, skipping any that would overlap
## one already placed. Each candidate: {prio, pos (top-left), max_w, text,
## size}. Returns how many were drawn.
static func draw_labels(o: CanvasItem, font: Font, cand: Array, budget: int) -> int:
	cand.sort_custom(func(a, b): return a.prio > b.prio)
	var pill_c := Color(Style.color("bg"), 0.86)
	var text_c := Style.color("text")
	var placed: Array[Rect2] = []
	for c in cand:
		if placed.size() >= budget:
			break
		var fs: int = c.size
		var text: String = c.text
		var max_w: float = c.max_w
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if tw > max_w:
			var keep := int(text.length() * max_w / tw) - 1
			if keep < 3:
				continue
			text = text.substr(0, keep) + "…"
			tw = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos: Vector2 = c.pos
		var pill := Rect2(pos, Vector2(tw + 6.0, fs + 4.0))
		var hit := false
		for p in placed:
			if p.intersects(pill):
				hit = true
				break
		if hit:
			continue
		placed.append(pill)
		o.draw_rect(pill, pill_c)
		o.draw_string(font, pos + Vector2(3.0, fs * 0.95 + 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, text_c)
	return placed.size()
