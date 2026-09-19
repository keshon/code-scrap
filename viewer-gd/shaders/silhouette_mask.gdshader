shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
stencil_mode write, compare_always, 1;

// Silhouette selection, pass 1: marks the pixels of the highlighted box in
// the stencil buffer (drawing nothing visible). Pass 2
// (silhouette_line.gdshader) draws a slightly bigger box only where this
// mark is absent, which leaves one clean outline around the whole shape.
// The reference value is set per material (selection 1, hover 2).

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
