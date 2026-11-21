extends Node3D
## T-05-3 (b): renders frames along the terrain flight with a magenta clear
## colour and counts magenta pixels below terrain in the same screen column.
## With no camera roll a column is a vertical plane, so such a pixel is a
## crack or a wrongly culled patch. Anti-aliasing is turned off after the
## preset is applied, so edge blends cannot pass for holes or hide one.
## Needs a display:
##   tools/godot.sh res://scenes/debug/terrain_flight_check.tscn \
##       [--rendering-method mobile] -- [--preset <quality id>] [--frames N] [--out <dir>]
## Prints one line per frame, then RESULT PASS or FAIL (exit code 0 or 1).

const CLEAR := Color(1.0, 0.0, 1.0)
const SETTLE_FRAMES := 3


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var preset := _arg(args, "--preset", "")
	var frames := int(_arg(args, "--frames", "24"))
	var out := _arg(args, "--out", "")
	if DisplayServer.get_name() == "headless":
		printerr("terrain check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	if preset != "" and not Quality.apply(preset, get_viewport()):
		get_tree().quit(2)
		return
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	var world := WorldData.new()
	add_child(world)
	var terrain := Terrain.new()
	add_child(terrain)
	if not world.load_dir(WorldData.default_dir()) or not terrain.setup(world):
		printerr("terrain check: %s" % ", ".join(world.errors + terrain.errors))
		get_tree().quit(2)
		return
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.05
	cam.far = 12000.0
	add_child(cam)
	cam.make_current()
	_add_light_and_clear()
	var flight := TerrainFlight.new(world)
	var method := RenderingServer.get_current_rendering_method()
	var total := 0
	for i in frames:
		cam.global_transform = flight.pose(flight.duration_s * i / frames)
		for f in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var holes := count_holes(img)
		total += holes
		print(
			(
				"frame %02d: %d instances, %d clear pixels under terrain"
				% [i, terrain.instances, holes]
			)
		)
		if out != "":
			img.save_png(out.path_join("terrain_%s_%02d.png" % [method, i]))
	print(
		(
			"RESULT %s (%s, %d frames, %d pixels)"
			% ["PASS" if total == 0 else "FAIL", method, frames, total]
		)
	)
	get_tree().quit(0 if total == 0 else 1)


## Clear-colour pixels with a non-clear pixel above them in the same column.
static func count_holes(img: Image) -> int:
	var holes := 0
	for x in img.get_width():
		var ground := false
		for y in img.get_height():
			var c := img.get_pixel(x, y)
			if not (c.r > 0.95 and c.g < 0.05 and c.b > 0.95):
				ground = true
			elif ground:
				holes += 1
	return holes


func _add_light_and_clear() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, -60.0, 0.0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = CLEAR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	add_child(env)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
