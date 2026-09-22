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
	// roofs seen nearly edge-on: the text is unreadable there and only
	// adds noise, so it fades out. Roofs always face world up; the mesh
	// normal is not trusted (a missing one made a band under the camera).
	vec3 up = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	c *= smoothstep(0.08, 0.3, abs(dot(up, VIEW)));
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
