// Scope outlines inside files, styled by kind (Settings → Scope outlines):
// functions get a solid rounded line, classes / types / namespaces a dashed
// one, and each nesting level inside the file is a little fainter.
//
// Box custom data for scopes: kind = 2 + scope kind / 10 (0 block, 1 func,
// 2 type, 3 namespace), depth = nesting inside the file.

global uniform float scrap_scope_opacity;
global uniform float scrap_scope_fill;   // 0 outlines only · 1 filled bodies
global uniform float scrap_scope_radius;      // physical px
global uniform float scrap_scope_dash;        // 1 = dashed containers
global uniform float scrap_scope_fade;
global uniform float scrap_scope_funcs;       // 1 = show functions
global uniform float scrap_scope_containers;  // 1 = show classes, types, namespaces

// Coverage (0..1) of a scope's outline at this pixel. near / far: pixels to
// the left/top and right/bottom edges of the piece; edges: which of them are
// the scope's real edges (1 left, 2 top, 4 right, 8 bottom); w: line width.
float scope_outline(vec2 near, vec2 far, int edges, vec2 frag, float kind, float depth, float w) {
	float sk = floor((kind - 2.0) * 10.0 + 0.5);
	bool container = sk > 1.5;
	if ((container && scrap_scope_containers < 0.5) || (!container && scrap_scope_funcs < 0.5)) {
		return 0.0;
	}
	float ex = 1e6;
	float ey = 1e6;
	if ((edges & 1) != 0) ex = min(ex, near.x);
	if ((edges & 4) != 0) ex = min(ex, far.x);
	if ((edges & 2) != 0) ey = min(ey, near.y);
	if ((edges & 8) != 0) ey = min(ey, far.y);
	// signed distance inward from a rounded rectangle outline
	float r = scrap_scope_radius;
	float dist = min(ex, ey);
	if (ex < r && ey < r) {
		dist = r - length(vec2(r - ex, r - ey));
	}
	float line = 1.0 - smoothstep(w * 0.5, w * 0.5 + 1.0, abs(dist - w * 0.5));
	if (container && scrap_scope_dash > 0.5) {
		// dash along the edge: 5 px on, 4 px off
		float along = ex < ey ? frag.y : frag.x;
		line *= step(fract(along / 9.0), 5.0 / 9.0);
	}
	return line * scrap_scope_opacity * pow(1.0 - scrap_scope_fade, depth);
}
