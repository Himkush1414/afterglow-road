extends SceneTree
## Spike P1-12 (assumption A-22): at the map corner in engine coordinates
## (4090, y, 4090) a held tool must not move on screen while the first-person
## camera sways by sub-millimetre steps, and 100 dropped spheres must rest
## within 5 cm of the surface. The origin is measured for comparison, and
## (1024, 941, 1024) as the worst case of a floating origin in 2,048 m steps
## (the written fallback). RESULT is the verdict at the two corners.
## `-- --sweep d1,d2,...` measures (d, 0, d) for each distance instead;
## `--no-interp` turns physics interpolation off for the run; `--viewmodel`
## draws the tool in camera space (viewmodel.gdshader); `--layer2` lets the
## camera see layer 2, which must switch the shader to the normal path.
## Rendered silhouette check needs a display (window 1920 x 1080); headless,
## only the projection maths and physics are checked.
## Prints RESULT PASS / FAIL.

const CORNERS := [Vector3(4090, 300, 4090), Vector3(-4090, 300, -4090)]
const OTHERS := [Vector3.ZERO, Vector3(1024, 941, 1024)]
const RADIUS := 0.05
const FRAMES := 120

var _rendering := false
var _viewmodel := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_rendering = DisplayServer.get_name() != "headless"
	if _rendering:
		# The window manager may still resize the window during start-up.
		var stable := 0
		while stable < 30:
			await process_frame
			stable = stable + 1 if DisplayServer.window_get_size() == Vector2i(1920, 1080) else 0
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	root.add_child(env)
	var corners_ok := true
	var origins: Array = OTHERS + CORNERS
	var args := OS.get_cmdline_user_args()
	_viewmodel = "--viewmodel" in args
	if "--no-interp" in args:
		physics_interpolation = false
	var sweep := args.find("--sweep")
	if sweep >= 0 and sweep + 1 < args.size():
		origins = []
		for d: String in args[sweep + 1].split(","):
			origins.append(Vector3(float(d), 0, float(d)))
	for origin: Vector3 in origins:
		var r: Dictionary = await _measure(origin)
		print(
			(
				(
					"origin %s: sphere drift %.5f m, worst rest error %.4f m, projection spread %.4f px, "
					% [origin, r.drift, r.rest_error, r.proj_spread]
				)
				+ (
					(
						"rendered step %.3f px max (%d of %d steps over 0.5 px), %d px silhouette"
						% [r.render_step, r.steps_over_half, FRAMES - 1, r.silhouette]
					)
					if _rendering
					else "not rendered (headless)"
				)
			)
		)
		var ok: bool = r.rest_error <= 0.05 and r.proj_spread < 1.0
		if _rendering:
			ok = ok and r.render_step < 1.0 and r.silhouette > 100 and r.size_stable
		print("  -> %s" % ("pass" if ok else "FAIL"))
		if origin in CORNERS:
			corners_ok = corners_ok and ok
	print("RESULT %s" % ("PASS" if corners_ok else "FAIL"))
	quit(0 if corners_ok else 1)


func _measure(origin: Vector3) -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	gs.shape = box
	ground.add_child(gs)
	ground.position = origin - Vector3(0, 0.5, 0)
	world.add_child(ground)
	var balls: Array[RigidBody3D] = []
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	for i in 100:
		var b := RigidBody3D.new()
		var c := CollisionShape3D.new()
		c.shape = sphere
		b.add_child(c)
		b.position = origin + Vector3((i % 10) * 0.5 - 2.5, 0.5 + i * 0.01, (i / 10) * 0.5 - 2.5)
		world.add_child(b)
		balls.append(b)

	# First-person camera with a tool 0.45 m in front, unshaded red on black.
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.far = 500.0
	# As the main camera of the plan: layer 2 (head) is not seen; the
	# viewmodel shader keys on it. `--layer2` keeps it visible (control).
	cam.set_cull_mask_value(2, "--layer2" in OS.get_cmdline_user_args())
	world.add_child(cam)
	cam.make_current()
	var tool := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.03, 0.03, 0.3)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0, 0)
	bm.material = mat
	tool.mesh = bm
	cam.add_child(tool)
	tool.position = Vector3(0.18, -0.15, -0.45)
	if _viewmodel:
		var vm := ShaderMaterial.new()
		vm.shader = load("res://src/spikes/precision/viewmodel.gdshader")
		vm.set_shader_parameter("view_local", Projection(tool.transform))
		tool.material_override = vm
	cam.position = origin + Vector3(0, 1.62, 6)

	for f in 240:
		await physics_frame
	var before: Array[Vector3] = []
	for b in balls:
		before.append(b.global_position)
	for f in 60:
		await physics_frame
	var drift := 0.0
	var rest_error := 0.0
	for i in balls.size():
		drift = maxf(drift, balls[i].global_position.distance_to(before[i]))
		rest_error = maxf(rest_error, absf(balls[i].global_position.y - (origin.y + RADIUS)))

	# Idle sway: sub-millimetre camera steps, as breathing moves the view.
	var vp_size := Vector2(1920, 1080)
	var ref := Vector2.INF
	var proj_spread := 0.0
	var render_step := 0.0
	var steps: Array[float] = []
	var size0 := DisplayServer.window_get_size()
	var silhouette := 0
	var last_c := Vector2.INF
	for f in FRAMES:
		var t := f / 60.0
		cam.position = origin + Vector3(0.0004 * sin(t * 2.0), 1.62 + 0.0008 * sin(t * 1.3), 6.0)
		cam.rotation = Vector3(0.0005 * sin(t * 1.7), 0.0005 * sin(t * 1.1), 0)
		# Maths: the tool corner as the renderer computes it (view × model in floats).
		var corner := tool.global_transform * Vector3(0.015, 0.015, -0.15)
		var local := cam.global_transform.affine_inverse() * corner
		var clip := cam.get_camera_projection() * Vector4(local.x, local.y, local.z, 1.0)
		var px := (Vector2(clip.x, -clip.y) / clip.w * 0.5 + Vector2(0.5, 0.5)) * vp_size
		if ref == Vector2.INF:
			ref = px
		proj_spread = maxf(proj_spread, px.distance_to(ref))
		if _rendering:
			await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			var cn := _red_centroid(img)
			silhouette = int(cn.z)
			var c := Vector2(cn.x, cn.y)
			if last_c != Vector2.INF:
				render_step = maxf(render_step, c.distance_to(last_c))
				steps.append(c.distance_to(last_c))
			last_c = c
	world.queue_free()
	await process_frame
	return {
		"drift": drift,
		"rest_error": rest_error,
		"proj_spread": proj_spread,
		"render_step": render_step,
		"steps_over_half": steps.filter(func(v: float) -> bool: return v > 0.5).size(),
		"size_stable": DisplayServer.window_get_size() == size0,
		"silhouette": silhouette,
	}


## x, y: centroid of red pixels; z: their count.
func _red_centroid(img: Image) -> Vector3:
	var sum := Vector2.ZERO
	var n := 0
	for y in range(img.get_height() / 2, img.get_height()):
		for x in range(img.get_width() / 2, img.get_width()):
			var c := img.get_pixel(x, y)
			if c.r > 0.5 and c.g < 0.2:
				sum += Vector2(x, y)
				n += 1
	return Vector3(sum.x / maxi(n, 1), sum.y / maxi(n, 1), n)
