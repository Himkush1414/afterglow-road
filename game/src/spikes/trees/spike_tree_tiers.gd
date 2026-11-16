extends SceneTree
## Spike P1-03 (assumptions A-05, A-13).
##   -- --time    headless: refill cost of a 3,000-instance buffer
##   -- --shots   needs a display: one tree seen across the 110-130 m hand-over

const COUNT := 3000


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if "--time" in OS.get_cmdline_user_args():
		_time()
	else:
		await _shots()


func _time() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = BoxMesh.new()
	mm.instance_count = COUNT
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	root.add_child(inst)
	# Source records as the tree chunks store them: x, z (u16), yaw (u8), scale (u8).
	var rng := RandomNumberGenerator.new()
	var recs := PackedByteArray()
	recs.resize(COUNT * 7)
	for i in recs.size():
		recs[i] = rng.randi() % 256
	var buf := PackedFloat32Array()
	buf.resize(COUNT * 16)
	var times: Array[float] = []
	for rep in 50:
		var t0 := Time.get_ticks_usec()
		for i in COUNT:
			var o := i * 7
			var x := recs.decode_u16(o + 1) / 512.0
			var z := recs.decode_u16(o + 3) / 512.0
			var yaw := recs[o + 5] / 255.0 * TAU
			var s := 0.75 + recs[o + 6] / 510.0
			var c := cos(yaw) * s
			var sn := sin(yaw) * s
			var b := i * 16
			buf[b] = c
			buf[b + 1] = 0.0
			buf[b + 2] = sn
			buf[b + 3] = x
			buf[b + 4] = 0.0
			buf[b + 5] = s
			buf[b + 6] = 0.0
			buf[b + 7] = 10.0
			buf[b + 8] = -sn
			buf[b + 9] = 0.0
			buf[b + 10] = c
			buf[b + 11] = z
			buf[b + 12] = float(recs[o])
			buf[b + 13] = 0.0
			buf[b + 14] = 0.0
			buf[b + 15] = 0.0
		mm.buffer = buf
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	var med := times[times.size() / 2]
	print("refill of %d instances: median %.3f ms, worst %.3f ms" % [COUNT, med, times[-1]])
	print("RESULT %s" % ("PASS" if med <= 1.0 else "FAIL"))
	quit(0 if med <= 1.0 else 1)


func _shots() -> void:
	var near := _tier(Color(0.2, 0.5, 0.2), -1.0, 0.0, 110.0, 130.0, false)
	var far := _tier(Color(0.25, 0.55, 0.25), 110.0, 130.0, 100000.0, 100001.0, true)
	var cam := Camera3D.new()
	cam.far = 2000.0
	root.add_child(cam)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(1, 0, 1)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	root.add_child(env)
	var worst := 0.0
	for dist: float in [100.0, 112.0, 116.0, 120.0, 124.0, 128.0, 140.0]:
		cam.look_at_from_position(Vector3(0, 5, dist), Vector3(0, 5, 0))
		var both := await _tree_pixels()
		# Reference: the near tier alone, forced fully visible.
		far.visible = false
		(near.material_override as ShaderMaterial).set_shader_parameter("fade_out_start", 100000.0)
		(near.material_override as ShaderMaterial).set_shader_parameter("fade_out_end", 100001.0)
		var ref := await _tree_pixels()
		far.visible = true
		(near.material_override as ShaderMaterial).set_shader_parameter("fade_out_start", 110.0)
		(near.material_override as ShaderMaterial).set_shader_parameter("fade_out_end", 130.0)
		var ratio := float(both) / float(maxi(ref, 1))
		worst = maxf(worst, absf(1.0 - ratio))
		print(
			"distance %.0f m: hand-over covers %.3f of the single-tier silhouette" % [dist, ratio]
		)
	print("RESULT %s" % ("PASS" if worst < 0.01 else "FAIL"))
	quit()


func _tree_pixels() -> int:
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if not (c.r > 0.9 and c.b > 0.9 and c.g < 0.1):
				n += 1
	return n


func _tier(
	col: Color, a: float, b: float, c: float, d: float, incoming: bool
) -> MultiMeshInstance3D:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/spikes/trees/tier_fade.gdshader")
	mat.set_shader_parameter("fade_in_start", a)
	mat.set_shader_parameter("fade_in_end", b)
	mat.set_shader_parameter("fade_out_start", c)
	mat.set_shader_parameter("fade_out_end", d)
	mat.set_shader_parameter("colour", Vector3(col.r, col.g, col.b))
	mat.set_shader_parameter("incoming", incoming)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.5
	mesh.bottom_radius = 1.5
	mesh.height = 10.0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis(), Vector3(0, 5, 0)))
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	root.add_child(inst)
	return inst
