extends Node
## Tree tiers on the active world (06 §A3):
## - T-06-1: along a fly-through, every tree within the T3 end + band has
##   exactly one tier with non-zero visibility, or, inside a hand-over band,
##   exactly the two adjacent tiers with visibilities summing to 1; and every
##   tier a tree is visible in holds it (near set, built chunk, built tile).
## - T-06-6: the near-set rebuild's main-thread part (buffer assignment) in
##   the densest chunk takes ≤ 1 ms.
## - With a display: draw calls and triangles of a frame at the start point.
##   tools/godot.sh [--headless] res://scenes/debug/tree_tiers_check.tscn \
##       -- <preset> <map x> <map z> <heading deg> [<frame.png> [<steps>]]
## Prints the results, then RESULT PASS or FAIL (exit 0 or 1).

const STEPS := 12
const STEP_M := 37.0
const SETTLE_FRAMES := 3000
const ASSIGN_LIMIT_USEC := 1000
const EPS := 1e-4
const NEAR_STEP := 40.0

var _world: WorldData
var _field: TreeField
var _tiers: Array = []
var _band := 0.0
var _preset := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var presets: Dictionary = ContentDB.tuning("quality").get("presets", {})
	if args.size() < 4 or not presets.has(args[0]):
		printerr("tree tiers check: needs -- <preset> <map x> <map z> <heading> [<frame.png>]")
		get_tree().quit(2)
		return
	_preset = presets[args[0]]
	_tiers = _preset.get("tree_tiers_m", [])
	var cfg := ContentDB.tuning("trees")
	_band = float(cfg.get("fade_band_m", 0.0))
	_world = WorldData.new()
	add_child(_world)
	if not _world.load_dir(WorldData.default_dir()):
		printerr("tree tiers check: %s" % ", ".join(_world.errors))
		get_tree().quit(2)
		return
	var defs: Array = ContentDB.ids("trees").map(
		func(id: String) -> Dictionary: return ContentDB.entry("trees", id)
	)
	_field = TreeField.new()
	_field.t2_shadows = presets[args[0]].get("t2_tree_shadows", false) == true
	_field.near_sectors = int(presets[args[0]].get("tree_near_sectors", 1))
	add_child(_field)
	if not _field.setup(_world, defs, cfg, _tiers):
		printerr("tree tiers check: %s" % ", ".join(_field.errors))
		get_tree().quit(2)
		return
	var start := Vector3(float(args[1]), 0.0, float(args[2]))
	var h := deg_to_rad(float(args[3]))
	var dir := Vector3(sin(h), 0.0, -cos(h))
	var bad := 0
	var worst_usec := 0
	var steps := int(args[5]) if args.size() >= 6 else STEPS
	for step in steps:
		var map := start + dir * STEP_M * step
		await _settle(map)
		worst_usec = maxi(worst_usec, _field.near_assign_usec)
		bad += _check_tiers(map, step)
	# T-06-6 in the densest chunk.
	var dense := _densest_chunk()
	var centre := Vector3(
		(dense.x + 0.5) * WorldData.TREE_CHUNK_M, 0.0, (dense.y + 0.5) * WorldData.TREE_CHUNK_M
	)
	await _settle(centre)
	await _settle(centre + Vector3(NEAR_STEP, 0.0, 0.0))
	var dense_usec := _field.near_assign_usec
	var assign_ok := dense_usec <= ASSIGN_LIMIT_USEC
	bad += int(not assign_ok)
	print(
		(
			"T-06-6: near assign %.3f ms, densest chunk %s (%d trees); route worst %.3f; limit %.1f%s"
			% [
				dense_usec / 1000.0,
				str(dense),
				_field.chunk_records(dense).size() / TreeField.RECORD_BYTES,
				worst_usec / 1000.0,
				ASSIGN_LIMIT_USEC / 1000.0,
				_flag(assign_ok),
			]
		)
	)
	print(
		(
			"near set there: T0 %d, T1 %d instances"
			% [_field.near_instances[0], _field.near_instances[1]]
		)
	)
	if DisplayServer.get_name() != "headless":
		await _frame(start, h, args[4] if args.size() >= 5 and args[4] != "-" else "")
	print("RESULT %s" % ["PASS" if bad == 0 else "FAIL"])
	get_tree().quit(0 if bad == 0 else 1)


func _settle(map: Vector3) -> void:
	var eye := _world.map_to_world(map)
	eye.y = _world.height_at(eye.x, eye.z) + 1.62
	for i in SETTLE_FRAMES:
		_field.update_for(eye)
		if _field.is_settled() and _field.near_map.distance_to(map) < TreeField.NEAR_LINE_M * 1.5:
			return
		await get_tree().process_frame


