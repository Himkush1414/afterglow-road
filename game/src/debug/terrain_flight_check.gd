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
## --water: review views of each lake, river and the sea with the water
## drawn under a plain sky; no hole verdict (RESULT REVIEW).
## --cliffs: review views of the three regions with the most cliff faces,
## regions streamed around the camera (RESULT REVIEW).

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
	var review_water := "--water" in args
	var review_cliffs := "--cliffs" in args
	_add_light_and_clear(review_water or review_cliffs)
	var streamer: Streamer = null
	var poses: Array[Transform3D] = []
	var labels: Array[String] = []
	if review_cliffs:
		streamer = Streamer.new()
		add_child(streamer)
		streamer.setup(world)
		streamer.track(cam)
		var views := cliff_views(world)
		for label: String in views:
			poses.append(views[label])
			labels.append(label)
	elif review_water:
		var water := Water.new()
		add_child(water)
		if not water.setup(world):
			printerr("terrain check: %s" % ", ".join(water.errors))
			get_tree().quit(2)
			return
		water.build(terrain.height_texture())
		var views := water_views(world, water)
		for label: String in views:
			poses.append(views[label])
			labels.append(label)
	elif "--biomes" in args:
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
		if streamer != null:
			for k in 200:
				streamer.update()
		for f in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var holes := count_holes(img)
		total += holes
		var tris := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
		)
		print(
			(
				"frame %s: %d instances, %d clear pixels under terrain, %d triangles"
				% [labels[i], terrain.instances, holes, tris]
			)
		)
		if out != "":
			img.save_png(out.path_join("terrain_%s_%s.png" % [method, labels[i]]))
	var verdict := "REVIEW" if review_water or review_cliffs else ("PASS" if total == 0 else "FAIL")
	print("RESULT %s (%s, %d frames, %d pixels)" % [verdict, method, poses.size(), total])
	get_tree().quit(0 if verdict != "FAIL" else 1)


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


## Review poses over each water body, 3 m above the surface: across each
## lake from its middle, down each river from its middle, and out to sea
## from the last river point (a mouth).
static func water_views(world: WorldData, water: Water) -> Dictionary:
	var out := {}
	var pitch := deg_to_rad(15.0)
	for lake: Dictionary in water.lakes():
		var poly: PackedVector2Array = lake.polygon
		var c := Vector2.ZERO
		for v in poly:
			c += v
		c /= poly.size()
		out["lake_%s" % lake.id] = _view(world, c, poly[0] - c, lake.level + 3.0, pitch)
	for r: Dictionary in water.rivers():
		var centre: PackedVector2Array = r.centre
		var level: PackedFloat32Array = r.level
		var i := centre.size() / 2
		out["river_%s" % r.id] = _view(
			world, centre[i], centre[i + 1] - centre[i], level[i] + 3.0, pitch
		)
	if not water.rivers().is_empty():
		var c: PackedVector2Array = water.rivers()[-1].centre
		var n := c.size()
		out["sea"] = _view(world, c[n - 1], c[n - 1] - c[n - 2], water.sea_level + 6.0, pitch)
	return out


## Review poses facing a cliff face of each of the three regions with the
## most faces, 40 m downhill of it and 12 m up.
static func cliff_views(world: WorldData) -> Dictionary:
	var index: Variant = JSON.parse_string(world.read_text("regions/index.json"))
	var ranked := []
	if index is Dictionary:
		for name: String in index.files:
			var doc: Variant = JSON.parse_string(world.read_indexed("regions", name))
			var rows: Array = []
			for r: Array in ((doc as Dictionary).objects.get("cliff", {}) as Dictionary).values():
				rows.append_array(r)
			if not rows.is_empty():
				ranked.append([rows.size(), name, rows[rows.size() / 2]])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out := {}
	for entry: Array in ranked.slice(0, 3):
		var row: Array = entry[2]
		var target := world.map_to_world(Vector3(row[1], row[2], row[3]))
		var yaw := deg_to_rad(float(row[4]))
		var down := Vector3(sin(yaw), 0.0, -cos(yaw))
		var eye := target + down * 40.0
		eye.y = maxf(world.height_at(eye.x, eye.z), target.y) + 12.0
		var label := "cliffs_%s" % str(entry[1]).trim_suffix(".json")
		out[label] = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
	return out


static func _view(
	world: WorldData, map_xz: Vector2, dir: Vector2, y: float, pitch: float
) -> Transform3D:
	var p := world.map_to_world(Vector3(map_xz.x, 0.0, map_xz.y))
	p.y = maxf(y, world.height_at(p.x, p.z) + 2.0)
	var d := dir.normalized()
	var forward := Vector3(d.x * cos(pitch), -sin(pitch), d.y * cos(pitch))
	return Transform3D(Basis.looking_at(forward, Vector3.UP), p)


func _add_light_and_clear(sky: bool = false) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, -60.0, 0.0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	if sky:
		env.environment.background_mode = Environment.BG_SKY
		env.environment.sky = Sky.new()
		env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	else:
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = CLEAR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	add_child(env)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
