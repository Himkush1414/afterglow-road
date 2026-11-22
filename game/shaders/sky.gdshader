shader_type sky;
// The sky (08 §2.2): gradient from the colour ramp, the horizon warmed toward
// the sun, sun disc and halo, the moon lit from the sun's direction, and
// procedural stars with a milky band that turn about the celestial pole.
// SkyDome sets each value as a prev_/next_ pair once per game minute; the
// shader blends them over blend_s real seconds from blend_t0 (shader TIME,
// measured by ShaderClock).

uniform vec3 prev_zenith : source_color = vec3(0.0);
uniform vec3 next_zenith : source_color = vec3(0.0);
uniform vec3 prev_horizon : source_color = vec3(0.0);
uniform vec3 next_horizon : source_color = vec3(0.0);
uniform vec3 prev_horizon_sun : source_color = vec3(0.0);
uniform vec3 next_horizon_sun : source_color = vec3(0.0);
uniform vec3 prev_sun_colour : source_color = vec3(1.0);
uniform vec3 next_sun_colour : source_color = vec3(1.0);
uniform vec3 prev_sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 next_sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 prev_moon_dir = vec3(0.0, -1.0, 0.0);
uniform vec3 next_moon_dir = vec3(0.0, -1.0, 0.0);
uniform float prev_stars = 0.0;
uniform float next_stars = 0.0;
// Star rotation about the pole, radians.
uniform float prev_star_angle = 0.0;
uniform float next_star_angle = 0.0;
uniform float blend_t0 = 0.0;
uniform float blend_s = 2.0;
uniform float time_rollover_s = 3600.0;
// Unit vector to the celestial pole.
uniform vec3 pole = vec3(0.0, 0.766, -0.643);

uniform float sun_radius_deg = 0.6;
uniform float sun_intensity = 40.0;
uniform float sun_halo_deg = 8.0;
uniform float moon_radius_deg = 0.7;
uniform vec3 moon_albedo : source_color = vec3(0.8, 0.8, 0.78);
uniform float moon_intensity = 2.0;
uniform float star_cells = 60.0;
uniform float star_share = 0.09;
uniform float star_intensity = 3.0;
uniform float band_intensity = 0.06;
// The milky band: the great circle whose plane has this normal (in star space).
uniform vec3 band_normal = vec3(0.35, 0.2, 0.915);

float blend_w() {
	float d = TIME - blend_t0;
	// Wrapped at the rollover; a start slightly ahead of TIME waits at 0.
	if (d < -0.5 * time_rollover_s) {
		d += time_rollover_s;
	} else if (d > 0.5 * time_rollover_s) {
		d -= time_rollover_s;
	}
	return clamp(d / max(blend_s, 1e-3), 0.0, 1.0);
}

