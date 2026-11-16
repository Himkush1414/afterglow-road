shader_type sky;
// Spike P1-04: a sky whose parameters change once per game minute; the
// shader interpolates between the last two values (08 §2.2).

global uniform float spike_sky_blend;
uniform vec3 zenith_a = vec3(0.16, 0.44, 0.82);
uniform vec3 zenith_b = vec3(0.16, 0.44, 0.82);
uniform vec3 horizon_a = vec3(0.72, 0.83, 0.93);
uniform vec3 horizon_b = vec3(0.72, 0.83, 0.93);

void sky() {
	vec3 z = mix(zenith_a, zenith_b, spike_sky_blend);
	vec3 h = mix(horizon_a, horizon_b, spike_sky_blend);
	float t = pow(clamp(EYEDIR.y, 0.0, 1.0), 0.5);
	vec3 col = mix(h, z, t);
	float sun = smoothstep(0.9995, 0.9999, dot(EYEDIR, LIGHT0_DIRECTION));
	COLOR = col + LIGHT0_COLOR * LIGHT0_ENERGY * sun * 20.0;
}