## Fails (returns 1) when a tree near `map` breaks T-06-1.
func _check_tiers(map: Vector3, step: int) -> int:
	var reach := float(_tiers[TreeField.T3]) + _band
	var tiles := _field.built_tiles()
	var chunks := _field.built_chunks()
	var windows := [_field.near_window(TreeField.T0), _field.near_window(TreeField.T1)]
	var per := int(TreeField.TILE_M / WorldData.TREE_CHUNK_M)
	var lo := WorldData.tree_chunk_of_map(map - Vector3(reach, 0.0, reach))
	var hi := WorldData.tree_chunk_of_map(map + Vector3(reach, 0.0, reach))
	var trees := 0
	var wrong_count := 0
	var not_held := 0
	var mid_hidden := [0, 0]  # nearer than the T2 range, beyond it
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var chunk := Vector2i(cx, cz)
			var raw := _field.chunk_records(chunk)
			for i in raw.size() / TreeField.RECORD_BYTES:
				var r := TreeField.decode(raw, chunk, i)
				var d := Vector2(r.map.x - map.x, r.map.y - map.z).length()
				if d > reach:
					continue
				trees += 1
				if chunks.has(chunk):
					var v2 := TreeShading.visibility(TreeField.T2, d, _tiers, _band)
					if (v2.x if v2.x < 0.999 else v2.y) <= EPS:
						mid_hidden[int(d > float(_tiers[TreeField.T2]))] += 1
				var shown: Array = []
				var total := 0.0
				for k in 4:
					var v := TreeShading.visibility(k, d, _tiers, _band)
					var vis := v.x if v.x < 0.999 else v.y
					if vis <= EPS:
						continue
					shown.append(k)
					total += vis
					var held := false
					match k:
						0, 1:
							var dn := (
								Vector2(r.map.x - _field.near_map.x, r.map.y - _field.near_map.z)
								. length()
							)
							held = (
								dn >= (windows[k] as Vector2).x and dn <= (windows[k] as Vector2).y
							)
						2:
							held = chunks.has(chunk)
						3:
							held = tiles.has(Vector2i(cx / per, cz / per))
					not_held += int(not held)
				var ok: bool = (
					shown.size() == 1
					or (
						shown.size() == 2
						and _next_tier(shown[0]) == shown[1]
						and absf(total - 1.0) < 1e-3
					)
				)
				if d < float(_tiers[TreeField.T3]) - _band and not ok:
					wrong_count += 1
	var ok_step := wrong_count == 0 and not_held == 0 and trees > 0
	print(
		(
			(
				"T-06-1 step %d: %d trees, wrong tier count %d, visible but not held %d%s;"
				+ " mid tier holds %d, hidden %d nearer and %d beyond"
			)
			% [
				step,
				trees,
				wrong_count,
				not_held,
				_flag(ok_step),
				_field.mid_instances,
				mid_hidden[0],
				mid_hidden[1],
			]
		)
	)
	return int(not ok_step)


## The next tier after k with a non-empty range (empty tiers are skipped
## in a hand-over), or -1.
func _next_tier(k: int) -> int:
	for j in range(k + 1, 4):
		var start := 0.0 if j == 0 else float(_tiers[j - 1])
		if float(_tiers[j]) > start:
			return j
	return -1


func _densest_chunk() -> Vector2i:
	var index: Dictionary = _world.index_of("trees").get("files", {})
	var best := ""
	for name: String in index:
		if best == "" or int(index[name].count) > int(index[best].count):
			best = name
	var parts := best.get_basename().split("_")
	return Vector2i(int(parts[0]), int(parts[1]))


func _frame(start: Vector3, heading: float, path: String) -> void:
	var eye := _world.map_to_world(start)
	eye.y = _world.height_at(eye.x, eye.z) + 1.62
	await _settle(start)
	var cam := Camera3D.new()
	cam.far = 4000.0
	cam.fov = 70.0
	add_child(cam)
	cam.look_at_from_position(eye, eye + Vector3(sin(heading), 0.05, -cos(heading)))
	cam.make_current()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, rad_to_deg(heading) + 150.0, 0.0)
	sun.shadow_enabled = true
	# The preset's sun shadows (23 §3).
	sun.directional_shadow_max_distance = float(_preset.get("shadow_distance_m", 100.0))
	sun.directional_shadow_mode = ([
		DirectionalLight3D.SHADOW_ORTHOGONAL,
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
	][clampi(int(_preset.get("shadow_cascades", 4)), 1, 4) - 1])
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
	var vp := get_viewport().get_viewport_rid()
	var calls := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	var prims := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
	)
	var shadow_calls := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	var shadow_prims := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
	)
	var kinds := {}
	for node in _field.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if not mmi.visible or mmi.multimesh.instance_count == 0:
			continue
		var kind := String(mmi.name).get_slice("_", 0)
		if String(mmi.name).contains("shadow"):
			kind += "_shadow"
		kinds[kind] = int(kinds.get(kind, 0)) + mmi.multimesh.mesh.get_surface_count()
	print("tree surfaces by kind (before culling): %s" % str(kinds))
	print(
		(
			"frame (terrain + trees): %d draw calls, %d triangles; shadow passes %d draw calls, %d triangles"
			% [calls, prims, shadow_calls, shadow_prims]
		)
	)
	if path != "":
		get_viewport().get_texture().get_image().save_png(path)
		print("frame: %s" % path)
	_field.visible = false
	for i in 3:
		await RenderingServer.frame_post_draw
	var t_calls := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	var t_prims := RenderingServer.viewport_get_render_info(
		vp,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
	)
	print("terrain alone: %d draw calls, %d triangles" % [t_calls, t_prims])
	_field.visible = true


func _flag(ok: bool) -> String:
	return "" if ok else "  FAIL"
