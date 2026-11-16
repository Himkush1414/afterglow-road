shader_type spatial;
render_mode cull_disabled;
// Spike P1-03 (assumption A-13): per-instance distance hand-over between two
// tiers with a screen-space dither, using the instance origin.

uniform float fade_in_start = -1.0;   // distance where this tier starts to appear
uniform float fade_in_end = 0.0;
uniform float fade_out_start = 100000.0;  // distance where this tier starts to vanish
uniform float fade_out_end = 100001.0;
uniform vec3 colour = vec3(0.2, 0.4, 0.2);
// The incoming tier uses the inverted pattern so the two tiers interleave.
uniform bool incoming = false;

varying float visibility;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = distance(origin.xz, cam.xz);
	float fin = clamp((d - fade_in_start) / max(fade_in_end - fade_in_start, 0.001), 0.0, 1.0);
	float fout = 1.0 - clamp((d - fade_out_start) / max(fade_out_end - fade_out_start, 0.001), 0.0, 1.0);
	visibility = fin * fout;
}

void fragment() {
	// 4 x 4 ordered dither: the two tiers use complementary thresholds, so
	// together they always cover every pixel during the hand-over.
	ivec2 p = ivec2(FRAGCOORD.xy) % 4;
	int idx = p.x + p.y * 4;
	float bayer[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	float threshold = (bayer[idx] + 0.5) / 16.0;
	if (incoming) {
		threshold = 1.0 - threshold;
	}
	if (visibility <= threshold) {
		discard;
	}
	ALBEDO = colour;
}
