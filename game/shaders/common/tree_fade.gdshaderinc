// Tree tier hand-over and tint (06 §A3). Globals are set by TreeShading:
// tree_tiers_m = (T0 end, T1 end, T2 end, T3 end) from the quality preset,
// the fade band, the camera position the fades measure from (the same in
// shadow passes) and the tint strength (value, hue in radians).

global uniform vec4 tree_tiers_m;
global uniform float tree_fade_band_m;
global uniform vec3 tree_camera_pos;
global uniform vec2 tree_tint;

// (fade-in, fade-out) visibility of tier k for an instance at `origin`. An
// empty tier is hidden; a tier that starts at 0 m does not fade in.
vec2 tree_tier_visibility(int k, vec3 origin) {
	float d = distance(origin.xz, tree_camera_pos.xz);
	float start = k == 0 ? 0.0 : tree_tiers_m[k - 1];
	float end = tree_tiers_m[k];
	if (end <= start) {
		return vec2(0.0);
	}
	float band = max(tree_fade_band_m, 0.001);
	float vin = start <= 0.0 ? 1.0 : clamp((d - start) / band + 0.5, 0.0, 1.0);
	float vout = 1.0 - clamp((d - end) / band + 0.5, 0.0, 1.0);
	return vec2(vin, vout);
}

// 4 x 4 ordered dither with complementary thresholds (spike P1-03): while
// fading in a tier keeps a pixel when 1 - t < visibility, while fading out
// when t < visibility, so two tiers handing over cover every pixel once.
bool tree_dither_keep(vec2 vis, vec2 fragcoord) {
	ivec2 p = ivec2(fragcoord) % 4;
	float bayer[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	float t = (bayer[p.x + p.y * 4] + 0.5) / 16.0;
	if (vis.x < 0.999) {
		return 1.0 - t < vis.x;
	}
	return t < vis.y;
}

// Instance tint s in [-1, 1]: value x (1 + tree_tint.x * s), hue turned by
// tree_tint.y * s radians (YIQ).
vec3 tree_tinted(vec3 c, float s) {
	mat3 to_yiq = mat3(vec3(0.299, 0.596, 0.211), vec3(0.587, -0.274, -0.523), vec3(0.114, -0.322, 0.312));
	mat3 to_rgb = mat3(vec3(1.0, 1.0, 1.0), vec3(0.956, -0.272, -1.106), vec3(0.621, -0.647, 1.703));
	vec3 yiq = to_yiq * c;
	float a = tree_tint.y * s;
	yiq.yz = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * yiq.yz;
	return max(to_rgb * yiq, vec3(0.0)) * (1.0 + tree_tint.x * s);
}
