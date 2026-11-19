shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Spike P1-06: flame card. Two scrolling noise layers erode the
// alpha; a colour ramp from a white-yellow core to deep red tips; HDR.

uniform sampler2D noise_a : repeat_enable, filter_linear;
uniform sampler2D noise_b : repeat_enable, filter_linear;
uniform float intensity = 6.0;
uniform float lean = 0.0; // radians, from the wind
uniform float flame_height = 0.7; // metres, card height
uniform vec3 wind_dir = vec3(1.0, 0.0, 0.0); // world space, unit
uniform float seed = 0.0;

void vertex() {
	// Lean the top of the card downwind (one world direction for every
	// crossed card); keep the base fixed.
	vec3 local_wind = (inverse(MODEL_MATRIX) * vec4(wind_dir, 0.0)).xyz;
	VERTEX += local_wind * tan(lean) * (1.0 - UV.y) * flame_height;
}

void fragment() {
	vec2 uv = UV;
	float t = TIME;
	float n1 = texture(noise_a, uv * vec2(1.0, 0.6) + vec2(seed, t * 1.3)).r;
	float n2 = texture(noise_b, uv * vec2(1.7, 1.1) + vec2(seed * 2.0, t * 2.1)).r;
	float body = smoothstep(0.0, 0.35, uv.y) * (1.0 - smoothstep(0.0, 0.5, abs(uv.x - 0.5)));
	float shape = body * mix(1.0, 0.25, 1.0 - uv.y);
	float a = clamp(shape * 1.6 - (n1 * 0.6 + n2 * 0.4) * (1.2 - uv.y), 0.0, 1.0);
	vec3 core = vec3(1.0, 0.95, 0.75);
	vec3 mid = vec3(1.0, 0.55, 0.12);
	vec3 tip = vec3(0.6, 0.08, 0.02);
	float heat = clamp(a * 1.4 + uv.y * 0.3 - 0.2, 0.0, 1.0);
	vec3 col = mix(tip, mid, smoothstep(0.0, 0.5, heat));
	col = mix(col, core, smoothstep(0.55, 1.0, heat));
	ALBEDO = col * intensity * a;
}
