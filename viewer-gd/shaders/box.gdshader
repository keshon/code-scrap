shader_type canvas_item;
render_mode unshaded;

// One instance per box piece (a box clipped to a tile).
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth)
//   edge mask: 1 left, 2 top, 4 right, 8 bottom — the box's real edges
//   kind: 0 dir, 1 file, 2 scope (outline only)
// COLOR = the area's hue.

varying flat vec4 v_custom;
varying flat vec4 v_hue;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_hue = COLOR;
}

void fragment() {
	vec2 d = max(fwidth(UV), vec2(1e-7));
	vec2 near = UV / d;          // px to the left / top edge
	vec2 far = (1.0 - UV) / d;   // px to the right / bottom edge
	int edges = int(v_custom.x + 0.5);
	float e = 1e6;
	if ((edges & 1) != 0) e = min(e, near.x);
	if ((edges & 2) != 0) e = min(e, near.y);
	if ((edges & 4) != 0) e = min(e, far.x);
	if ((edges & 8) != 0) e = min(e, far.y);
	float true_px = v_custom.w / d.x;               // box's shorter side on screen
	float line = 1.0 - smoothstep(0.55, 1.45, e);   // ~1px outline
	float outline = line * smoothstep(3.0, 9.0, true_px);
	float big = smoothstep(8.0, 90.0, true_px);
	vec3 hue = v_hue.rgb;
	if (v_custom.y > 1.5) {
		COLOR = vec4(hue, outline * 0.5);
	} else {
		// tiny boxes read as solid color cells; big ones as dark rooms
		vec3 fill = hue * mix(0.5, 0.085, big);
		COLOR = vec4(mix(fill, hue * 0.95, outline), 1.0);
	}
}
