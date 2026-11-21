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

// Ground surface (fragment). Layer weights: biome (bilinear over the four
// nearest cells) -> slope layers -> mask R (way) and G (wet) -> height blend
// with each layer's height (albedo alpha); beyond macro_near_m the far colour
// takes over (fully at macro_far_m); weather wetness darkens and smooths.
const int MAX_LAYERS = 8;
uniform sampler2D biome_tex : filter_nearest, repeat_disable;
uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform sampler2D macro_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2DArray layer_ah : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_nra : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_mask = false;
uniform bool use_macro = false;
uniform int layer_count = 0;
uniform float biome_cell_m = 16.0;
uniform int biome_layer[32];
uniform int slope_layer[2];
uniform float slope_deg[2];
uniform float slope_blend_deg = 0.0;
uniform int dirt_layer = -1;
uniform int mud_layer = -1;
uniform int triplanar_layer = -1;
uniform float tile_m = 1.0;
uniform float height_blend = 0.0;
uniform float macro_near_m = 0.0;
uniform float macro_far_m = 0.0;
uniform float wetness = 0.0;
uniform float wet_albedo = 1.0;
uniform float wet_roughness = 1.0;

varying vec3 v_pos;

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
	v_pos = VERTEX;
	vec2 n = textureLod(normal_tex, idx * sample_m / size_m, 0.0).rg * 2.0 - 1.0;
	NORMAL = normalize(vec3(n.x, sqrt(max(1.0 - dot(n, n), 0.0)), n.y));
}

// Moves `amount` of every weight onto `layer`.
void pull(inout float w[MAX_LAYERS], int layer, float amount) {
	if (layer < 0 || amount <= 0.0) {
		return;
	}
	for (int i = 0; i < MAX_LAYERS; i++) {
		w[i] *= 1.0 - amount;
	}
	w[layer] += amount;
}

vec4 sample_layer(sampler2DArray tex, int layer, vec3 pos, vec3 n, bool tri) {
	if (!tri) {
		return texture(tex, vec3(pos.xz / tile_m, float(layer)));
	}
	vec3 b = pow(abs(n), vec3(4.0));
	b /= b.x + b.y + b.z;
	return texture(tex, vec3(pos.zy / tile_m, float(layer))) * b.x
		+ texture(tex, vec3(pos.xz / tile_m, float(layer))) * b.y
		+ texture(tex, vec3(pos.xy / tile_m, float(layer))) * b.z;
}

void fragment() {
	vec2 map = v_pos.xz + origin_offset;
	vec2 nn = texture(normal_tex, map / size_m).rg * 2.0 - 1.0;
	vec3 n = normalize(vec3(nn.x, sqrt(max(1.0 - dot(nn, nn), 0.0)), nn.y));
	vec3 albedo = vec3(0.45);
	float rough = 0.95;
	float ao = 1.0;
	vec3 nw = n;
	if (layer_count > 0) {
		float w[MAX_LAYERS];
		for (int i = 0; i < MAX_LAYERS; i++) {
			w[i] = 0.0;
		}
		vec2 c = map / biome_cell_m - 0.5;
		ivec2 c0 = ivec2(floor(c));
		vec2 f = c - vec2(c0);
		ivec2 last = textureSize(biome_tex, 0) - ivec2(1);
		for (int k = 0; k < 4; k++) {
			ivec2 o = ivec2(k & 1, k >> 1);
			int id = int(texelFetch(biome_tex, clamp(c0 + o, ivec2(0), last), 0).r * 255.0 + 0.5);
			int layer = biome_layer[min(id, 31)];
			float bw = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
			if (layer >= 0) {
				w[layer] += bw;
			}
		}
		float slope = degrees(acos(clamp(n.y, -1.0, 1.0)));
		for (int s = 0; s < 2; s++) {
			float half_band = max(slope_blend_deg * 0.5, 0.001);
			pull(w, slope_layer[s], smoothstep(slope_deg[s] - half_band, slope_deg[s] + half_band, slope));
		}
		if (use_mask) {
			vec4 m = texture(mask_tex, map / size_m);
			pull(w, dirt_layer, m.r);
			pull(w, mud_layer, m.g);
		}
		// height blend: layers whose height stands out win at the borders
		vec4 ah[MAX_LAYERS];
		float top = -1.0;
		for (int i = 0; i < MAX_LAYERS; i++) {
			if (i < layer_count && w[i] > 0.001) {
				ah[i] = sample_layer(layer_ah, i, v_pos, n, i == triplanar_layer);
				top = max(top, ah[i].a + w[i]);
			}
		}
		float total = 0.0;
		vec3 a = vec3(0.0);
		vec4 nra = vec4(0.0);
		for (int i = 0; i < MAX_LAYERS; i++) {
			if (i < layer_count && w[i] > 0.001) {
				float bw = max(ah[i].a + w[i] - top + height_blend, 0.0) + 1e-4 * w[i];
				a += ah[i].rgb * bw;
				nra += sample_layer(layer_nra, i, v_pos, n, i == triplanar_layer) * bw;
				total += bw;
			}
		}
		if (total > 0.0) {
			albedo = a / total;
			nra /= total;
			rough = nra.b;
			ao = nra.a;
			// detail normal: texture x along world +x, texture up along world -z
			vec2 d = nra.rg * 2.0 - 1.0;
			vec3 t = normalize(vec3(1.0, 0.0, 0.0) - n * n.x);
			vec3 bt = cross(n, t);
			nw = normalize(n * sqrt(max(1.0 - dot(d, d), 0.0)) + t * d.x + bt * d.y);
		}
	}
	float far = clamp(
		(distance(v_pos, CAMERA_POSITION_WORLD) - macro_near_m) / max(macro_far_m - macro_near_m, 0.001),
		0.0,
		1.0
	);
	if (use_macro) {
		albedo = mix(albedo, texture(macro_tex, map / size_m).rgb, far);
	}
	nw = normalize(mix(nw, n, far));
	ALBEDO = albedo * mix(1.0, wet_albedo, wetness);
	ROUGHNESS = mix(rough, wet_roughness, wetness);
	AO = ao;
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
}
