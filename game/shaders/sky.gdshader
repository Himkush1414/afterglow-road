shader_type sky;
// The sky (08 §2.2): gradient from the colour ramp, the horizon warmed toward
// the sun, sun disc and halo, the moon lit from the sun's direction, and
// procedural stars with a milky band that turn about the celestial pole, and
// two cloud layers (high cirrus, low domain-warped cumulus) from tiling noise
// textures, drifting with the wind. The glow band (08 §2.6) is a soft band
// on the great circle through the zenith and the horizon at glow_azimuth.
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
uniform float prev_cloud_cover = 0.0;
uniform float next_cloud_cover = 0.0;
uniform float prev_cloud_darkness = 0.0;
uniform float next_cloud_darkness = 0.0;
// Glow band strength: sun and cloud fade times the story gain.
uniform float prev_glow = 0.0;
uniform float next_glow = 0.0;
uniform float blend_t0 = 0.0;
uniform float blend_s = 2.0;
uniform float time_rollover_s = 3600.0;
// Constant light added to the radiance map only (linear): ambient light
// never falls to black (08 §2.4).
uniform vec3 ambient_floor = vec3(0.0);
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
uniform float milky_intensity = 0.06;
// The milky band: the great circle whose plane has this normal (in star space).
uniform vec3 milky_normal = vec3(0.35, 0.2, 0.915);

// Compass azimuth (radians) of the band's bright end.
uniform float glow_azimuth = 0.785;
uniform vec3 glow_centre : source_color = vec3(0.75, 0.91, 0.75);
uniform vec3 glow_edge : source_color = vec3(0.95, 0.85, 0.63);
// Gaussian sigma of the band across, radians.
uniform float glow_sigma = 0.1;
uniform vec2 glow_scroll = vec2(0.004, 0.007);
uniform float glow_intensity = 0.1;
uniform float glow_end_gain = 2.5;
// Elevation (radians) below which the bright end is cut off: 0 draws the
// band down to the horizon; after the story's end it stops at the target.
uniform float glow_end_elev = 0.0;

uniform sampler2D cumulus_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D cirrus_tex : filter_linear_mipmap, repeat_enable;
// Cloud drift in metres at blend_t0, and the wind (m/s) it continues with.
uniform vec2 cloud_offset = vec2(0.0);
uniform vec2 cloud_wind = vec2(0.0);
uniform float cumulus_height_m = 1500.0;
uniform float cumulus_tile_m = 2000.0;
uniform float cirrus_height_m = 8000.0;
uniform float cirrus_tile_m = 6000.0;
uniform float cirrus_drift = 0.3;

// Real seconds since blend_t0 on the wrapped TIME; a start slightly ahead of
// TIME counts as 0.
float since_t0() {
	float d = TIME - blend_t0;
	if (d < -0.5 * time_rollover_s) {
		d += time_rollover_s;
	} else if (d > 0.5 * time_rollover_s) {
		d -= time_rollover_s;
	}
	return max(d, 0.0);
}

float blend_w() {
	return clamp(since_t0() / max(blend_s, 1e-3), 0.0, 1.0);
}

