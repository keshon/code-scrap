shader_type sky;

// Background of the 3D city: the theme's background with a faint glow at
// the horizon, so the ground plane has somewhere to go.

uniform vec4 top_color : source_color;
uniform vec4 horizon_color : source_color;

void sky() {
	float h = 1.0 - clamp(abs(EYEDIR.y), 0.0, 1.0);
	COLOR = mix(top_color.rgb, horizon_color.rgb, pow(h, 6.0));
}
