shader_type spatial;
render_mode unshaded, cull_back;
// Planar mirror surface (10 §3.2). Live: the mirror camera's view with U
// flipped, times the tint, plus dust where the wipe mask allows. Not live:
// a dull, dusty grey gradient. Cracked: the crack overlay on top.

uniform sampler2D reflection : source_color, filter_linear, repeat_disable;
uniform bool live = false;
uniform float tint = 0.92;
uniform sampler2D dust : source_color, hint_default_black;
uniform sampler2D wipe_mask : hint_default_white;
uniform bool cracked = false;
uniform sampler2D crack : source_color, hint_default_transparent;
uniform vec3 dull_top : source_color = vec3(0.42, 0.43, 0.44);
uniform vec3 dull_bottom : source_color = vec3(0.30, 0.31, 0.32);

void fragment() {
	vec3 c;
	if (live) {
		c = texture(reflection, vec2(1.0 - UV.x, UV.y)).rgb * tint;
	} else {
		c = mix(dull_top, dull_bottom, UV.y);
	}
	c += texture(dust, UV).rgb * texture(wipe_mask, UV).r;
	if (cracked) {
		vec4 k = texture(crack, UV);
		c = mix(c, k.rgb, k.a);
	}
	ALBEDO = c;
}
