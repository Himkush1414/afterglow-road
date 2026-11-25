shader_type spatial;
render_mode cull_disabled;
// Ground cover (06 §B4). Per instance (MultiMesh custom data): r fade key
// 0..1, g wind phase 0..1. Vertex colour R is the tip weight (0 at the root,
// 1 at the tip). The tip leans downwind by
//   tip × (lean_base + lean_per_ms × w) × blade height
// with w the gust field at the plant (wind.gdshaderinc, so gust fronts
// travel across the ground at the wind speed), plus a flutter of
// flutter_m at flutter_hz. Benders (xyz, radius; radius 0 = unused) push
// tips outward within their radius. A plant is drawn while its fade key is
// below the fade factor: 1 inside, falling linearly to 0 over the last
// fade_band of radius_m.

#include "res://shaders/common/wind.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_texture = false;
uniform vec3 colour : source_color = vec3(0.32, 0.42, 0.16);
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
// Mesh height at scale 1, in metres.
uniform float blade_height_m = 0.5;
// Lean, flutter and bender push: set from the "grass" tuning.
uniform float lean_base = 0.0;
uniform float lean_per_ms = 0.0;
uniform float flutter_m = 0.0;
uniform float flutter_hz = 1.0;
uniform float radius_m = 48.0;
uniform float fade_band = 0.3;
uniform vec4 benders[4];
uniform float bend_push = 0.0;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 eye = INV_VIEW_MATRIX[3].xyz;
	float d = distance(origin.xz, eye.xz);
	float keep = clamp((radius_m - d) / max(fade_band * radius_m, 0.001), 0.0, 1.0);
	if (INSTANCE_CUSTOM.r >= keep) {
		VERTEX = vec3(0.0);  // collapsed: no fragments
	} else {
		mat3 m = mat3(MODEL_MATRIX);
		float scale = length(m[1]);
		float h = blade_height_m * scale;
		float tip = COLOR.r;
		vec2 dir = wind_dir;
		float w = wind_speed_at(origin);
		vec2 lean = dir * (lean_base + lean_per_ms * w) * h;
		lean += dir * flutter_m * sin(TAU * (flutter_hz * wind_time + INSTANCE_CUSTOM.g));
		for (int i = 0; i < 4; i++) {
			vec4 b = benders[i];
			vec2 away = origin.xz - b.xz;
			float r = length(away);
			if (b.w > 0.0 && r < b.w) {
				lean += (r > 0.001 ? away / r : dir) * (1.0 - r / b.w) * bend_push * h;
			}
		}
		// Keep the blade's length: the tip sinks as it leans.
		float l = min(length(lean), h * 0.95);
		vec2 shift = length(lean) > 0.0 ? normalize(lean) * l : vec2(0.0);
		float sink = h - sqrt(h * h - l * l);
		vec3 offset = vec3(shift.x, -sink, shift.y) * tip;
		VERTEX += inverse(m) * offset;
	}
}

void fragment() {
	vec4 a = use_texture ? texture(albedo_tex, UV) : vec4(colour, 1.0);
	ALBEDO = a.rgb * (0.6 + 0.4 * COLOR.r);
	ALPHA = a.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ROUGHNESS = 0.9;
	BACKLIGHT = a.rgb * 0.3;
}
