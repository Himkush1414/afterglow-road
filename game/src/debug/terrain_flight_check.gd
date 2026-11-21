extends Node3D
## T-05-3 (b): renders frames along the terrain flight with a magenta clear
## colour and counts magenta pixels below terrain in the same screen column.
## With no camera roll a column is a vertical plane, so such a pixel is a
## crack or a wrongly culled patch. Anti-aliasing is turned off after the
## preset is applied, so edge blends cannot pass for holes or hide one.
## Needs a display:
##   tools/godot.sh res://scenes/debug/terrain_flight_check.tscn \
##       [--rendering-method mobile] -- [--preset <id>] [--frames N] [--out <abs dir>] [--biomes]
## Prints one line per frame, then RESULT PASS or FAIL (exit code 0 or 1).
## --biomes: instead of the flight, one ground-level view per biome, from the
## cell with the most cells of the same biome around it (review frames).

const CLEAR := Color(1.0, 0.0, 1.0)
const SETTLE_FRAMES := 3
## Biome views: eye height, downward pitch, the scan step and window in cells.
const BIOME_EYE_M := 3.0
const BIOME_PITCH_DEG := 25.0
const BIOME_STEP := 4
const BIOME_WINDOW := 4


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
	var poses: Array[Transform3D] = []
	var labels: Array[String] = []
	if "--biomes" in args:
		var views := biome_views(world)
		for id: int in views:
			poses.append(views[id])
			labels.append("biome_%d" % id)
	else:
		var flight := TerrainFlight.new(world)
		for i in frames:
			poses.append(flight.pose(flight.duration_s * i / frames))
			labels.append("%02d" % i)
	var method := RenderingServer.get_current_rendering_method()
	var total := 0
	for i in poses.size():
		cam.global_transform = poses[i]
		for f in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var holes := count_holes(img)
		total += holes
		print(
			(
				"frame %s: %d instances, %d clear pixels under terrain"
				% [labels[i], terrain.instances, holes]
			)
		)
		if out != "":
			img.save_png(out.path_join("terrain_%s_%s.png" % [method, labels[i]]))
	print(
		(
			"RESULT %s (%s, %d frames, %d pixels)"
			% ["PASS" if total == 0 else "FAIL", method, poses.size(), total]
		)
	)
	get_tree().quit(0 if total == 0 else 1)


## One camera pose per biome id present: at the scanned cell with the most
## cells of its own biome within BIOME_WINDOW cells, a little above ground.
static func biome_views(world: WorldData) -> Dictionary:
	var best := {}
	var score := {}
	var cell := WorldData.BIOME_CELL_M
	var n := world.biome_cells
	for j in range(BIOME_WINDOW, n - BIOME_WINDOW, BIOME_STEP):
		for i in range(BIOME_WINDOW, n - BIOME_WINDOW, BIOME_STEP):
			var at := world.map_to_world(Vector3((i + 0.5) * cell, 0.0, (j + 0.5) * cell))
			var id := world.biome_at(at.x, at.z)
			var same := 0
			for dj in range(-BIOME_WINDOW, BIOME_WINDOW + 1):
				for di in range(-BIOME_WINDOW, BIOME_WINDOW + 1):
					same += 1 if world.biome_at(at.x + di * cell, at.z + dj * cell) == id else 0
			if same > int(score.get(id, -1)):
				score[id] = same
				best[id] = at
	var out := {}
	var ids := best.keys()
	ids.sort()
	for id: int in ids:
		var p: Vector3 = best[id]
		p.y = world.height_at(p.x, p.z) + BIOME_EYE_M
		var forward := Vector3(
			cos(deg_to_rad(BIOME_PITCH_DEG)), -sin(deg_to_rad(BIOME_PITCH_DEG)), 0.0
		)
		out[id] = Transform3D(Basis.looking_at(forward, Vector3.UP), p)
	return out


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
