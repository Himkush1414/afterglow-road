shader_type spatial;
render_mode cull_disabled;
// Tree tier T3 (06 §A3): a unit quad (x -0.5..0.5, y 0..1, UV v 0 at the
// top) scaled per instance to the model's billboard side, turned about Y to
// face the camera, drawn from the billboard atlas cell in custom data a.
// Custom data: r wind phase (unused here), g tint, a atlas cell.

#include "res://shaders/common/tree_wind.gdshaderinc"
#include "res://shaders/common/tree_fade.gdshaderinc"

uniform sampler2D atlas_ca : source_color, filter_linear_mipmap;
uniform sampler2D atlas_n : filter_linear_mipmap;
uniform float atlas_grid = 8.0;
// Trunk lean of the model in each cell (metres at the top at the reference wind).
uniform float cell_flex[64];
uniform float roughness_value : hint_range(0.0, 1.0) = 0.85;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;

varying flat vec2 vis;
varying flat float tint;
varying vec2 cell_uv;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 cam = (inverse(MODEL_MATRIX) * vec4(tree_camera_pos, 1.0)).xyz;
	vec2 d = cam.xz;
	d = length(d) > 1e-4 ? normalize(d) : vec2(0.0, 1.0);
	vec3 facing = vec3(d.x, 0.0, d.y);
	vec3 right = vec3(facing.z, 0.0, -facing.x);
	VERTEX = right * VERTEX.x + vec3(0.0, VERTEX.y, 0.0);
	NORMAL = facing;
	TANGENT = right;
	BINORMAL = vec3(0.0, 1.0, 0.0);
	int cell = int(INSTANCE_CUSTOM.a + 0.5);
	float h = length(MODEL_MATRIX[1].xyz);  // the quad's height in metres
	vec3 lean = tree_wind_offset(vec3(0.0, VERTEX.y * h, 0.0), vec3(0.0), vec4(0.0), 0.0, origin, h, cell_flex[clamp(cell, 0, 63)], wind_time);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * lean;
	float g = atlas_grid;
	cell_uv = (vec2(mod(float(cell), g), floor(float(cell) / g)) + UV) / g;
	vis = tree_tier_visibility(3, origin);
	tint = INSTANCE_CUSTOM.g;
}

void fragment() {
	if (!tree_dither_keep(vis, FRAGCOORD.xy)) {
		discard;
	}
	vec4 c = texture(atlas_ca, cell_uv);
	ALBEDO = tree_tinted(c.rgb, tint);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	vec3 n = texture(atlas_n, cell_uv).rgb;
	NORMAL_MAP = n;
	ROUGHNESS = roughness_value;
}
