shader_type spatial;
render_mode world_vertex_coords;
// Terrain patch (05 §5). Every instance has the identity transform; the patch
// is placed from INSTANCE_CUSTOM = (corner x, corner z, size, level + 0.5 when
// drawn as a quadrant). Positions are formed in whole-sample units, so
// vertices shared by two patches are bit-identical. The morph uses the eye
// and lift of the last selection (not the live camera), like the selection.

uniform sampler2D height_tex : filter_nearest, repeat_disable;
uniform sampler2D normal_tex : filter_linear, repeat_disable;
uniform float sample_m = 2.0;
uniform float origin_offset = 0.0;
uniform float size_m = 1.0;
uniform float height_scale = 0.02;
uniform float height_offset = 0.0;
uniform float r0 = 160.0;
uniform float morph_start = 0.8;
uniform float base_quads = 32.0;
uniform vec3 eye = vec3(0.0);
uniform float lift = 0.0;

const float MESH_QUADS = 32.0;

float h_at(ivec2 t) {
	ivec2 last = textureSize(height_tex, 0) - ivec2(1);
	vec2 rg = texelFetch(height_tex, clamp(t, ivec2(0), last), 0).rg;
	return (rg.r * 255.0 + rg.g * 255.0 * 256.0) * height_scale - height_offset;
}

// Bilinear height at a position in sample units.
float height_at_idx(vec2 idx) {
	ivec2 i = ivec2(floor(idx));
	vec2 f = idx - vec2(i);
	float a = mix(h_at(i), h_at(i + ivec2(1, 0)), f.x);
	float b = mix(h_at(i + ivec2(0, 1)), h_at(i + ivec2(1, 1)), f.x);
	return mix(a, b, f.y);
}

void vertex() {
	vec2 origin_idx = round((INSTANCE_CUSTOM.xy + origin_offset) / sample_m);
	float level = floor(INSTANCE_CUSTOM.w);
	float quads = fract(INSTANCE_CUSTOM.w) > 0.25 ? base_quads * 0.5 : base_quads;
	float range = r0 * exp2(level);
	float step_idx = INSTANCE_CUSTOM.z / (quads * sample_m);
	vec2 g = floor(round(VERTEX.xz * MESH_QUADS) * (quads / MESH_QUADS));
	vec2 idx = origin_idx + g * step_idx;
	vec2 dxz = idx * sample_m - origin_offset - eye.xz;
	float d = sqrt(dot(dxz, dxz) + lift * lift);
	float k = clamp((d - morph_start * range) / ((1.0 - morph_start) * range), 0.0, 1.0);
	g -= fract(g * 0.5) * 2.0 * k;
	idx = origin_idx + g * step_idx;
	vec2 wxz = idx * sample_m - origin_offset;
	VERTEX = vec3(wxz.x, height_at_idx(idx), wxz.y);
	vec2 n = textureLod(normal_tex, idx * sample_m / size_m, 0.0).rg * 2.0 - 1.0;
	NORMAL = normalize(vec3(n.x, sqrt(max(1.0 - dot(n, n), 0.0)), n.y));
}

void fragment() {
	// Neutral ground until the layer textures exist (next step).
	ALBEDO = vec3(0.45);
	ROUGHNESS = 0.95;
}
