// The wind field (08 §5.2), the same formula as Wind.speed_at on the CPU:
// base speed raised with altitude (capped), times a gust factor from a
// tiling noise image scrolled downwind. Globals are set every frame by Wind.

global uniform vec2 wind_dir;
global uniform float wind_base;
global uniform float wind_gust;
global uniform vec2 wind_scroll;
global uniform float wind_time;
global uniform sampler2D wind_noise : filter_linear, repeat_enable;
global uniform float wind_tile_m;
global uniform float wind_altitude_scale_m;
global uniform float wind_max_ms;

float wind_base_at(float y) {
	return min(wind_base * (1.0 + max(y, 0.0) / wind_altitude_scale_m), wind_max_ms);
}

float wind_speed_at(vec3 pos) {
	float n = texture(wind_noise, (pos.xz - wind_scroll) / wind_tile_m).r;
	return wind_base_at(pos.y) * (1.0 + wind_gust * (2.0 * n - 1.0));
}

vec3 wind_vector_at(vec3 pos) {
	return vec3(wind_dir.x, 0.0, wind_dir.y) * wind_speed_at(pos);
}
