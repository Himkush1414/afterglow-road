extends Node3D
## T-10-6 and T-10-7 (10 §3): mirror render check in a test room.
## Reflection: a red sphere in front of a 0.6 x 1.2 m mirror must appear in
## the mirror's image where the line from the eye to the sphere's reflection
## crosses the quad (image x runs along the mirror camera's right, which is
## minus the mirror's right: the left-right flip) within 2 px; trial 0 is
## the plan's case (sphere 1 m in front of the mirror, 0.5 m to the eye's
## right); a blue sphere behind the mirror wall must never show.
## Swap: two mirrors on the wall, the eye walks past them; exactly one is
## live each frame, the live one changes, and frame times are reported
## against the 25 ms rule (software rendering here: the times are this
## machine's, not a GPU's).
## Needs a display:
##   tools/godot.sh res://scenes/debug/mirror_check.tscn -- [--preset <id>] [--frames <dir>]
## Prints the trials and frame times, then RESULT PASS or FAIL (exit 0 or 1).

const W := 0.6
const H := 1.2
const TOL_PX := 2.0
const TRIALS := 12
const FRAME_LIMIT_MS := 25.0
const WALK_FRAMES := 180

var _frames_dir := ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("mirror check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := PlayerCheckRig.args()
	_frames_dir = String(args.get("frames", ""))
	var preset_id := String(args.get("preset", Quality.chosen()))
	var preset: Dictionary = Quality.presets().get(preset_id, {})
	if preset.is_empty():
		print("unknown preset %s" % preset_id)
		get_tree().quit(2)
		return
	var size := int(preset.mirror_size)
	var hz := float(preset.mirror_hz)
	print("preset %s: mirror %d px, %d Hz" % [preset_id, size, hz])
	_room()
	var ok := await _reflection(size)
	ok = await _swap(size, hz) and ok
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


func _room() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	add_child(env)
	# the wall the mirrors hang on (plane z = 0, room in front at +z)
	var wall := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8, 4, 0.1)
	wall.mesh = box
	wall.position = Vector3(0, 1.5, -0.06)
	var grey := StandardMaterial3D.new()
	grey.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grey.albedo_color = Color(0.2, 0.2, 0.2)
	wall.material_override = grey
	add_child(wall)


func _mirror(x: float, size: int, hz: float) -> Mirror:
	var m := Mirror.new()
	m.width_m = W
	m.height_m = H
	add_child(m)
	m.configure(ContentDB.tuning("mirror"), size, hz, false)
	m.position = Vector3(x, 1.5, 0)  # faces +Z, into the room
	return m


func _sphere(col: Color) -> MeshInstance3D:
	var s := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	s.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	s.material_override = mat
	add_child(s)
	return s


