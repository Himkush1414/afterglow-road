shader_type spatial;
render_mode cull_disabled;
// Water, desktop path: the phone shading plus refraction of the scene behind
// the surface (screen texture, so the water is drawn after opaque objects)
// and vertex waves on still water near the camera.
#include "res://shaders/common/water.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float wave_amplitude_m = 0.25;
uniform float wave_range_m = 200.0;
uniform float refraction_strength = 0.04;
// Opacity of the water colour over the refracted bed, from shallow to deep.
uniform float shallow_opacity = 0.35;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_speed = UV2.x;
	if (!flowing) {
		vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float fade = 1.0 - clamp(distance(v_world.xz, cam.xz) / max(wave_range_m, 0.001), 0.0, 1.0);
		float w = sin(dot(v_world.xz, vec2(0.11, 0.07)) + TIME * 1.1) * 0.6
			+ sin(dot(v_world.xz, vec2(-0.05, 0.13)) + TIME * 0.8) * 0.4;
		VERTEX.y += w * wave_amplitude_m * fade * clamp(wind_speed, 0.0, 2.0) * 0.5;
		v_world.y += w * wave_amplitude_m * fade * clamp(wind_speed, 0.0, 2.0) * 0.5;
	}
}

void fragment() {
	vec3 albedo;
	vec3 nm;
	float rough;
	water_fragment(UV, TIME, albedo, nm, rough);
	float depth = max(v_world.y - ground_y(v_world.xz), 0.0);
	float a = mix(shallow_opacity, 1.0, clamp(depth / deep_m, 0.0, 1.0));
	vec2 offset = (nm.xy * 2.0 - 1.0) * refraction_strength * clamp(depth, 0.0, 1.0);
	vec3 behind = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
	ALBEDO = albedo * a;
	EMISSION = behind * (1.0 - a);
	NORMAL_MAP = nm;
	ROUGHNESS = rough;
	SPECULAR = 0.5;
}
