// First-person body surface (10 §2 rule 5). The main camera does not draw
// the head layer (layer 2); for it the vertex goes straight to view space
// through view_local, the mesh's transform relative to the camera built
// from local transforms under the player, so no world-sized number enters
// the maths. Mirrors (which draw layer 2) and shadow passes use the normal
// model-view transform.

uniform mat4 view_local;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;

void vertex() {
	mat4 m = ((CAMERA_VISIBLE_LAYERS & 2u) == 0u) ? view_local : MODELVIEW_MATRIX;
	VERTEX = (m * vec4(VERTEX, 1.0)).xyz;
	NORMAL = normalize((m * vec4(NORMAL, 0.0)).xyz);
	TANGENT = normalize((m * vec4(TANGENT, 0.0)).xyz);
	BINORMAL = normalize((m * vec4(BINORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 c = albedo * texture(albedo_texture, UV);
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
}
