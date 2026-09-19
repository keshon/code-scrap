shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Dotted ground plane under the city; dots keep a steady screen density
// by switching spacing with the camera distance, and fade toward the
// horizon (Settings → ☰ Ground grid).

uniform float spacing = 1.0;      // render units between dots
uniform vec3 center;              // fade centre (render space)
uniform float radius = 100.0;     // fade radius (render units)
uniform vec4 dot_color : source_color = vec4(1.0, 1.0, 1.0, 0.1);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz / spacing;
	vec2 fw = max(fwidth(p), vec2(1e-6));
	vec2 f = abs(fract(p + 0.5) - 0.5) / fw;   // px to the nearest dot
	float a = 1.0 - smoothstep(0.8, 1.6, length(f));
	a *= 1.0 - smoothstep(radius * 0.3, radius, distance(v_world.xz, center.xz));
	a *= smoothstep(0.02, 0.2, 1.0 / max(fw.x, 1e-6) / 6.0);  // hide when dots would merge
	ALBEDO = dot_color.rgb;
	ALPHA = dot_color.a * a;
}
