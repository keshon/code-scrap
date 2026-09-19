shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, blend_mix;

// Box outline drawn through everything: every face shows its four edges,
// so the selection's full 3D shape stays visible behind other buildings.

uniform vec4 color : source_color = vec4(0.35, 0.65, 1.0, 1.0);
uniform float width_px = 2.0;
uniform float face_alpha = 0.05;

void fragment() {
	vec2 d = max(fwidth(UV), vec2(1e-7));
	vec2 e2 = min(UV, 1.0 - UV) / d;
	float e = min(e2.x, e2.y);
	float line = 1.0 - smoothstep(width_px - 0.5, width_px + 0.5, e);
	ALBEDO = color.rgb;
	ALPHA = max(line * color.a, face_alpha);
}
