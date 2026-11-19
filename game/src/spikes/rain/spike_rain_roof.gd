extends SceneTree
## Spike P1-06, rain part (assumption A-17): rain particles are stopped by a
## roof through GPUParticlesCollisionHeightField3D on both renderers. The
## camera sits inside a roofed, open-sided room looking at the floor; bright
## rain streaks must appear outside the roof's footprint and not under it.
## Needs a display. Prints RESULT PASS / FAIL. `-- --no-hf` runs the control
## without the height field (must FAIL). SPIKE_OUT names a folder for one
## PNG per renderer (default: user://).


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.1, 0.1, 0.1)
	root.add_child(env)
	# Floor (dark) and a 6 x 6 m roof 3 m up.
	root.add_child(_box(Vector3(0, -0.05, 0), Vector3(40, 0.1, 40), Color(0.05, 0.05, 0.05)))
	var roof := _box(Vector3(0, 3.0, 0), Vector3(6, 0.2, 6), Color(0.1, 0.05, 0.0))
	root.add_child(roof)
	var hf := GPUParticlesCollisionHeightField3D.new()
	hf.size = Vector3(20, 20, 20)
	hf.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	hf.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_ALWAYS
	hf.position = Vector3(0, 6, 0)
	if not "--no-hf" in OS.get_cmdline_user_args():
		root.add_child(hf)
	else:
		hf.free()
	var rain := GPUParticles3D.new()
	rain.amount = 6000
	rain.lifetime = 1.2
	rain.preprocess = 1.2
	rain.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	rain.collision_base_size = 0.02
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(10, 0.1, 10)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 0.0
	pm.initial_velocity_min = 9.0
	pm.initial_velocity_max = 9.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	rain.process_material = pm
	var streak := QuadMesh.new()
	streak.size = Vector2(0.08, 0.4)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_color = Color(1, 1, 1)
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.billboard_keep_scale = true
	streak.material = sm
	rain.draw_pass_1 = streak
	rain.position = Vector3(0, 9, 0)
	root.add_child(rain)
	var cam := Camera3D.new()
	cam.fov = 100.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(-2.0, 1.6, 0), Vector3(4.0, 0.0, 0.0))
	for f in 40:
		await process_frame
	var inside := 0
	var skipped := 0
	var outside := 0
	for shot in 5:
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if shot == 0:
			var out := OS.get_environment("SPIKE_OUT")
			img.save_png(
				(out if out != "" else "user://").path_join(
					"rain_%s.png" % RenderingServer.get_current_rendering_method()
				)
			)
		var w := img.get_width()
		var h := img.get_height()
		for y in range(0, h, 2):
			for x in range(0, w, 2):
				var c := img.get_pixel(x, y)
				if c.r > 0.6 and c.g > 0.6 and c.b > 0.6:
					# Unproject to the floor to know whether this pixel is under the roof.
					var o := cam.global_position
					var th := tan(deg_to_rad(cam.fov) * 0.5)
					var dc := Vector3((x + 0.5) / w * 2.0 - 1.0, 1.0 - (y + 0.5) / h * 2.0, 0.0)
					dc = Vector3(dc.x * th * float(w) / h, dc.y * th, -1.0)
					var d := (cam.global_basis * dc).normalized()
					if d.y >= -0.01:
						skipped += 1
						continue
					var p := o + d * (-o.y / d.y)
					if absf(p.x) < 2.6 and absf(p.z) < 2.6:
						inside += 1
					else:
						outside += 1
	print("skipped (above the horizon) %d" % skipped)
	print(
		(
			"%s: rain pixels seen over the floor outside the roof %d, under the roof %d"
			% [RenderingServer.get_current_rendering_method(), outside, inside]
		)
	)
	var ok := outside > 200 and inside <= outside / 200
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _box(pos: Vector3, size: Vector3, col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	b.material = mat
	m.mesh = b
	m.position = pos
	return m
