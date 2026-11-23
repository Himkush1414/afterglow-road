extends Node3D
## Rain volume under a roof (08 §4.5, A-17): the game's Rain volume (content
## tuning, preset streak count) falls on an open-sided room with a 6 x 6 m
## roof 3 m up; the camera stands under the roof looking out and down. Each
## bright pixel is projected to the floor: rain seen over the floor under
## the roof must stay at most 1/200 of the rain seen outside it. Run calm
## and with wind (slanted drops).
## Needs a display:
##   tools/godot.sh res://scenes/debug/rain_check.tscn [--rendering-method mobile] \
##       -- [--streaks 3000] [--out <dir>]
## Prints one line per wind, then RESULT PASS or FAIL (exit 0 or 1).

const ROOF_HALF := 3.0
const MARGIN := 0.4
const WINDS := [0.0, 8.0]


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("rain check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 1.2
	add_child(env)
	add_child(_box(Vector3(0, -0.05, 0), Vector3(60, 0.1, 60)))
	add_child(_box(Vector3(0, 3.0, 0), Vector3(ROOF_HALF * 2.0, 0.2, ROOF_HALF * 2.0)))
	var wind := Wind.new()
	add_child(wind)
	wind.configure(ContentDB.tuning("wind"))
	wind.set_process(false)
	wind.gust = 0.0
	var rain := Rain.new()
	add_child(rain)
	if not rain.configure(ContentDB.tuning("rain")):
		printerr("rain check: %s" % ", ".join(rain.errors))
		get_tree().quit(2)
		return
	rain.wind = wind
	rain.intensity = 1.0
	rain.build_volume(int(_arg(args, "--streaks", "3000")))
	var mat := (rain.particles.draw_pass_1 as QuadMesh).material as ShaderMaterial
	mat.set_shader_parameter("alpha", 1.0)  # full streaks so they read as bright pixels
	var cam := Camera3D.new()
	cam.fov = 100.0
	add_child(cam)
	cam.look_at_from_position(Vector3(-2.0, 1.6, 0.0), Vector3(4.0, 0.0, 0.0))
	cam.make_current()
	var out := _arg(args, "--out", "")
	var bad := 0
	for w: float in WINDS:
		wind.dir = Vector2(0.0, 1.0)  # across the view, so slanted drops pass the roof edge
		wind.base = w
		rain.particles.restart()
		for f in 60:
			await get_tree().process_frame
		var inside := 0
		var outside := 0
		for shot in 5:
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			if shot == 0 and out != "":
				var method := RenderingServer.get_current_rendering_method()
				img.save_png(out.path_join("rain_%s_w%d.png" % [method, int(w)]))
			var counts := _count(img, cam)
			inside += counts.x
			outside += counts.y
		var ok := outside > 200 and inside <= outside / 200
		bad += int(not ok)
		print(
			(
				"wind %.0f m/s: rain over the floor outside %d, under the roof %d%s"
				% [w, outside, inside, "" if ok else "  FAIL"]
			)
		)
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


## Bright pixels whose floor point lies under the roof (x) and outside (y).
func _count(img: Image, cam: Camera3D) -> Vector2i:
	var w := img.get_width()
	var h := img.get_height()
	var res := Vector2i.ZERO
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			var c := img.get_pixel(x, y)
			if c.r < 0.4:
				continue
			var o := cam.project_ray_origin(Vector2(x, y))
			var d := cam.project_ray_normal(Vector2(x, y))
			if d.y >= -0.01:
				continue
			var p := o + d * (-o.y / d.y)
			if absf(p.x) < ROOF_HALF - MARGIN and absf(p.z) < ROOF_HALF - MARGIN:
				res.x += 1
			else:
				res.y += 1
	return res


func _box(pos: Vector3, size: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.04, 0.04)
	b.material = mat
	m.mesh = b
	m.position = pos
	return m


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
