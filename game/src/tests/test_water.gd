extends TestCase
## Water API (05 §7): surface, depth and kind for the sea, lakes, rivers and
## streams of water.json, on the active and the sample world.

var _world: WorldData
var _water: Water


func before_each() -> void:
	_world = WorldData.new()
	_water = Water.new()


func after_each() -> void:
	_water.free()
	_world.free()


func _load(dir: String) -> bool:
	if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
		return false
	return check(_water.setup(_world), "water %s: %s" % [dir, ", ".join(_water.errors)])


func _at(map_x: float, map_z: float) -> Vector3:
	return _world.map_to_world(Vector3(map_x, 0.0, map_z))


func test_every_river_point_reports_its_level() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _load(dir):
			continue
		check(not _water.rivers().is_empty(), "%s has rivers" % dir)
		for r: Dictionary in _water.rivers():
			var centre: PackedVector2Array = r.centre
			var level: PackedFloat32Array = r.level
			var worst := 0.0
			var wet := 0
			for i in centre.size():
				var p := _at(centre[i].x, centre[i].y)
				if level[i] <= _world.height_at(p.x, p.z):
					continue
				wet += 1
				check_eq(_water.kind_at(p), r.kind, "%s point %d" % [r.id, i])
				worst = maxf(worst, absf(_water.surface_y(p) - level[i]))
			check(wet > centre.size() / 2, "%s: %d of %d wet" % [r.id, wet, centre.size()])
			check(worst <= 0.01, "%s: level differs by %.4f m" % [r.id, worst])


func test_lakes_report_their_level_inside_and_nothing_outside() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _load(dir):
			continue
		for lake: Dictionary in _water.lakes():
			var poly: PackedVector2Array = lake.polygon
			var c := Vector2.ZERO
			for v in poly:
				c += v
			c /= poly.size()
			var p := _at(c.x, c.y)
			check_eq(_water.kind_at(p), Water.LAKE, "%s centre" % lake.id)
			check_eq(_water.surface_y(p), lake.level, "%s level" % lake.id)
			check_near(_water.depth_at(p), lake.level - _world.height_at(p.x, p.z), 1e-4)


func test_the_sea_covers_ground_below_sea_level() -> void:
	if not _load(WorldData.default_dir()):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var seen := 0
	for k in 4000:
		var p := _at(rng.randf() * _world.size_m, rng.randf() * _world.size_m)
		var bed := _world.height_at(p.x, p.z)
		var kind := _water.kind_at(p)
		if bed < _water.sea_level and kind == Water.SEA:
			seen += 1
			check_eq(_water.surface_y(p), _water.sea_level)
		elif kind == Water.SEA:
			fail("sea over ground at %.2f m" % bed)
	check(seen > 0 or ContentDB.root == ContentDB.SAMPLE_ROOT, "random points found sea")


func test_surface_is_above_the_ground_or_absent() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _load(dir):
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = 10
		var wrong := 0
		for k in 3000:
			var p := _at(rng.randf() * _world.size_m, rng.randf() * _world.size_m)
			var s := _water.surface_y(p)
			var bed := _world.height_at(p.x, p.z)
			if s == -INF:
				wrong += 1 if (_water.depth_at(p) != 0.0 or _water.kind_at(p) != &"") else 0
			else:
				wrong += 1 if (s <= bed or absf(_water.depth_at(p) - (s - bed)) > 1e-4) else 0
		check_eq(wrong, 0, "%s: inconsistent answers" % dir)


func test_stream_ribbon_ends_at_its_width() -> void:
	if not _load(ContentDB.SAMPLE_ROOT + "/world"):
		return
	var r: Dictionary = _water.rivers()[0]
	var centre: PackedVector2Array = r.centre
	var width: PackedFloat32Array = r.width
	# the deepest centre point, so a bank that rises sideways stays under water
	var i := 0
	for k in centre.size() - 1:
		if (
			_water.depth_at(_at(centre[k].x, centre[k].y))
			> _water.depth_at(_at(centre[i].x, centre[i].y))
		):
			i = k
	var c := centre[i]
	var along := (centre[i + 1] - c).normalized()
	var side := Vector2(-along.y, along.x)
	var half := width[i] * 0.5
	check_eq(_water.kind_at(_at(c.x + side.x * half * 0.5, c.y + side.y * half * 0.5)), r.kind)
	var outside := _at(c.x + side.x * half * 1.5, c.y + side.y * half * 1.5)
	check(_water.kind_at(outside) != r.kind, "beyond the ribbon")


