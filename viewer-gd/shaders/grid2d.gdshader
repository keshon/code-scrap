shader_type canvas_item;

// Dotted ground behind the flat map, fixed to world coordinates so it pans
// and zooms with the map (Settings → ☰ Ground grid).

uniform vec2 origin;          // screen position of a grid point (px)
uniform float spacing = 32.0; // px between dots
uniform float fade = 1.0;     // 0..1 as spacing changes level
uniform vec4 dot_color : source_color = vec4(1.0, 1.0, 1.0, 0.12);

void fragment() {
	vec2 p = (FRAGCOORD.xy - origin) / spacing;
	vec2 f = abs(fract(p + 0.5) - 0.5) * spacing;   // px to the nearest dot
	float d = length(f);
	float a = 1.0 - smoothstep(0.6, 1.4, d);
	COLOR = vec4(dot_color.rgb, dot_color.a * a * fade);
}
