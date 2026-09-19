shader_type canvas_item;

// Focus + context: darkens the map except where the mask is white (search
// hits, relation endpoints, the selection). Settings → Look → Focus dimming.

uniform sampler2D mask : filter_linear;
uniform float amount = 0.55;
uniform vec4 tint : source_color = vec4(0.07, 0.07, 0.08, 1.0);

void fragment() {
	float keep = texture(mask, UV).r;
	COLOR = vec4(tint.rgb, amount * (1.0 - keep));
}
