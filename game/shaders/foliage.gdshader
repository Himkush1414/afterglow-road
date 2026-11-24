shader_type spatial;
render_mode cull_disabled;
// Tree tiers T0-T2 (06 §A3, §A4): one surface per tier mesh holding bark and
// leaf cards (Q-110); a vertex is a card when its flutter weight (colour G)
// is above 0.25, bark when it is 0. Cards cut their alpha. Per instance
// (MultiMesh custom data): r wind phase, g tint (-1..1). Vertex colour as in
// tree_wind.gdshaderinc.

#include "res://shaders/common/tree_wind.gdshaderinc"
#include "res://shaders/common/tree_fade.gdshaderinc"

uniform int tier : hint_range(0, 2) = 0;
uniform sampler2D bark_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_nra : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D leaf_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D leaf_nra : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float height_m = 10.0;
uniform float flex = 0.0;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;

varying flat vec2 vis;
varying flat float tint;
varying float leaf;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 offset = tree_wind_offset(VERTEX, NORMAL, COLOR, INSTANCE_CUSTOM.r, origin, height_m, flex, wind_time);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * offset;
	vis = tree_tier_visibility(tier, origin);
	tint = INSTANCE_CUSTOM.g;
	leaf = COLOR.g > 0.25 ? 1.0 : 0.0;
}

void fragment() {
	if (!tree_dither_keep(vis, FRAGCOORD.xy)) {
		discard;
	}
	// Both pairs are sampled so mip derivatives stay valid where bark meets a card.
	bool is_leaf = leaf > 0.5;
	vec4 la = texture(leaf_albedo, UV);
	vec4 ba = texture(bark_albedo, UV);
	vec4 ln = texture(leaf_nra, UV);
	vec4 bn = texture(bark_nra, UV);
	vec4 a = mix(ba, la, leaf);
	vec4 n = mix(bn, ln, leaf);
	ALBEDO = tree_tinted(a.rgb, tint);
	ALPHA = is_leaf ? a.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	vec2 d = n.rg * 2.0 - 1.0;
	NORMAL_MAP = vec3(n.rg, sqrt(max(1.0 - dot(d, d), 0.0)) * 0.5 + 0.5);
	ROUGHNESS = n.b;
	AO = n.a * COLOR.a;
	if (is_leaf && !FRONT_FACING) {
		NORMAL = -NORMAL;  // keep the soft crown normal on the card's back face
	}
}
