shader_type spatial;
// The outer ring around the map (05 §4 stage 12a): far terrain colours per
// vertex (by height and slope, linear), fully rough, fogged like the terrain.
render_mode cull_back, diffuse_lambert, specular_disabled;

varying vec3 v_colour;

void vertex() {
	v_colour = COLOR.rgb;
}

void fragment() {
	ALBEDO = v_colour;
	ROUGHNESS = 1.0;
}
