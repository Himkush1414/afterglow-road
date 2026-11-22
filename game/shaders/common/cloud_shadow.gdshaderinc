// Cloud shadows on the ground (08 §2.2): the cumulus noise projected
// straight down on world XZ (one repeat per cloud_shadow_tile_m metres),
// drifting with the wind, thresholded by the cloud cover like the sky's
// cumulus. Direct light is multiplied by 1 - 0.5 * shadow. The globals are
// set once per game minute by SkyDome; the drift continues from
// cloud_shadow_t0 on the shaders' TIME.
//
// `cloud_direct_light` replaces the built-in lighting in a light() function:
// Lambert diffuse and GGX specular, with directional lights scaled by the
// cloud shadow at `world`.

global uniform sampler2D cloud_shadow_tex : filter_linear_mipmap, repeat_enable;
global uniform vec2 cloud_shadow_drift;
global uniform vec2 cloud_shadow_wind;
global uniform float cloud_shadow_t0;
global uniform float cloud_shadow_cover;
global uniform float cloud_shadow_tile_m;
global uniform float cloud_time_rollover_s;

float cloud_shadow(vec3 world) {
	if (cloud_shadow_cover <= 0.0) {
		return 0.0;
	}
	float d = TIME - cloud_shadow_t0;
	if (d < -0.5 * cloud_time_rollover_s) {
		d += cloud_time_rollover_s;
	} else if (d > 0.5 * cloud_time_rollover_s) {
		d -= cloud_time_rollover_s;
	}
	vec2 drift = cloud_shadow_drift + cloud_shadow_wind * max(d, 0.0);
	float n = texture(cloud_shadow_tex, (world.xz + drift) / max(cloud_shadow_tile_m, 1.0)).r;
	float edge = 1.0 - cloud_shadow_cover;
	return smoothstep(edge - 0.08, edge + 0.12, n);
}

void cloud_direct_light(vec3 world, vec3 normal, vec3 view, vec3 light, vec3 light_colour,
		float attenuation, bool directional, float roughness, float metallic,
		inout vec3 diffuse, inout vec3 specular) {
	float shade = directional ? 1.0 - 0.5 * cloud_shadow(world) : 1.0;
	float ndl = clamp(dot(normal, light), 0.0, 1.0);
	vec3 radiance = light_colour * attenuation * shade;
	diffuse += ndl * radiance / PI * (1.0 - metallic);
	vec3 h = normalize(view + light);
	float ndh = clamp(dot(normal, h), 0.0, 1.0);
	float ndv = clamp(dot(normal, view), 1e-3, 1.0);
	float a = max(roughness * roughness, 1e-3);
	float a2 = a * a;
	float den = ndh * ndh * (a2 - 1.0) + 1.0;
	float dist = a2 / (PI * den * den);
	float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
	float geo = ndl / (ndl * (1.0 - k) + k) * ndv / (ndv * (1.0 - k) + k);
	float fres = 0.04 + 0.96 * pow(1.0 - clamp(dot(view, h), 0.0, 1.0), 5.0);
	specular += dist * geo * fres / max(4.0 * ndl * ndv, 1e-4) * ndl * radiance / PI;
}
