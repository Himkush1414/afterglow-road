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


func test_run_draws_and_then_removes_it() -> void:
	var holder := Node.new()
	tree.root.add_child(holder)
	var start := tree.get_frame()
	await Warmup.run(holder)
	check(tree.get_frame() - start >= Warmup.FRAMES - 1, "frames passed while drawn")
	await tree.process_frame
	check_eq(holder.get_child_count(), 0, "removed afterwards")
	holder.free()
