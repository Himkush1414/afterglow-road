extends TestCase
## Warm-up scene: every rendering feature present, environment from the
## applied preset, drawn for its frames and then removed.


func test_features_and_environment_follow_the_preset() -> void:
	var w: Warmup = (load(Warmup.SCENE) as PackedScene).instantiate()
	tree.root.add_child(w)
	for type: String in [
		"DirectionalLight3D", "OmniLight3D", "ReflectionProbe", "Decal", "Camera3D"
	]:
		check(not w.find_children("*", type, false).is_empty(), type)
	for light: Light3D in w.find_children("*", "Light3D", false):
		check(light.shadow_enabled, "%s casts shadows" % light.name)
	var env := w.environment.environment
	check(env.glow_enabled, "glow")
	check_eq(env.ssao_enabled, Quality.value("ssao") == true, "ssao follows the preset")
	check_eq(env.volumetric_fog_enabled, Quality.value("volumetric_fog") == true, "fog")
	check_eq(env.ssr_enabled, Quality.value("water_ssr") == true, "ssr")
	w.free()


func test_every_custom_shader_is_drawn() -> void:
	var files := DirAccess.get_files_at("res://shaders")
	for f in files:
		if f.ends_with(".gdshader"):
			check("res://shaders/" + f in Warmup.SHADERS, "%s registered in the warm-up" % f)
	var w: Warmup = (load(Warmup.SCENE) as PackedScene).instantiate()
	tree.root.add_child(w)
	var drawn := {}
	for q: MeshInstance3D in w.find_children("Shader_*", "MeshInstance3D", false, false):
		drawn[((q.material_override as ShaderMaterial).shader as Shader).resource_path] = true
	var sky := w.environment.environment.sky.sky_material as ShaderMaterial
	if sky != null:
		drawn[sky.shader.resource_path] = true
	for path in Warmup.SHADERS:
		check(drawn.has(path), "%s drawn" % path)
	var mirror := w.find_child("Mirror", false, false) as Mirror
	check(mirror != null and mirror.live, "a live mirror")
	w.free()


func test_run_draws_and_then_removes_it() -> void:
	var holder := Node.new()
	tree.root.add_child(holder)
	var start := Engine.get_process_frames()
	await Warmup.run(holder)
	check(Engine.get_process_frames() - start >= Warmup.FRAMES - 1, "frames passed while drawn")
	await tree.process_frame
	check_eq(holder.get_child_count(), 0, "removed afterwards")
	holder.free()
