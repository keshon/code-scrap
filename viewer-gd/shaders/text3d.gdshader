shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/code_text.gdshaderinc"

void vertex() {
	// lie on the roof: lift a hair toward the viewer (scaled with distance)
	// so the text never z-fights with the roof it's printed on
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wp.y += distance(wp, CAMERA_POSITION_WORLD) * 0.0012;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
}

void fragment() {
	vec4 c = code_text(UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
