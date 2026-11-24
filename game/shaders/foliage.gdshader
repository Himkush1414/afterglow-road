shader_type spatial;
render_mode cull_disabled;
// Tree tiers T0-T2 (06 §A3, §A4): one material per surface; `leaves` cuts
// the card alpha. Per instance (MultiMesh custom data): r wind phase,
// g tint (-1..1). Vertex colour as in tree_wind.gdshaderinc.

#include "res://shaders/common/tree_wind.gdshaderinc"
#include "res://shaders/common/tree_fade.gdshaderinc"

uniform int tier : hint_range(0, 2) = 0;
uniform bool leaves = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_rough_ao : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float height_m = 10.0;
uniform float flex = 0.0;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;

varying flat vec2 vis;
varying flat float tint;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 offset = tree_wind_offset(VERTEX, NORMAL, COLOR, INSTANCE_CUSTOM.r, origin, height_m, flex, wind_time);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * offset;
	vis = tree_tier_visibility(tier, origin);
	tint = INSTANCE_CUSTOM.g;
}

void fragment() {
	if (!tree_dither_keep(vis, FRAGCOORD.xy)) {
		discard;
	}
	vec4 a = texture(albedo_tex, UV);
	vec4 n = texture(normal_rough_ao, UV);
	ALBEDO = tree_tinted(a.rgb, tint);
	ALPHA = leaves ? a.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	vec2 d = n.rg * 2.0 - 1.0;
	NORMAL_MAP = vec3(n.rg, sqrt(max(1.0 - dot(d, d), 0.0)) * 0.5 + 0.5);
	ROUGHNESS = n.b;
	AO = n.a * COLOR.a;
	if (leaves && !FRONT_FACING) {
		NORMAL = -NORMAL;  // keep the soft crown normal on the card's back face
	}
}
