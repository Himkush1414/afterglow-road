shader_type spatial;
// Rock objects (cliff faces, boulders): the terrain's rock layer texture,
// projected from world position onto each instance's own X-Y plane (so the
// texture runs on across neighbouring faces instead of repeating per face);
// a plain grey when the texture is missing.

uniform bool textured = false;
uniform sampler2D albedo_height : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_rough_ao : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 base_color : source_color = vec3(0.45);
uniform float uv_m = 6.0;

varying vec2 v_uv;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_uv = vec2(dot(wp, normalize(MODEL_MATRIX[0].xyz)), -dot(wp, normalize(MODEL_MATRIX[1].xyz))) / uv_m;
}

void fragment() {
	if (textured) {
		vec4 a = texture(albedo_height, v_uv);
		vec4 n = texture(normal_rough_ao, v_uv);
		vec2 d = n.rg * 2.0 - 1.0;
		ALBEDO = a.rgb;
		NORMAL_MAP = vec3(n.rg, sqrt(max(1.0 - dot(d, d), 0.0)) * 0.5 + 0.5);
		ROUGHNESS = n.b;
		AO = n.a;
	} else {
		ALBEDO = base_color;
		ROUGHNESS = 0.9;
	}
}
