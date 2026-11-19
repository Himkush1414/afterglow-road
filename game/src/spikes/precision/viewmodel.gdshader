shader_type spatial;
render_mode unshaded, skip_vertex_transform;
// Spike P1-12: draw a held item in camera space. view_local is the item's
// transform relative to the camera, so no world-sized number enters the
// vertex maths.

uniform mat4 view_local;
uniform vec3 color : source_color = vec3(1.0, 0.0, 0.0);

void vertex() {
	// Only the main camera (it does not see layer 2) takes the camera-space
	// path; other cameras (mirrors) use the normal transform.
	if ((CAMERA_VISIBLE_LAYERS & 2u) == 0u) {
		VERTEX = (view_local * vec4(VERTEX, 1.0)).xyz;
		NORMAL = normalize((view_local * vec4(NORMAL, 0.0)).xyz);
	} else {
		VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	}
}

void fragment() {
	ALBEDO = color;
}
