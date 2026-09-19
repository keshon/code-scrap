shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// One instance per box piece, extruded from the ground to its roof.
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth) — as in 2D.
// COLOR = the area's hue. Kind 2 (code scopes) draws only an outline on the
// roof of its file; the code itself is a separate GPU text layer.
//
// Shading is done here rather than by Godot's lights, so it stays cheap and
// tunable (Settings → Look): one directional light for walls, chamfered roof
// edges (bevels) that catch or lose that light, and contact shading that
// darkens walls toward their base so terraces read.

uniform float tile_scale = 1.0;   // render units per tile edge
uniform float level = 0.0;        // tile zoom level
global uniform float scrap_line_px;       // outline width, physical px
global uniform float scrap_line_min_box;  // boxes smaller than this: no outline
global uniform float scrap_roof_tone;
global uniform vec3 scrap_light_dir;      // toward the light
global uniform float scrap_light_strength;
global uniform float scrap_bevel;         // chamfer size / box's shorter side
global uniform float scrap_contact;
global uniform float scrap_flat;          // 1 = no shading

#include "res://shaders/scope_outline.gdshaderinc"

varying flat vec4 v_custom;
varying flat vec4 v_hue;
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
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Lambert term scaled by the light strength (1 = unlit look).
float shade(vec3 n) {
	if (scrap_flat > 0.5) {
		return 1.0;
	}
	float l = max(dot(normalize(n), normalize(scrap_light_dir)), 0.0);
	return mix(1.0, 0.55 + 0.9 * l, scrap_light_strength);
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
		float true_px = v_custom.w / d.x;
		float show = smoothstep(scrap_line_min_box * 0.5, scrap_line_min_box, true_px);
		float w = max(scrap_line_px, 1.0);
		if (kind > 1.5) {
			float a = scope_outline(near, far, edges, FRAGCOORD.xy, kind, v_custom.z, w) * show;
			if (a < 0.2) {
				discard;
			}
			c = hue * 0.8;
		} else {
			float ex = 1e6;
			float ey = 1e6;
			vec3 nx = vec3(0.0);
			vec3 nz = vec3(0.0);
			if ((edges & 1) != 0 && near.x < ex) { ex = near.x; nx = vec3(-1.0, 0.0, 0.0); }
			if ((edges & 4) != 0 && far.x < ex) { ex = far.x; nx = vec3(1.0, 0.0, 0.0); }
			if ((edges & 2) != 0 && near.y < ey) { ey = near.y; nz = vec3(0.0, 0.0, -1.0); }
			if ((edges & 8) != 0 && far.y < ey) { ey = far.y; nz = vec3(0.0, 0.0, 1.0); }
			float e = min(ex, ey);
			// perspective lines cannot snap to pixels: a 1 px antialiased ramp
			float line = (1.0 - smoothstep(w - 0.45, w + 0.45, e)) * show;
			float big = smoothstep(8.0, 90.0, true_px);
			// 3D colors are linear: the same lift looks ~4x stronger than in 2D
			vec3 base = kind > 0.5 ? mix(hue * 0.45, vec3(0.055, 0.058, 0.07) + scrap_roof_tone * 0.25, big)
			                       : hue * mix(0.5, 0.2, big);
			// bevel: the band along the edges tilts toward them
			float bevel_px = true_px * scrap_bevel;
			vec3 n = vec3(0.0, 1.0, 0.0);
			if (bevel_px > 1.5 && e < bevel_px) {
				vec3 side = ex < ey ? nx : nz;
				if (ex < bevel_px && ey < bevel_px) {
					side = normalize(nx + nz);
				}
				n = normalize(vec3(0.0, 1.0, 0.0) + side);
			}
			base *= shade(n) / shade(vec3(0.0, 1.0, 0.0));  // flat roofs keep their tone
			c = mix(base, hue, line * 0.9);
		}
	} else {
		c = hue * 0.55 * shade(v_wnormal);
		// contact shading: darker toward the base
		c *= mix(1.0 - scrap_contact, 1.0, smoothstep(0.0, 0.45, UV.y));
		// thin darker rim just below the roof edge
		float rim = 1.0 - smoothstep(0.0, 1.5, (1.0 - UV.y) / max(d.y, 1e-7));
		c = mix(c, hue * 0.25, rim * 0.6);
	}
	ALBEDO = c;
}
