shader_type spatial;
// Spike P1-01: CDLOD patch, height from an RG8 texture (assumption A-03).

uniform sampler2D height_tex : filter_nearest, repeat_disable;
uniform float sample_m = 2.0;
uniform float half_world = 4096.0;
uniform float height_scale = 0.02;
uniform float height_offset = 64.0;
uniform float morph_start = 0.7;
uniform float r0 = 160.0;
uniform float base_cells = 32.0;

varying vec3 world_normal;
varying float world_y;

float h_at(ivec2 t) {
	t = clamp(t, ivec2(0), ivec2(4095));
	vec2 rg = texelFetch(height_tex, t, 0).rg;
	return (rg.r * 255.0 + rg.g * 255.0 * 256.0) * height_scale - height_offset;
}

float height(vec2 xz) {
	vec2 g = (xz + half_world) / sample_m;
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	float a = mix(h_at(i), h_at(i + ivec2(1, 0)), f.x);
	float b = mix(h_at(i + ivec2(0, 1)), h_at(i + ivec2(1, 1)), f.x);
	return mix(a, b, f.y);
}

void vertex() {
	// Every instance has the identity transform; the patch is placed from
	// INSTANCE_CUSTOM = (corner x, corner z, size, level + 0.5 if quadrant).
	// Positions are formed in whole-sample units and no per-instance matrix
	// touches them, so vertices shared by two patches are bit-identical.
	vec2 origin_idx = round((INSTANCE_CUSTOM.xy + half_world) / sample_m);
	float size = INSTANCE_CUSTOM.z;
	float level = floor(INSTANCE_CUSTOM.w);
	float cells = fract(INSTANCE_CUSTOM.w) > 0.25 ? base_cells * 0.5 : base_cells;
	float range = r0 * exp2(level);
	float step_idx = size / (cells * sample_m);
	vec2 g = floor(round(VERTEX.xz * 32.0) * (cells / 32.0));
	vec2 wxz = (origin_idx + g * step_idx) * sample_m - half_world;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = distance(vec3(wxz.x, height(wxz), wxz.y), cam);
	float k = clamp((d - morph_start * range) / ((1.0 - morph_start) * range), 0.0, 1.0);
	g -= fract(g * 0.5) * 2.0 * k;
	wxz = (origin_idx + g * step_idx) * sample_m - half_world;
	float y = height(wxz);
	float e = sample_m;
	float hx = height(wxz + vec2(e, 0.0)) - height(wxz - vec2(e, 0.0));
	float hz = height(wxz + vec2(0.0, e)) - height(wxz - vec2(0.0, e));
	world_normal = normalize(vec3(-hx, 2.0 * e, -hz));
	world_y = y;
	VERTEX = vec3(wxz.x, y, wxz.y);
	NORMAL = world_normal;
}

void fragment() {
	float slope = 1.0 - world_normal.y;
	vec3 grass = vec3(0.30, 0.42, 0.20);
	vec3 rock = vec3(0.45, 0.43, 0.40);
	vec3 snow = vec3(0.85);
	vec3 c = mix(grass, rock, smoothstep(0.15, 0.35, slope));
	c = mix(c, snow, smoothstep(800.0, 900.0, world_y));
	ALBEDO = c;
	ROUGHNESS = 0.95;
}
