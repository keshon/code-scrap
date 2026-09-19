shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Box outline drawn where the box is visible (depth tested): the "outline"
// selection / hover style. The x-ray variant (highlight_xray.gdshader) draws
// the same edges through everything.

uniform vec4 color : source_color = vec4(0.35, 0.65, 1.0, 1.0);
uniform float width_px = 2.0;

void vertex() {
	// pull toward the viewer a touch so the edges win over the box itself
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wp += normalize(CAMERA_POSITION_WORLD - wp) * distance(wp, CAMERA_POSITION_WORLD) * 0.002;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	vec2 d = max(fwidth(UV), vec2(1e-7));
	vec2 e2 = min(UV, 1.0 - UV) / d;
	float e = min(e2.x, e2.y);
	float line = 1.0 - smoothstep(width_px - 0.5, width_px + 0.5, e);
	if (line < 0.01) {
		discard;
	}
	ALBEDO = color.rgb;
	ALPHA = line * color.a;
}
