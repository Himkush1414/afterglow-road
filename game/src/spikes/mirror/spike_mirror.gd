extends SceneTree
## Spike P1-05 (assumptions A-06, A-18): planar mirror by an off-axis
## frustum camera into a SubViewport.
## Part 1 (geometry): a red sphere in front of the mirror appears in the
## mirror texture at the expected pixel within 2 px; a blue sphere behind
## the mirror never appears.
## Part 2 (cost): median frame time of a lit test room with the mirror
## viewport (square, 512 px) on and off, in alternating blocks.
## Needs a display. Prints RESULT PASS / FAIL for the geometry part and the
## cost increase in percent.

const W := 0.6
const H := 1.2
const TEX := Vector2i(512, 1024)
## Cost configurations: [texture side, update rate in Hz (0 = every frame), far].
## First: the planned desktop setting; second: the written fallback of A-06.
const COST_CONFIGS := [[512, 0.0, 30.0], [256, 15.0, 12.0]]
const FAR := 30.0
const BLOCKS := 6
const BLOCK_FRAMES := 120


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var geometry_ok := await _geometry()
	for cfg: Array in COST_CONFIGS:
		await _cost(cfg[0], cfg[1], cfg[2])
	print("RESULT %s" % ("PASS" if geometry_ok else "FAIL"))
	quit(0 if geometry_ok else 1)


func _geometry() -> bool:
	var c := Vector3(0, 1.5, 0)
	var n := Vector3(0, 0, 1)
	var u := Vector3.UP
	var r := Vector3(1, 0, 0)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	root.add_child(env)
	var red := _sphere(Color(1, 0, 0))
	var blue := _sphere(Color(0, 0, 1))
	var vp := _viewport(TEX)
	var mcam := Camera3D.new()
	vp.add_child(mcam)
	var worst := 0.0
	var blue_seen := 0
	var inside_trials := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for trial in 20:
		var eye := Vector3(
			rng.randf_range(-0.8, 0.8), rng.randf_range(1.3, 1.8), rng.randf_range(0.6, 2.5)
		)
		if trial == 0:
			# The case of T-10-6: sphere 1 m in front, 0.5 m right of the player.
			eye = Vector3(-0.5, 1.6, 1.5)
			red.position = Vector3(0.0, 1.6, 1.0)
		else:
			red.position = (
				c
				+ n
				+ Vector3(
					rng.randf_range(-0.6, 0.6),
					rng.randf_range(-0.3, 0.3),
					rng.randf_range(-0.4, 0.4)
				)
			)
		blue.position = (
			c - n * rng.randf_range(0.3, 1.5) + Vector3(rng.randf_range(-0.2, 0.2), 0, 0)
		)
		_place_mirror_camera(mcam, eye, c, n, u, H)
		for f in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		# Expected pixel: where the ray from the mirrored eye to the sphere
		# crosses the mirror plane. Texture x runs along the camera right.
		var e2 := eye - 2.0 * (eye - c).dot(n) * n
		var dir := red.position - e2
		var p := e2 + dir * ((c - e2).dot(n) / dir.dot(n))
		var ex := ((p - c).dot(mcam.global_basis.x) / W + 0.5) * TEX.x
		var ey := (0.5 - (p - c).dot(u) / H) * TEX.y
		var found := _centroid(img, Color(1, 0, 0))
		blue_seen += _count(img, Color(0, 0, 1))
		var margin := 0.06
		var inside := (
			absf((p - c).dot(r)) < W / 2 - margin and absf((p - c).dot(u)) < H / 2 - margin
		)
		if inside:
			inside_trials += 1
			worst = INF if found == Vector2.INF else maxf(worst, found.distance_to(Vector2(ex, ey)))
		if trial == 0:
			print(
				(
					"T-10-6 case: inside %s, expected (%.1f, %.1f), found %s"
					% [str(inside), ex, ey, str(found)]
				)
			)
	print(
		(
			"geometry: %d of 20 trials inside the mirror, worst centroid error %.2f px, blue pixels %d"
			% [inside_trials, worst, blue_seen]
		)
	)
	print("camera right = -mirror right: %s" % str(mcam.global_basis.x.dot(r) < -0.99))
	env.queue_free()
	red.queue_free()
	blue.queue_free()
	vp.queue_free()
	await process_frame
	return worst <= 2.0 and blue_seen == 0 and inside_trials > 0


