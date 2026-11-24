extends Node
## Far tree tier (P5-04, 06 §A3 T3) on the active world: from a viewpoint,
## streams the billboard tiles with the given preset's ranges and checks that
## - every tree whose distance is within the T3 end has a billboard instance
##   (tiles built = tiles within reach; instance count = trees in them);
## - no tile beyond reach + keep margin stays built;
## and reports the build time per tile. With a display and an output path it
## also saves a frame looking along `heading` from the viewpoint.
##   tools/godot.sh [--headless] res://scenes/debug/tree_far_check.tscn \
##       -- <preset> <map x> <map z> [<heading deg> <frame.png>]
## Prints the results, then RESULT PASS or FAIL (exit 0 or 1).

const SETTLE_FRAMES := 3000

var _world: WorldData
var _field: TreeField


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var presets: Dictionary = ContentDB.tuning("quality").get("presets", {})
	if args.size() < 3 or not presets.has(args[0]):
		printerr("tree far check: needs -- <preset> <map x> <map z> [<heading> <frame.png>]")
		get_tree().quit(2)
		return
	var tiers: Array = presets[args[0]].get("tree_tiers_m", [])
	_world = WorldData.new()
	add_child(_world)
	if not _world.load_dir(WorldData.default_dir()):
		printerr("tree far check: %s" % ", ".join(_world.errors))
		get_tree().quit(2)
		return
	var defs: Array = ContentDB.ids("trees").map(
		func(id: String) -> Dictionary: return ContentDB.entry("trees", id)
	)
	_field = TreeField.new()
	add_child(_field)
	if not _field.setup(_world, defs, ContentDB.tuning("trees"), tiers):
		printerr("tree far check: %s" % ", ".join(_field.errors))
		get_tree().quit(2)
		return
	var map := Vector3(float(args[1]), 0.0, float(args[2]))
	var eye := _world.map_to_world(map)
	eye.y = _world.height_at(eye.x, eye.z) + 1.62
	var t0 := Time.get_ticks_msec()
	for i in SETTLE_FRAMES:
		_field.update_for(eye)
		if _field.is_settled() and not _field.built_tiles().is_empty():
			break
		await get_tree().process_frame
	var seconds := (Time.get_ticks_msec() - t0) / 1000.0
	var bad := 0
	var wanted := _field.tiles_within(eye, _field.reach_m())
	var built := _field.built_tiles()
	var tiles_ok := (
		built.size() == wanted.size() and wanted.all(func(t: Vector2i) -> bool: return built.has(t))
	)
	bad += int(not tiles_ok)
	print(
		(
			"tiles: %d built, %d within %.0f m of the eye%s"
			% [built.size(), wanted.size(), _field.reach_m(), _flag(tiles_ok)]
		)
	)
	# Every tree within the T3 end lies in a built tile and is drawn there.
	var in_range := 0
	var missing := 0
	var drawn := 0
	for t: Vector2i in built:
		drawn += int(_field.tile_buffer(t)[1])
	var per := int(TreeField.TILE_M / WorldData.TREE_CHUNK_M)
	var t3_end := float(tiers[TreeField.T3])
	var side := WorldData.TREE_CHUNKS_PER_SIDE
	for cz in side:
		for cx in side:
			var chunk := Vector2i(cx, cz)
			var raw := _field.chunk_records(chunk)
			for i in raw.size() / TreeField.RECORD_BYTES:
				var r := TreeField.decode(raw, chunk, i)
				if Vector2(r.map.x - map.x, r.map.y - map.z).length() > t3_end:
					continue
				in_range += 1
				if not built.has(Vector2i(cx / per, cz / per)):
					missing += 1
	var cover_ok := missing == 0 and in_range > 0 and drawn == _field.instances
	bad += int(not cover_ok)
	print(
		(
			"trees within %.0f m: %d, outside a built tile: %d; instances %d (tiles hold %d)%s"
			% [t3_end, in_range, missing, _field.instances, drawn, _flag(cover_ok)]
		)
	)
	print(
		(
			"build: %.2f s for %d tiles (%.0f ms per tile, %d worker builds at a time)"
			% [
				seconds,
				built.size(),
				seconds * 1000.0 / maxf(built.size(), 1),
				TreeField.MAX_BUILDS
			]
		)
	)
	if args.size() >= 5 and DisplayServer.get_name() != "headless":
		await _frame(eye, float(args[3]), args[4])
	print("RESULT %s" % ["PASS" if bad == 0 else "FAIL"])
	get_tree().quit(0 if bad == 0 else 1)


func _frame(eye: Vector3, heading_deg: float, path: String) -> void:
	var cam := Camera3D.new()
	cam.far = 4000.0
	cam.fov = 60.0
	add_child(cam)
	var h := deg_to_rad(heading_deg)
	cam.look_at_from_position(eye, eye + Vector3(sin(h), -0.02, -cos(h)))
	cam.make_current()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, heading_deg + 150.0, 0.0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.72, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.58, 0.62)
	add_child(env)
	var terrain := Terrain.new()
	add_child(terrain)
	terrain.setup(_world)
	for i in 30:
		terrain.update_for(cam)
		_field.update_for(eye)
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("frame: %s" % path)


func _flag(ok: bool) -> String:
	return "" if ok else "  FAIL"
