shader_type canvas_item;
render_mode unshaded;

// One instance per box piece (a box clipped to a tile).
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth)
//   edge mask: 1 left, 2 top, 4 right, 8 bottom — the box's real edges
//   kind: 0 dir, 1 file, 2 scope (outline only)
// COLOR = the area's hue.
//
// Outlines are pixel-exact: each edge snaps to the nearest pixel boundary
// and covers exactly scrap_line_px pixels inward, so every line has the same
// weight wherever the box falls (Settings → Lines).

global uniform float scrap_line_px;       // outline width, physical px
global uniform float scrap_line_min_box;  // boxes smaller than this: no outline
global uniform float scrap_depth_tone;    // fills lighten with nesting depth
global uniform float scrap_roof_tone;     // files: lift behind the code text

#include "res://shaders/scope_outline.gdshaderinc"

varying flat vec4 v_custom;
varying flat vec4 v_hue;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_hue = COLOR;
}

// 1 when the pixel is within w px inside an edge at screen position edge
// (edge snapped to a pixel boundary); dir = +1 for left/top, -1 right/bottom.
float edge_cover(float frag, float edge, float dir, float w) {
	float s = (frag - round(edge)) * dir;  // pixel center distance inward
	return step(0.0, s) * step(s, w);
}

void fragment() {
	vec2 d = max(fwidth(UV), vec2(1e-7));
	vec2 near = UV / d;          // px to the left / top edge
	vec2 far = (1.0 - UV) / d;   // px to the right / bottom edge
	vec2 fc = FRAGCOORD.xy;
	float w = max(scrap_line_px, 1.0);
	int edges = int(v_custom.x + 0.5);
	float line = 0.0;
	if ((edges & 1) != 0) line = max(line, edge_cover(fc.x, fc.x - near.x, 1.0, w));
	if ((edges & 2) != 0) line = max(line, edge_cover(fc.y, fc.y - near.y, 1.0, w));
	if ((edges & 4) != 0) line = max(line, edge_cover(fc.x, fc.x + far.x, -1.0, w));
	if ((edges & 8) != 0) line = max(line, edge_cover(fc.y, fc.y + far.y, -1.0, w));
	float true_px = v_custom.w / d.x;               // box's shorter side on screen
	float outline = line * smoothstep(scrap_line_min_box * 0.5, scrap_line_min_box, true_px);
	float big = smoothstep(8.0, 90.0, true_px);
	vec3 hue = v_hue.rgb;
	if (v_custom.y > 1.5) {
		float a = scope_outline(near, far, edges, fc, v_custom.y, v_custom.z, w)
			* smoothstep(scrap_line_min_box * 0.5, scrap_line_min_box, true_px);
		COLOR = vec4(hue, a);
	} else {
		// tiny boxes read as solid color cells; big ones as dark rooms that
		// get a little lighter with each nesting level
		float tone = 1.0 + scrap_depth_tone * min(v_custom.z, 8.0) * 0.18;
		vec3 fill = hue * mix(0.5, 0.085 * tone, big);
		if (v_custom.y > 0.5) {
			fill += vec3(scrap_roof_tone) * big;
		}
		COLOR = vec4(mix(fill, hue * 0.95, outline), 1.0);
	}
}
