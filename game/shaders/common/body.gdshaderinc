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
// Render checks: front faces glow green, back faces red, lighting-free.
uniform bool debug_faces = false;
// Double-sided surfaces show their back faces to mirrors only: the
// first-person camera would see a garment's inside through the hidden
// head's neck opening (T-10-8). Render checks switch this on as a control.
uniform bool back_faces_first_person = false;

void vertex() {
	mat4 m = ((CAMERA_VISIBLE_LAYERS & 2u) == 0u) ? view_local : MODELVIEW_MATRIX;
	VERTEX = (m * vec4(VERTEX, 1.0)).xyz;
	NORMAL = normalize((m * vec4(NORMAL, 0.0)).xyz);
	TANGENT = normalize((m * vec4(TANGENT, 0.0)).xyz);
	BINORMAL = normalize((m * vec4(BINORMAL, 0.0)).xyz);
}

void fragment() {
	if (!FRONT_FACING && !back_faces_first_person && (CAMERA_VISIBLE_LAYERS & 2u) == 0u) {
		discard;
	}
	vec4 c = albedo * texture(albedo_texture, UV);
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	if (debug_faces) {
		ALBEDO = vec3(0.0);
		EMISSION = FRONT_FACING ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	}
}
