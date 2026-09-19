shader_type canvas_item;
render_mode blend_premul_alpha;

#include "res://shaders/code_text.gdshaderinc"

void fragment() {
	COLOR = code_text(UV);
}