// Cloud colour (rgb) and opacity (a) of both layers along `dir`.
vec4 clouds(vec3 dir, vec3 sun_dir, vec3 sun_colour, vec3 zenith, vec3 horizon, float cover,
		float dark) {
	if (dir.y <= 0.0 || cover <= 0.0) {
		return vec4(0.0);
	}
	vec2 drift = cloud_offset + cloud_wind * since_t0();
	float fade = smoothstep(0.0, 0.08, dir.y);
	vec2 flat_dir = dir.xz / (dir.y + 0.05);
	// Light: the sun's colour by day, the sky's by night; a warm rim toward a
	// low sun; undersides darker with the weather's darkness.
	float day = smoothstep(-0.12, 0.1, sun_dir.y);
	vec3 lit = mix(zenith * 1.6 + vec3(0.01), sun_colour * 0.9 + horizon * 0.35, day);
	float low_sun = (1.0 - smoothstep(0.05, 0.4, sun_dir.y)) * day;
	float toward = pow(max(dot(dir, sun_dir), 0.0), 6.0);

	// Anchored to world XZ under the eye, so the cumulus matches its ground shadow.
	vec2 uv_ci = (POSITION.xz + flat_dir * cirrus_height_m + drift * cirrus_drift) / cirrus_tile_m;
	float ci = texture(cirrus_tex, uv_ci * vec2(1.0, 0.35)).r;
	float ci_a = smoothstep(1.0 - 0.75 * cover, 1.05, ci) * 0.55 * fade;
	vec3 ci_col = lit * 1.05 + sun_colour * toward * low_sun * 0.8;

	vec2 uv_cu = (POSITION.xz + flat_dir * cumulus_height_m + drift) / cumulus_tile_m;
	vec2 warp = texture(cirrus_tex, uv_cu * 0.5 + 0.37).rg - 0.5;
	float n = texture(cumulus_tex, uv_cu + warp * 0.18).r;
	float edge = 1.0 - cover;
	float cu_a = smoothstep(edge - 0.08, edge + 0.12, n) * fade;
	float thick = smoothstep(edge, edge + 0.35, n);
	vec3 under = lit * (0.6 - 0.4 * dark);
	vec3 cu_col = mix(lit, under, thick);
	cu_col += sun_colour * toward * low_sun * (1.0 - thick) * 1.2;

	// Cumulus over cirrus, premultiplied; returned straight for mix().
	vec3 pm = cu_col * cu_a + ci_col * ci_a * (1.0 - cu_a);
	float a = cu_a + ci_a * (1.0 - cu_a);
	return vec4(a > 1e-4 ? pm / a : vec3(0.0), a);
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

vec3 milky(vec3 dir) {
	float off = dot(dir, normalize(milky_normal));
	float core = exp(-off * off / 0.006);
	float clumps = noise3(dir * 6.0) * 0.6 + noise3(dir * 17.0) * 0.4;
	return vec3(0.75, 0.8, 0.95) * core * clumps * milky_intensity;
}

// The glow band: across, a Gaussian of glow_sigma from the great circle's
// plane; along, from the bright end (t = 0, horizon at glow_azimuth) over
// the zenith to the far end (t = 1), brightness falls from glow_end_gain
// to 1; two noise layers scroll along it as filaments.
vec3 glow(vec3 dir, float strength) {
	vec3 end_dir = vec3(sin(glow_azimuth), 0.0, -cos(glow_azimuth));
	vec3 n = normalize(cross(vec3(0.0, 1.0, 0.0), end_dir));
	float off = asin(clamp(dot(dir, n), -1.0, 1.0));
	float t_rad = atan(dir.y, dot(dir, end_dir));
	if (dir.y < 0.0 || t_rad < glow_end_elev) {
		return vec3(0.0);
	}
	float t = t_rad / PI;
	float across = exp(-0.5 * (off / glow_sigma) * (off / glow_sigma));
	float f1 = noise3(vec3(t_rad * 9.0 + TIME * glow_scroll.x * 9.0, off * 14.0, 3.0));
	float f2 = noise3(vec3(t_rad * 23.0 - TIME * glow_scroll.y * 23.0, off * 31.0, 7.0));
	// Subtle (±8%), so the end-to-end brightness rise stays readable.
	float filaments = 1.0 + 0.05 * (2.0 * f1 - 1.0) + 0.03 * (2.0 * f2 - 1.0);
	float gain = mix(glow_end_gain, 1.0, t);
	vec3 colour = mix(glow_centre, glow_edge, clamp(abs(off) / (2.0 * glow_sigma), 0.0, 1.0));
	float cut = smoothstep(glow_end_elev, glow_end_elev + 0.02, t_rad);
	return colour * across * filaments * gain * glow_intensity * strength * cut;
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
	float cover = mix(prev_cloud_cover, next_cloud_cover, w);
	float dark = mix(prev_cloud_darkness, next_cloud_darkness, w);
	float glow_strength = mix(prev_glow, next_glow, w);

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
		col += (stars(star_dir) * star_intensity + milky(star_dir)) * star_fade;
	}

	vec4 m = moon(dir, moon_dir, sun_dir);
	col = mix(col, m.rgb, m.a * step(0.0, moon_dir.y + 0.02));

	float disc = smoothstep(radians(sun_radius_deg) * 1.1, radians(sun_radius_deg) * 0.9, ang);
	col += sun_colour * sun_intensity * disc * step(-0.02, sun_dir.y);

	vec4 c = clouds(dir, sun_dir, sun_colour, zenith, horizon, cover, dark);
	col = mix(col, c.rgb, c.a);
	// On top of the clouds: it glows through overcast, dimmed by the cover.
	if (!AT_CUBEMAP_PASS && glow_strength > 0.0) {
		col += glow(dir, glow_strength);
	}

	if (AT_CUBEMAP_PASS) {
		col += ambient_floor;
	}

	COLOR = col;
}
