extends SceneTree
## Spike P1-04 (assumption A-04): sky parameters change every 2 real seconds
## with incremental radiance updates; report frame-time spikes. Needs a
## display. On a software renderer the numbers are not GPU numbers.

const RADIANCE := 128


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	RenderingServer.global_shader_parameter_add(
		"spike_sky_blend", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0
	)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/spikes/sky/sky_spike.gdshader")
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	var cam := Camera3D.new()
	root.add_child(cam)
	var ball := MeshInstance3D.new()
	ball.mesh = SphereMesh.new()
	var m := StandardMaterial3D.new()
	m.metallic = 1.0
	m.roughness = 0.2
	ball.mesh.surface_set_material(0, m)
	ball.position = Vector3(0, 0, -3)
	root.add_child(ball)
	var calm: Array[float] = []
	var after_change: Array[float] = []
	var last := Time.get_ticks_usec()
	var t := 0.0
	var change_at := 0.0
	var frames_since_change := 99
	var step := 0
	while t < 24.0:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1000.0
		last = now
		t += dt / 1000.0
		frames_since_change += 1
		if t > 4.0:  # skip start-up and first shader compilation
			if frames_since_change <= 6:
				after_change.append(dt)
			else:
				calm.append(dt)
		RenderingServer.global_shader_parameter_set(
			"spike_sky_blend", clampf((t - change_at) / 2.0, 0.0, 1.0)
		)
		if t - change_at >= 2.0:
			change_at = t
			frames_since_change = 0
			step += 1
			var a := Color.from_hsv(fmod(step * 0.07, 1.0), 0.6, 0.8)
			mat.set_shader_parameter("zenith_a", mat.get_shader_parameter("zenith_b"))
			mat.set_shader_parameter("zenith_b", Vector3(a.r, a.g, a.b))
			sun.rotation_degrees = Vector3(-10.0 - step * 3.0, step * 10.0, 0.0)
	calm.sort()
	after_change.sort()
	var med := calm[calm.size() / 2]
	var worst_after := after_change[-1]
	var worst_calm := calm[-1]
	print(
		(
			(
				"%s on %s, radiance %d: calm median %.1f ms, calm worst %.1f ms; "
				% [
					RenderingServer.get_current_rendering_method(),
					RenderingServer.get_video_adapter_name(),
					RADIANCE,
					med,
					worst_calm
				]
			)
			+ (
				"6 frames after each change: worst %.1f ms (%d frames)"
				% [worst_after, after_change.size()]
			)
		)
	)
	var extra := worst_after - med
	print("worst extra cost after a change: %.1f ms" % extra)
	quit()