func test_a_changed_water_file_is_refused() -> void:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), "load"):
		return
	var dir := "user://water_test_copy"
	DirAccess.make_dir_recursive_absolute(dir)
	for f: String in ["meta.json", "height.bin", "biome.bin", "water.json"]:
		DirAccess.copy_absolute(ContentDB.SAMPLE_ROOT + "/world/" + f, dir + "/" + f)
	var out := FileAccess.open(dir + "/water.json", FileAccess.READ_WRITE)
	out.seek(2)
	out.store_8(0x20)
	out.close()
	check(_world.load_dir(dir), "load the copy")
	check(not _water.setup(_world), "a changed water file is refused")
	check(_water.errors.size() == 1 and "water.json" in _water.errors[0], "error names it")
	for f: String in ["meta.json", "height.bin", "biome.bin", "water.json"]:
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)


func test_the_game_sets_up_its_water() -> void:
	check_eq(await App.start_game("slot_1", true), OK)
	await tree.process_frame
	var game := Game.current
	if check(game != null, "game scene running"):
		check(not game.water.rivers().is_empty(), "water loaded in the game")


func test_build_makes_sea_lake_and_river_surfaces() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _load(dir):
			continue
		_water.build(ImageTexture.new())
		check_eq(_water.sea.get_child_count(), 2, "sea grid and far ring")
		check_eq(_water.lake_meshes.size(), _water.lakes().size(), "one mesh per lake")
		check(_water.river_meshes.size() >= _water.rivers().size(), "river pieces")
		var cfg := ContentDB.tuning("water")
		var off_level := 0
		var off_ribbon := 0
		var bad_speed := 0
		var points := 0
		for node in _water.river_meshes:
			var arr := node.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
			for k in verts.size():
				points += 1
				var v := verts[k]
				# a vertex on the ribbon edge: just inside it the water is at that level
				var inward := _water.surface_y(v.lerp(_ribbon_centre(v), 0.05))
				if inward != -INF and absf(inward - v.y) > 0.05:
					off_level += 1
				if _water.kind_at(v.lerp(_ribbon_centre(v), 0.05)) == &"":
					off_ribbon += 1 if inward != -INF else 0
				var sp := uv2[k].x
				if sp < cfg.flow_min_mps - 1e-4 or sp > cfg.flow_max_mps + 1e-4:
					bad_speed += 1
		check(points > 0, "ribbon vertices")
		check_eq(off_level, 0, "%s: ribbon edges off the river level" % dir)
		check_eq(bad_speed, 0, "%s: flow speed outside the range" % dir)
		var lake: MeshInstance3D = (
			_water.lake_meshes[0] if not _water.lake_meshes.is_empty() else null
		)
		if lake != null:
			check_near(lake.get_aabb().position.y, _water.lakes()[0].level, 1e-3, "lake mesh level")


func test_the_sea_follows_the_camera_in_quad_steps() -> void:
	if not _load(WorldData.default_dir()):
		return
	_water.build(ImageTexture.new())
	_water.follow(Vector3(1003.0, 50.0, -2005.0))
	var step := Water.SEA_GRID_M / Water.SEA_GRID_QUADS
	check_eq(
		_water.sea.position,
		Vector3(snappedf(1003.0, step), _water.sea_level, snappedf(-2005.0, step))
	)


## The nearest river centre point to `v` (engine), at v's height.
func _ribbon_centre(v: Vector3) -> Vector3:
	var best := INF
	var out := v
	var m := _world.world_to_map(v)
	for r: Dictionary in _water.rivers():
		var c: PackedVector2Array = r.centre
		for p in c:
			var d := Vector2(m.x, m.z).distance_squared_to(p)
			if d < best:
				best = d
				out = _world.map_to_world(Vector3(p.x, v.y, p.y))
	return Vector3(out.x, v.y, out.z)
