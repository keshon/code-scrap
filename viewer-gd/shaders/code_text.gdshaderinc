// GPU code text for one text block (a column of a file, up to 4096 lines).
// Shared by the 2D map and the 3D city.
//
//  color_tex  RGBA8, one texel per character: premultiplied syntax color,
//             alpha = "has a glyph". Mipmapped, so from afar it averages
//             into the dashed minimap look without any extra work.
//  glyph_tex  RG8, the atlas cell of each character (u16, little endian).
//  atlas_tex  L8 glyph coverage, atlas_grid cells.
//
// Close up, glyphs are drawn from the atlas; far away, dashes; in between
// the two crossfade by the on-screen line height, so nothing pops.

uniform sampler2D color_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D glyph_tex : filter_nearest, repeat_disable;
uniform sampler2D atlas_tex : filter_linear_mipmap_anisotropic, repeat_disable;
// tunables shared by every text material (Settings → Code text)
global uniform float scrap_glyph_from;
global uniform float scrap_glyph_full;
global uniform float scrap_text_weight;
global uniform float scrap_text_mode;   // 0 auto, 1 syntax, 2 mono
global uniform vec4 scrap_text_mono;
uniform float rows = 1.0;
uniform float col_chars = 100.0;
uniform float tex_w = 128.0;
uniform vec2 atlas_grid = vec2(32.0, 14.0);
uniform float fade = 1.0;  // block fade in/out (premultiplied: scales all)

vec4 code_text(vec2 uv) {
	vec2 p = vec2(uv.x * col_chars, uv.y * rows);  // (character, line)
	vec2 dp = max(fwidth(p), vec2(1e-6));
	float line_px = 1.0 / dp.y;

	// dashes: the mipmapped color texture, barred vertically while lines are
	// a few pixels tall so they read as separate lines
	// one blur level for both directions: the GPU's anisotropic choice
	// changes with the viewing angle and makes far text blotchy, so the
	// same patch would look different from every side
	vec2 uv_d = vec2(p.x / tex_w, p.y / rows);
	float g = max(max(abs(dFdx(uv_d).x), abs(dFdy(uv_d).x)), max(abs(dFdx(uv_d).y), abs(dFdy(uv_d).y)));
	vec4 dash = textureGrad(color_tex, uv_d, vec2(g, 0.0), vec2(0.0, g));
	float fy = fract(p.y);
	float aa = min(dp.y, 0.5);
	float bar = smoothstep(0.2 - aa, 0.2 + aa, fy) * (1.0 - smoothstep(0.8 - aa, 0.8 + aa, fy));
	bar = mix(0.6, bar, smoothstep(1.5, 3.0, line_px));
	dash *= bar * 0.85;

	float t = smoothstep(scrap_glyph_from, max(scrap_glyph_full, scrap_glyph_from + 0.01), line_px);
	vec4 glyph = vec4(0.0);
	if (t > 0.0 && p.x < col_chars && p.y < rows) {
		ivec2 cell = ivec2(floor(p));
		vec2 gi = texelFetch(glyph_tex, cell, 0).rg * 255.0;
		float idx = floor(gi.x + 0.5) + floor(gi.y + 0.5) * 256.0;
		if (idx > 0.5) {
			vec2 cpos = vec2(mod(idx, atlas_grid.x), floor(idx / atlas_grid.x));
			vec2 g = 1.0 / atlas_grid;
			// gradients of the continuous position keep mip selection smooth
			// across cell boundaries
			float cov = textureGrad(atlas_tex, (cpos + fract(p)) * g, dFdx(p) * g, dFdy(p) * g).r;
			vec4 c = texelFetch(color_tex, cell, 0);
			cov = pow(cov, scrap_text_weight);  // small text reads thin without a slight boost
			glyph = vec4(c.rgb, 1.0) * cov;
		}
	}
	vec4 c = mix(dash, glyph, t);
	// mono: one calm tone; auto: mono while it is dashes, syntax once readable
	float mono = scrap_text_mode > 1.5 ? 1.0 : (scrap_text_mode < 0.5 ? 1.0 - t : 0.0);
	c.rgb = mix(c.rgb, scrap_text_mono.rgb * c.a, mono);
	return c * fade;
}
