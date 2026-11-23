// Water surface shared by the phone and desktop shaders (05 §7): colour by
// depth over the terrain heights (shallow -> deep over deep_m), shore foam
// below foam_m, two scrolling normal maps scaled by the wind, still bodies
// scroll in world space, rivers along their ribbon at their flow speed.
// Reflections come from the environment (low roughness, fresnel).

uniform sampler2D ground_tex : filter_nearest, repeat_disable;
uniform float origin_offset = 0.0;
uniform float sample_m = 2.0;
uniform float height_scale = 0.02;
uniform float height_offset = 0.0;
uniform vec3 shallow_color : source_color = vec3(0.4, 0.5, 0.5);
uniform vec3 deep_color : source_color = vec3(0.05, 0.15, 0.2);
uniform vec3 foam_color : source_color = vec3(0.9);
uniform float deep_m = 3.0;
uniform float foam_m = 0.3;
uniform float normal_tile_m = 8.0;
uniform float roughness_value = 0.05;
uniform float wind_speed = 1.0;
uniform bool flowing = false;
uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;

// Rain ripples (08 §4.5), set by Rain: intensity 0..1 and the ring look.
global uniform float rain_intensity;
global uniform float rain_ripple_cell_m;
global uniform float rain_ripple_period_s;
global uniform float rain_ripple_strength;

// Set in each shader's vertex(): world position and flow speed (UV2.x).
varying vec3 v_world;
varying float v_speed;

float ground_at_texel(ivec2 t) {
	ivec2 last = textureSize(ground_tex, 0) - ivec2(1);
	vec2 rg = texelFetch(ground_tex, clamp(t, ivec2(0), last), 0).rg;
	return (rg.r * 255.0 + rg.g * 255.0 * 256.0) * height_scale - height_offset;
}

float ground_y(vec2 xz) {
	vec2 idx = (xz + origin_offset) / sample_m;
	ivec2 i = ivec2(floor(idx));
	vec2 f = idx - vec2(i);
	float a = mix(ground_at_texel(i), ground_at_texel(i + ivec2(1, 0)), f.x);
	float b = mix(ground_at_texel(i + ivec2(0, 1)), ground_at_texel(i + ivec2(1, 1)), f.x);
	return mix(a, b, f.y);
}

// Normal tilt of rain ripples at `xz`: one ring per cell of
// rain_ripple_cell_m, from a random point at a random phase, growing to half
// a cell and fading over rain_ripple_period_s; a share of cells equal to the
// rain intensity rings in each period.
vec2 rain_ripple(vec2 xz, float time) {
	if (rain_intensity <= 0.0) {
		return vec2(0.0);
	}
	vec2 g = xz / rain_ripple_cell_m;
	vec2 cell = floor(g);
	vec2 h = fract(sin(vec2(dot(cell, vec2(127.1, 311.7)), dot(cell, vec2(269.5, 183.3)))) * 43758.5453);
	float t = time / rain_ripple_period_s + h.x;
	float age = fract(t);
	float pick = fract(sin(dot(cell + floor(t), vec2(12.9898, 78.233))) * 43758.5453);
	vec2 d = g - (cell + 0.25 + 0.5 * h);
	float x = (length(d) - age * 0.5) * 24.0;
	float ring = sin(clamp(x, -3.14159, 3.14159));
	float amp = (1.0 - age) * step(pick, rain_intensity) * rain_ripple_strength;
	return normalize(d + vec2(1e-5)) * ring * amp;
}

void water_fragment(vec2 uv, float time, out vec3 albedo, out vec3 normal_map, out float rough) {
	float depth = max(v_world.y - ground_y(v_world.xz), 0.0);
	vec3 c = mix(shallow_color, deep_color, clamp(depth / deep_m, 0.0, 1.0));
	float foam = 1.0 - smoothstep(0.0, max(foam_m, 0.001), depth);
	albedo = mix(c, foam_color, foam);
	vec2 ua;
	vec2 ub;
	if (flowing) {
		// uv = (metres across, metres along the flow)
		ua = vec2(uv.x, uv.y - v_speed * time) / normal_tile_m;
		ub = vec2(uv.x * 0.8 + 0.37, uv.y - v_speed * 0.7 * time) / (normal_tile_m * 0.6);
	} else {
		float s = 0.05 * wind_speed;
		ua = v_world.xz / normal_tile_m + vec2(s, 0.6 * s) * time;
		ub = v_world.xz / (normal_tile_m * 1.7) + vec2(-0.7 * s, 0.9 * s) * time;
	}
	vec3 na = texture(normal_a, ua).rgb * 2.0 - 1.0;
	vec3 nb = texture(normal_b, ub).rgb * 2.0 - 1.0;
	vec3 n = normalize(vec3(na.xy + nb.xy, na.z * nb.z));
	n.xy *= clamp(0.4 + 0.3 * wind_speed, 0.2, 1.5) * (1.0 - foam * 0.7);
	n.xy += rain_ripple(v_world.xz, time);
	normal_map = normalize(n) * 0.5 + 0.5;
	rough = mix(roughness_value, 0.6, foam);
}