func _reflection(size: int) -> bool:
	var mirror := _mirror(0.0, size, 60.0)
	var red := _sphere(Color(1, 0, 0))
	var blue := _sphere(Color(0, 0, 1))
	var a := mirror.axes()
	var n := a[0]
	var r := a[1]
	var u := a[2]
	var c := mirror.global_position
	var tex := Vector2(mirror.viewport.size)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	var inside_trials := 0
	var blue_seen := 0
	mirror.set_live(true)
	for trial in TRIALS:
		var eye := (
			c
			+ n * rng.randf_range(0.6, 2.5)
			+ r * rng.randf_range(-0.8, 0.8)
			+ u * rng.randf_range(-0.2, 0.3)
		)
		red.global_position = (
			c + n * 1.0 + r * rng.randf_range(-0.5, 0.5) + u * rng.randf_range(-0.3, 0.3)
		)
		if trial == 0:  # the plan's case: 1 m in front of the mirror, 0.5 m to the eye's right
			eye = c + n * 1.5 - r * 0.5 + u * 0.1
			red.global_position = eye - n * 0.5 + r * 0.5
		blue.global_position = c - n * rng.randf_range(0.3, 1.5) + r * rng.randf_range(-0.2, 0.2)
		mirror.update_view(eye, 1.0 / 60.0)
		var img := await _grab(mirror.viewport, "reflection_%02d" % trial)
		var mirrored := eye - 2.0 * (eye - c).dot(n) * n
		var dir := red.global_position - mirrored
		var p := mirrored + dir * ((c - mirrored).dot(n) / dir.dot(n))
		var want := Vector2(
			((p - c).dot(mirror.camera.global_basis.x) / W + 0.5) * tex.x,
			(0.5 - (p - c).dot(u) / H) * tex.y
		)
		var found := _centroid(
			img, func(px: Color) -> bool: return px.r > 0.5 and px.g < 0.2 and px.b < 0.2
		)
		blue_seen += PlayerCheckRig.count(
			img, func(px: Color) -> bool: return px.b > 0.5 and px.r < 0.2 and px.g < 0.2
		)
		var margin := 0.06
		if absf((p - c).dot(r)) < W / 2 - margin and absf((p - c).dot(u)) < H / 2 - margin:
			inside_trials += 1
			var err := INF if found == Vector2.INF else found.distance_to(want)
			worst = maxf(worst, err)
			print(
				(
					"trial %02d: expected (%.1f, %.1f), found (%.1f, %.1f), error %.2f px"
					% [trial, want.x, want.y, found.x, found.y, err]
				)
			)
	print(
		(
			"reflection: %d trials inside the mirror, worst %.2f px (limit %.1f), blue pixels %d"
			% [inside_trials, worst, TOL_PX, blue_seen]
		)
	)
	mirror.queue_free()
	red.queue_free()
	blue.queue_free()
	return inside_trials > 0 and worst <= TOL_PX and blue_seen == 0


func _swap(size: int, hz: float) -> bool:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var left := _mirror(-1.2, size, hz)
	var right := _mirror(1.2, size, hz)
	var system := MirrorSystem.new()
	add_child(system)
	system.setup(cam, ContentDB.tuning("mirror"), null)
	system.add_mirror(left)
	system.add_mirror(right)
	var lives: Array[Mirror] = []
	var times_ms: Array[float] = []
	var swap_frames: Array[int] = []
	var one_live := true
	cam.global_position = Vector3(-2.0, 1.6, 2.0)
	for i in 3:  # let the system pick the first live mirror
		await get_tree().process_frame
	lives.append(system.live)
	var last := Time.get_ticks_usec()
	for f in WALK_FRAMES:
		# there and back: each mirror goes live once more after its first time
		var t := float(f) / (WALK_FRAMES - 1)
		var x := lerpf(-2.0, 2.0, 1.0 - absf(2.0 * t - 1.0))
		cam.global_position = Vector3(x, 1.6, 2.0)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times_ms.append((now - last) / 1000.0)
		last = now
		var count := int(left.live) + int(right.live)
		one_live = one_live and count == 1
		if not lives.is_empty() and system.live != lives[-1]:
			swap_frames.append(f)
		lives.append(system.live)
	# the first frames include setup work: skip 5 before judging
	var judged := times_ms.slice(5)
	var worst := 0.0
	for ms: float in judged:
		worst = maxf(worst, ms)
	var at_swap := 0.0
	var per_swap: Array[String] = []
	for f in swap_frames:
		var w := 0.0
		for k in range(f, mini(f + 3, times_ms.size())):
			w = maxf(w, times_ms[k])
		per_swap.append("%d: %.1f ms" % [f, w])
		at_swap = maxf(at_swap, w)
	print("worst frame within 3 frames of each swap: %s" % ", ".join(per_swap))
	var sorted := judged.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	print("swap: one live mirror every frame %s, swaps at frames %s" % [one_live, swap_frames])
	print(
		(
			"frame times: median %.1f ms, worst %.1f ms, worst near a swap %.1f ms (limit %.0f ms)"
			% [median, worst, at_swap, FRAME_LIMIT_MS]
		)
	)
	return one_live and not swap_frames.is_empty() and at_swap <= FRAME_LIMIT_MS


func _grab(vp: SubViewport, frame_name: String) -> Image:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if _frames_dir != "":
		img.save_png(_frames_dir.path_join(frame_name + ".png"))
	return img


static func _centroid(img: Image, test: Callable) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if test.call(img.get_pixel(x, y)):
				sum += Vector2(x + 0.5, y + 0.5)
				n += 1
	return sum / n if n > 0 else Vector2.INF
