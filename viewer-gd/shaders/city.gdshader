shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// One instance per box piece, extruded from the ground to its roof.
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth) — as in 2D.
// COLOR = the area's hue. The tile's code raster is projected onto roofs.

uniform sampler2D code_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_code = false;
uniform float tile_scale = 1.0;   // render units per tile edge
uniform vec3 light_dir = vec3(0.45, 0.8, 0.3);

varying flat vec4 v_custom;
varying flat vec4 v_hue;
varying vec3 v_tile;      // tile-local position (x, height, z), tile edge = 1
varying vec3 v_wnormal;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_hue = COLOR;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_tile = (wp - NODE_POSITION_WORLD) / tile_scale;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 hue = v_hue.rgb;
	float kind = v_custom.y;
	bool roof = v_wnormal.y > 0.5;
	vec2 d = max(fwidth(UV), vec2(1e-7));
	vec3 c;
	if (roof) {
		// roof outline on the box's real edges (same bitmask as 2D)
		vec2 near = UV / d;
		vec2 far = (1.0 - UV) / d;
		int edges = int(v_custom.x + 0.5);
		float e = 1e6;
		if ((edges & 1) != 0) e = min(e, near.x);
		if ((edges & 2) != 0) e = min(e, near.y);
		if ((edges & 4) != 0) e = min(e, far.x);
		if ((edges & 8) != 0) e = min(e, far.y);
		float true_px = v_custom.w / d.x;
		float line = (1.0 - smoothstep(0.55, 1.45, e)) * smoothstep(3.0, 9.0, true_px);
		float big = smoothstep(8.0, 90.0, true_px);
		vec3 base = kind > 0.5 ? mix(hue * 0.45, vec3(0.055, 0.058, 0.07), big)
		                       : hue * mix(0.5, 0.2, big);
		if (has_code && kind > 0.5) {
			vec4 code = texture(code_tex, v_tile.xz);
			base = code.rgb + base * (1.0 - code.a);   // premultiplied
		}
		c = mix(base, hue, line * 0.9);
	} else {
		float lambert = max(dot(v_wnormal, normalize(light_dir)), 0.0);
		c = hue * (0.42 + 0.45 * lambert);
		// thin darker rim just below the roof edge
		float rim = 1.0 - smoothstep(0.0, 1.5, (1.0 - UV.y) / max(d.y, 1e-7));
		c = mix(c, hue * 0.25, rim * 0.6);
	}
	ALBEDO = c;
}
