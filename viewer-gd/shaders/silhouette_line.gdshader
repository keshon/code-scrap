shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
stencil_mode read, compare_not_equal, 1;

// Silhouette selection, pass 2: the box grown by width_px on screen, drawn
// only outside the stencil mark of pass 1, so what remains is a band of
// constant width around the box's silhouette, with no inner edges.

uniform vec4 color : source_color = vec4(0.35, 0.65, 1.0, 1.0);
uniform float width_px = 2.0;
uniform float px_size = 0.001;   // render units per pixel at distance 1

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 center = (MODEL_MATRIX * vec4(0.5, 0.5, 0.5, 1.0)).xyz;
	// grow along the corner direction, by a constant number of pixels
	vec3 dir = normalize(wp - center);
	wp += dir * width_px * px_size * distance(wp, CAMERA_POSITION_WORLD) * 1.4;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
