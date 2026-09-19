shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// One instance per box piece, extruded from the ground to its roof.
// INSTANCE_CUSTOM = (edge mask, kind, depth, trueMin / pieceWidth) — as in 2D.
// COLOR = the area's hue. Kind 2 (code scopes) draws only an outline on the
// roof of its file; the code itself is a separate GPU text layer.
//
// Shading is done here rather than by Godot's lights, so it stays cheap and
// tunable (Settings → Look): ambient + one light (a headlight that follows
// the camera, or a fixed sun), specular highlights, contact shading toward
// the base. Roofs keep their tone (the code is printed there) and can be
// kept free of specular.

uniform float tile_scale = 1.0;   // render units per tile edge
uniform float level = 0.0;        // tile zoom level
global uniform float scrap_line_px;       // outline width, physical px
global uniform float scrap_line_min_box;  // boxes smaller than this: no outline
global uniform float scrap_roof_tone;
global uniform vec3 scrap_light_dir;      // toward the light (view space in camera mode)
global uniform float scrap_light_space;   // 0 camera (headlight), 1 world (sun)
global uniform float scrap_light_strength;
global uniform float scrap_ambient;
global uniform float scrap_specular;
global uniform float scrap_gloss;
global uniform float scrap_roof_diffuse;  // 0 all roofs, 1 selected only, 2 none
global uniform float scrap_contact;
global uniform float scrap_flat;          // 1 = no shading
// selection and hover, in render space: box (x, z, w, h), roof height, tint
global uniform vec4 scrap_sel_box;
global uniform float scrap_sel_top;
global uniform vec4 scrap_sel_tint;       // rgb + strength (0 = off)
global uniform vec4 scrap_hov_box;
global uniform float scrap_hov_top;
global uniform vec4 scrap_hov_tint;

#include "res://shaders/scope_outline.gdshaderinc"

varying flat vec4 v_custom;
varying flat vec4 v_hue;
varying flat vec4 v_dims;     // box size x, z (render units)
varying flat float v_sel;     // 1 = this piece belongs to the selected box
varying flat float v_hov;
varying vec3 v_local;         // position in the piece: x, z in render units, y = height 0..1
varying vec3 v_wnormal;
varying vec3 v_wpos;
varying float v_ring;

// Is the piece (origin o, size s) part of box b with roof height top?
float matches(vec3 o, vec3 s, vec4 b, float top) {
	if (b.z <= 0.0) {
		return 0.0;
	}
	float e = max(b.z, b.w) * 1e-4;
	bool inside = o.x >= b.x - e && o.z >= b.y - e && o.x + s.x <= b.x + b.z + e && o.z + s.z <= b.y + b.w + e;
	return inside && abs(o.y + s.y - top) <= max(s.y, top) * 2e-3 + e ? 1.0 : 0.0;
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_hue = COLOR;
	vec3 size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec3 origin = MODEL_MATRIX[3].xyz;
	bool scope = INSTANCE_CUSTOM.y > 1.5;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (VERTEX.y > 0.5) {
		// Roofs are lifted toward the viewer by a fraction of the distance,
		// ordering coplanar layers without z-fighting: finer tile levels over
		// a coarse fallback tile (≤0.05%), scope outlines (0.07%), then the
		// text layer (0.12%, in text3d.gdshader).
		float k = scope ? 7e-4 : 2e-5 * level;
		wp.y += distance(wp, CAMERA_POSITION_WORLD) * k;
		VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
	}
	v_local = vec3(VERTEX.x * size.x, VERTEX.z * size.z, VERTEX.y);
	v_dims = vec4(size.x, size.z, 0.0, 0.0);
	v_wnormal = NORMAL;   // the cube is axis aligned and not rotated
	v_wpos = wp;
	v_ring = NORMAL.y > 0.5 ? 2.0 : 0.0;
	v_sel = scope ? 0.0 : matches(origin, size, scrap_sel_box, scrap_sel_top);
	v_hov = scope ? 0.0 : matches(origin, size, scrap_hov_box, scrap_hov_top);
}