vec3 rotate_about(vec3 v, vec3 axis, float a) {
	return v * cos(a) + cross(axis, v) * sin(a) + axis * dot(axis, v) * (1.0 - cos(a));
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 hash33(vec3 p) {
	return vec3(hash13(p), hash13(p + 17.17), hash13(p + 41.41));
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

// Stars: one candidate per cell of a 3-D grid, kept with probability
// star_share; three sizes; slight twinkle.
vec3 stars(vec3 dir) {
	vec3 p = dir * star_cells;
	vec3 cell = floor(p);
	vec3 h = hash33(cell);
	if (h.x > star_share) {
		return vec3(0.0);
	}
	vec3 centre = cell + 0.25 + 0.5 * hash33(cell + 5.0);
	float d = length(p - centre);
	float size = h.y < 0.7 ? 0.05 : (h.y < 0.95 ? 0.08 : 0.12);
	float twinkle = 0.85 + 0.15 * sin(TIME * (2.0 + 3.0 * h.z) + h.z * 40.0);
	vec3 tint = mix(vec3(0.8, 0.85, 1.0), vec3(1.0, 0.9, 0.8), h.z);
	return tint * smoothstep(size, 0.0, d) * twinkle * (0.3 + h.y);
}

vec3 band(vec3 dir) {
	float off = dot(dir, normalize(band_normal));
	float core = exp(-off * off / 0.006);
	float clumps = noise3(dir * 6.0) * 0.6 + noise3(dir * 17.0) * 0.4;
	return vec3(0.75, 0.8, 0.95) * core * clumps * band_intensity;
}

// The moon: a sphere seen as a disc, lit from the sun's direction.
vec4 moon(vec3 dir, vec3 moon_dir, vec3 sun_dir) {
	float r = radians(moon_radius_deg);
	vec3 right = normalize(cross(abs(moon_dir.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0), moon_dir));
	vec3 up = cross(moon_dir, right);
	vec2 uv = vec2(dot(dir, right), dot(dir, up)) / r;
	float rr = dot(uv, uv);
	if (dot(dir, moon_dir) <= 0.0 || rr >= 1.0) {
		return vec4(0.0);
	}
	// Normal of the visible face (it points back toward the viewer); the
	// sun is far enough that its direction is the same from the moon.
	vec3 n = uv.x * right + uv.y * up - sqrt(1.0 - rr) * moon_dir;
	float lit = max(dot(n, sun_dir), 0.0);
	vec3 surface = moon_albedo * (0.75 + 0.25 * noise3(vec3(uv * 4.0, 1.0)));
	float edge = smoothstep(1.0, 0.97, rr);
	return vec4(surface * (lit * moon_intensity + 0.01), edge);
}

void sky() {
	float w = blend_w();
	vec3 zenith = mix(prev_zenith, next_zenith, w);
	vec3 horizon = mix(prev_horizon, next_horizon, w);
	vec3 horizon_sun = mix(prev_horizon_sun, next_horizon_sun, w);
	vec3 sun_colour = mix(prev_sun_colour, next_sun_colour, w);
	vec3 sun_dir = normalize(mix(prev_sun_dir, next_sun_dir, w));
	vec3 moon_dir = normalize(mix(prev_moon_dir, next_moon_dir, w));
	float star_fade = mix(prev_stars, next_stars, w);
	float star_angle = mix(prev_star_angle, next_star_angle, w);

	vec3 dir = EYEDIR;
	vec2 view_h = normalize(dir.xz + vec2(1e-5));
	vec2 sun_h = normalize(sun_dir.xz + vec2(1e-5));
	float toward_sun = pow(max(dot(view_h, sun_h), 0.0), 4.0);
	vec3 h_col = mix(horizon, horizon_sun, toward_sun);
	float up = max(dir.y, 0.0);
	vec3 col = mix(h_col, zenith, pow(up, 0.5));
	if (dir.y < 0.0) {
		col = h_col * mix(1.0, 0.35, smoothstep(0.0, 0.3, -dir.y));
	}

	float cos_sun = dot(dir, sun_dir);
	float ang = acos(clamp(cos_sun, -1.0, 1.0));
	float halo = exp(-pow(ang / radians(sun_halo_deg), 2.0)) * 0.6;
	col += sun_colour * halo * smoothstep(-0.1, 0.05, sun_dir.y);

	if (!AT_CUBEMAP_PASS && star_fade > 0.0 && dir.y > -0.05) {
		vec3 star_dir = rotate_about(dir, normalize(pole), -star_angle);
		col += (stars(star_dir) * star_intensity + band(star_dir)) * star_fade;
	}

	vec4 m = moon(dir, moon_dir, sun_dir);
	col = mix(col, m.rgb, m.a * step(0.0, moon_dir.y + 0.02));

	float disc = smoothstep(radians(sun_radius_deg) * 1.1, radians(sun_radius_deg) * 0.9, ang);
	col += sun_colour * sun_intensity * disc * step(-0.02, sun_dir.y);

	COLOR = col;
}