func _cost(side: int, hz: float, far: float) -> void:
	var room := Node3D.new()
	root.add_child(room)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.3, 0.35, 0.4)
	env.environment.ambient_light_color = Color(0.4, 0.4, 0.45)
	room.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-50, 30, 0)
	room.add_child(sun)
	var fire := OmniLight3D.new()
	fire.position = Vector3(0, 0.6, 2)
	fire.omni_range = 6.0
	fire.shadow_enabled = true
	room.add_child(fire)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.6, 0.5)
	var box := BoxMesh.new()
	box.material = mat
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 60:
		var b := MeshInstance3D.new()
		b.mesh = box
		b.scale = Vector3.ONE * rng.randf_range(0.2, 0.8)
		b.position = Vector3(
			rng.randf_range(-4, 4), rng.randf_range(0, 2.5), rng.randf_range(-3, 6)
		)
		room.add_child(b)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(12, 12)
	floor_mesh.material = mat
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	room.add_child(floor_node)
	var eye := Vector3(0, 1.6, 4)
	var cam := Camera3D.new()
	cam.position = eye
	room.add_child(cam)
	cam.look_at(Vector3(0, 1.5, 0))
	cam.make_current()
	var vp := _viewport(Vector2i(side, side))
	var mcam := Camera3D.new()
	var cheap := Environment.new()
	cheap.background_mode = Environment.BG_COLOR
	cheap.background_color = Color(0.3, 0.35, 0.4)
	mcam.environment = cheap
	vp.add_child(mcam)
	_place_mirror_camera(mcam, eye, Vector3(0, 1.5, 0), Vector3(0, 0, 1), Vector3.UP, 1.0, far)
	for f in 60:  # warm-up: pipelines and shadow maps
		await process_frame
	var off: Array[float] = []
	var on: Array[float] = []
	for block in BLOCKS * 2:
		var mirror_on := block % 2 == 1
		vp.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if mirror_on and hz <= 0.0 else SubViewport.UPDATE_DISABLED
		)
		for f in 10:  # settle after the switch
			await process_frame
		var last := Time.get_ticks_usec()
		var next_update := last
		for f in BLOCK_FRAMES:
			if mirror_on and hz > 0.0 and Time.get_ticks_usec() >= next_update:
				vp.render_target_update_mode = SubViewport.UPDATE_ONCE
				next_update += int(1e6 / hz)
			await process_frame
			var now := Time.get_ticks_usec()
			(on if mirror_on else off).append((now - last) / 1000.0)
			last = now
	var med_off := _median(off)
	var med_on := _median(on)
	var mean_off := _mean(off)
	var mean_on := _mean(on)
	var rate := "every frame" if hz <= 0.0 else "%.0f Hz" % hz
	print(
		(
			"cost on %s / %s, window %s, mirror %d px, %s, far %.0f m:"
			% [
				RenderingServer.get_current_rendering_method(),
				RenderingServer.get_video_adapter_name(),
				str(DisplayServer.window_get_size()),
				side,
				rate,
				far
			]
		)
	)
	print(
		(
			"  median off %.2f on %.2f ms (+%.1f %%); mean off %.2f on %.2f ms (+%.1f %%)"
			% [
				med_off,
				med_on,
				(med_on / med_off - 1.0) * 100.0,
				mean_off,
				mean_on,
				(mean_on / mean_off - 1.0) * 100.0
			]
		)
	)
	room.queue_free()
	vp.queue_free()
	await process_frame


func _viewport(size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.world_3d = root.world_3d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	return vp


## Mirror camera of the planar mirror rule: position at the mirrored eye,
## forward along the mirror normal, off-axis frustum whose near rectangle
## is the mirror quad.
func _place_mirror_camera(
	cam: Camera3D, eye: Vector3, c: Vector3, n: Vector3, u: Vector3, h: float, far := FAR
) -> void:
	var d := (eye - c).dot(n)
	var e2 := eye - 2.0 * d * n
	cam.global_transform = Transform3D(Basis.looking_at(n, u), e2)
	var near := maxf(d, 0.05)
	var off := Vector2((c - e2).dot(cam.global_basis.x), (c - e2).dot(u)) * near / d
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.set_frustum(h * near / d, off, near, far)


func _sphere(col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.06
	s.height = 0.12
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	s.material = mat
	m.mesh = s
	root.add_child(m)
	return m


func _is(px: Color, col: Color) -> bool:
	return absf(px.r - col.r) < 0.3 and absf(px.g - col.g) < 0.3 and absf(px.b - col.b) < 0.3


func _centroid(img: Image, col: Color) -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for y in img.get_height():
		for x in img.get_width():
			if _is(img.get_pixel(x, y), col):
				sum += Vector2(x + 0.5, y + 0.5)
				count += 1
	return sum / count if count > 0 else Vector2.INF


func _count(img: Image, col: Color) -> int:
	var count := 0
	for y in img.get_height():
		for x in img.get_width():
			if _is(img.get_pixel(x, y), col):
				count += 1
	return count


func _median(a: Array[float]) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]


func _mean(a: Array[float]) -> float:
	var total := 0.0
	for v in a:
		total += v
	return total / a.size()