// diffuse light on a face (1 = unchanged albedo)
float diffuse(vec3 n, vec3 l) {
	if (scrap_flat > 0.5) {
		return 1.0;
	}
	float lit = scrap_ambient + (1.0 - scrap_ambient) * max(dot(n, l), 0.0);
	float avg = scrap_ambient + (1.0 - scrap_ambient) * 0.6;
	return mix(1.0, lit / avg, scrap_light_strength);
}

float specular(vec3 n, vec3 l, vec3 v) {
	if (scrap_flat > 0.5 || scrap_specular <= 0.0) {
		return 0.0;
	}
	return scrap_specular * pow(max(dot(n, normalize(l + v)), 0.0), scrap_gloss);
}

void fragment() {
	vec3 hue = v_hue.rgb;
	float kind = v_custom.y;
	bool roof = v_ring > 1.5;
	if (kind > 1.5 && !roof) {
		discard;
	}
	vec3 l = scrap_light_space < 0.5 ? normalize((INV_VIEW_MATRIX * vec4(scrap_light_dir, 0.0)).xyz)
	                                 : normalize(scrap_light_dir);
	vec3 v = normalize(CAMERA_POSITION_WORLD - v_wpos);
	vec3 n = normalize(v_wnormal);
	vec3 c;
	float spec = 0.0;
	if (roof) {
		int edges = int(v_custom.x + 0.5);
		vec2 p = v_local.xy;                        // render units in the piece
		vec2 pw = max(fwidth(p), vec2(1e-9));       // render units per pixel
		float true_px = min(v_dims.x / pw.x, v_dims.y / pw.y);
		float show = smoothstep(scrap_line_min_box * 0.5, scrap_line_min_box, true_px);
		float w = max(scrap_line_px, 1.0);
		if (kind > 1.5) {
			vec2 near = p / pw;
			vec2 far = (v_dims.xy - p) / pw;
			float a = scope_outline(near, far, edges, FRAGCOORD.xy, kind, v_custom.z, w) * show;
			if (a < 0.2) {
				discard;
			}
			c = hue * 0.8;
		} else {
			// distance to the roof's real edges, in pixels
			float big_ = 1e9;
			float dl = (edges & 1) != 0 ? p.x : big_;
			float dr = (edges & 4) != 0 ? v_dims.x - p.x : big_;
			float dt = (edges & 2) != 0 ? p.y : big_;
			float db = (edges & 8) != 0 ? v_dims.y - p.y : big_;
			float dx = min(dl, dr);
			float dz = min(dt, db);
			float d = min(dx / pw.x, dz / pw.y);
			float line = (1.0 - smoothstep(w - 0.45, w + 0.45, d)) * show;
			float big = smoothstep(8.0, 90.0, true_px);
			// 3D colors are linear: the same lift looks ~4x stronger than in 2D
			vec3 base = kind > 0.5 ? mix(hue * 0.45, vec3(0.055, 0.058, 0.07) + scrap_roof_tone * 0.25, big)
			                       : hue * mix(0.5, 0.2, big);
			c = mix(base, hue, line * 0.9);
			bool diffuse_only = scrap_roof_diffuse < 0.5 || (scrap_roof_diffuse < 1.5 && v_sel > 0.5);
			if (!diffuse_only) {
				spec = specular(n, l, v);
			}
		}
	} else {
		c = hue * 0.55 * diffuse(n, l);
		// contact shading: darker toward the base
		c *= mix(1.0 - scrap_contact, 1.0, smoothstep(0.0, 0.45, v_local.z));
		spec = specular(n, l, v);
	}
	c += vec3(spec);
	// selection / hover tint: the whole box glows
	if (v_sel > 0.5 && scrap_sel_tint.a > 0.0) {
		c = mix(c, scrap_sel_tint.rgb, scrap_sel_tint.a * (roof ? 0.6 : 1.0));
	} else if (v_hov > 0.5 && scrap_hov_tint.a > 0.0) {
		c = mix(c, scrap_hov_tint.rgb, scrap_hov_tint.a * (roof ? 0.5 : 0.8));
	}
	ALBEDO = c;
}
