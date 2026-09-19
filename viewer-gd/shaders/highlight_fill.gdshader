shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_mix;

// Tint on the visible surfaces of the selected box (depth tested, so it
// only colors what you can actually see of it).

uniform vec4 color : source_color = vec4(0.3, 0.55, 1.0, 0.38);

void vertex() {
	// pull toward the viewer a touch so the tint wins over the box itself
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wp += normalize(CAMERA_POSITION_WORLD - wp) * distance(wp, CAMERA_POSITION_WORLD) * 0.002;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
