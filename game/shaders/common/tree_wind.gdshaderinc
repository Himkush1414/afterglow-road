// Tree wind (06 §A4): trunk lean, branch sway and leaf flutter from the wind
// field. Vertex colour: R branch phase (0 on the trunk), G flutter weight,
// B distance from the trunk along the branch, A ambient occlusion.
// Globals are set by TreeShading from the `trees` tuning group.

#include "res://shaders/common/wind.gdshaderinc"

global uniform float tree_wind_ref_ms;
global uniform float tree_bend_exponent;
global uniform float tree_height_exponent;
global uniform float tree_branch_amp_m;
global uniform float tree_branch_rate;
global uniform float tree_leaf_amp_m;
global uniform float tree_leaf_rate;
global uniform float tree_leaf_ref_ms;
global uniform vec2 tree_leaf_clamp;
global uniform vec2 tree_leaf_wave;

// World-space offset at time t of a vertex at model position v (metres from
// the tree base, y up) with normal n and vertex colour col, for a tree of
// height_m and trunk lean flex (metres at the top at the reference wind)
// standing at origin; phase is the instance's wind phase (0-1).
vec3 tree_wind_offset(vec3 v, vec3 n, vec4 col, float phase, vec3 origin, float height_m, float flex, float t) {
	float w = wind_speed_at(origin);
	float r = w / tree_wind_ref_ms;
	float h01 = clamp(v.y / max(height_m, 0.01), 0.0, 1.0);
	float bend = flex * pow(r, tree_bend_exponent) * pow(h01, tree_height_exponent);
	float branch = col.b * tree_branch_amp_m * r * sin(t * tree_branch_rate + (col.r + phase) * TAU);
	float flutter = clamp(w / tree_leaf_ref_ms, tree_leaf_clamp.x, tree_leaf_clamp.y);
	float leaf = col.g * tree_leaf_amp_m * flutter * sin(t * tree_leaf_rate + v.x * tree_leaf_wave.x + v.z * tree_leaf_wave.y);
	return vec3(wind_dir.x, 0.0, wind_dir.y) * (bend + branch) + n * leaf;
}
