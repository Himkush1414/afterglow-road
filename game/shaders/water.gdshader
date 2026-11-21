shader_type spatial;
render_mode cull_disabled;
// Water, phone path (no screen textures, no vertex waves).
#include "res://shaders/common/water.gdshaderinc"

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_speed = UV2.x;
}

void fragment() {
	vec3 albedo;
	vec3 nm;
	float rough;
	water_fragment(UV, TIME, albedo, nm, rough);
	ALBEDO = albedo;
	NORMAL_MAP = nm;
	ROUGHNESS = rough;
	SPECULAR = 0.5;
}
