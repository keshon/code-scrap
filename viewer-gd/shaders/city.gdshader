shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// One instance per box piece, extruded from the ground to its roof.
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth) — as in 2D.
// COLOR = the area's hue. Kind 2 (code scopes) draws only an outline on the
// roof of its file; the code itself is a separate GPU text layer.

uniform float tile_scale = 1.0;   // render units per tile edge
uniform float level = 0.0;        // tile zoom level
uniform vec3 light_dir = vec3(0.45, 0.8, 0.3);

varying flat vec4 v_custom;
varying flat vec4 v_hue;
varying vec3 v_tile;      // tile-local position (x, height, z), tile edge = 1
varying vec3 v_wnormal;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_hue = COLOR;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (VERTEX.y > 0.5) {
		// Roofs are lifted toward the viewer by a fraction of the distance,
		// ordering coplanar layers without z-fighting: finer tile levels over
		// a coarse fallback tile (≤0.05%), scope outlines (0.07%), then the
		// text layer (0.12%, in text3d.gdshader).
		float k = INSTANCE_CUSTOM.y > 1.5 ? 7e-4 : 2e-5 * level;
		float lift = distance(wp, CAMERA_POSITION_WORLD) * k;
		wp.y += lift;
		VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
	}
	v_tile = (wp - NODE_POSITION_WORLD) / tile_scale;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 hue = v_hue.rgb;
	float kind = v_custom.y;
	bool roof = v_wnormal.y > 0.5;
	if (kind > 1.5 && !roof) {
		discard;
	}
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
		if (kind > 1.5) {
			if (line < 0.35) {
				discard;
			}
			c = hue * 0.8;
		} else {
			vec3 base = kind > 0.5 ? mix(hue * 0.45, vec3(0.055, 0.058, 0.07), big)
			                       : hue * mix(0.5, 0.2, big);
			c = mix(base, hue, line * 0.9);
		}
	} else {
		float lambert = max(dot(v_wnormal, normalize(light_dir)), 0.0);
		c = hue * (0.42 + 0.45 * lambert);
		// thin darker rim just below the roof edge
		float rim = 1.0 - smoothstep(0.0, 1.5, (1.0 - UV.y) / max(d.y, 1e-7));
		c = mix(c, hue * 0.25, rim * 0.6);
	}
	ALBEDO = c;
}
