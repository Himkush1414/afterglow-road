extends TestCase
## WorldData: loading, T-05-2 on the active world, biome and index queries.

var _world: WorldData


func before_each() -> void:
	_world = WorldData.new()


func after_each() -> void:
	_world.free()


func _load_active() -> bool:
	if not check(_world.load_dir(WorldData.default_dir()), "load: %s" % ", ".join(_world.errors)):
		return false
	return true


# gdlint:ignore = function-name
func test_T_05_2() -> void:
	# the active world, and the public sample world (what CI has)
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
			continue
		var doc: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(dir + "/height_points.json")
		)
		if not check(doc is Dictionary, "%s/height_points.json" % dir):
			continue
		var points: Array = doc["points"]
		check_eq(points.size(), 1000, "point count")
		var worst := 0.0
		for p: Array in points:
			var pos := _world.map_to_world(Vector3(float(p[0]), 0.0, float(p[1])))
			worst = maxf(worst, absf(_world.height_at(pos.x, pos.z) - float(p[2])))
		check(worst <= 0.01, "%s: height_at differs by %.4f m (limit 0.01)" % [dir, worst])


func test_read_layer_decodes_the_lod_and_normal_files() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
			continue
		var texels := int(round(_world.size_m / 4.0))
		check_eq(_world.read_layer("normal.bin", texels * texels * 2).size(), texels * texels * 2)
		var nodes := 0
		var k := int(round(_world.size_m / 64.0))
		while k >= 2:
			nodes += k * k
			k /= 2
		check_eq(_world.read_layer("minmax.bin", nodes * 4).size(), nodes * 4, dir)
		check(_world.errors.is_empty(), ", ".join(_world.errors))
		check(_world.read_layer("minmax.bin", nodes * 4 + 4).is_empty(), "wrong size refused")
		check(_world.errors.size() == 1 and "minmax.bin" in _world.errors[0], "error names it")


func test_a_changed_file_is_refused() -> void:
	var dir := "user://world_test_copy"
	DirAccess.make_dir_recursive_absolute(dir)
	for f: String in ["meta.json", "height.bin", "biome.bin"]:
		DirAccess.copy_absolute(WorldData.default_dir() + "/" + f, dir + "/" + f)
	var bytes := FileAccess.get_file_as_bytes(dir + "/biome.bin")
	bytes[bytes.size() - 1] ^= 1
	var out := FileAccess.open(dir + "/biome.bin", FileAccess.WRITE)
	out.store_buffer(bytes)
	out.close()
	check(not _world.load_dir(dir), "a changed file must be refused")
	check(_world.errors.size() == 1 and "biome.bin" in _world.errors[0], "error names the file")
	check(not _world.is_loaded(), "no data kept")
	for f: String in ["meta.json", "height.bin", "biome.bin"]:
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)


func test_height_at_on_samples_and_triangles() -> void:
	if not _load_active():
		return
	var s := _world.sample_m
	var corner := _world.map_to_world(Vector3(10 * s, 0.0, 20 * s))
	check_near(_world.height_at(corner.x, corner.z), _world.sample(10, 20), 1e-6, "on a sample")
	var mid := _world.map_to_world(Vector3(10.5 * s, 0.0, 20.5 * s))
	var diag := (_world.sample(11, 20) + _world.sample(10, 21)) / 2.0
	check_near(
		_world.height_at(mid.x, mid.z), diag, 1e-6, "cell centre lies on the (1,0)-(0,1) diagonal"
	)
	var beyond := _world.map_to_world(Vector3(-50.0, 0.0, -50.0))
	check_near(
		_world.height_at(beyond.x, beyond.z), _world.sample(0, 0), 1e-6, "clamped outside the map"
	)


func test_biome_and_indices() -> void:
	if not _load_active():
		return
	var p := _world.map_to_world(Vector3(1.0, 0.0, 1.0))
	check(_world.biome_at(p.x, p.z) >= 0, "a biome id")
	check_eq(WorldData.region_of_map(Vector3(513.0, 0.0, 1023.0)), Vector2i(1, 1))
	check_eq(WorldData.region_index(Vector2i(3, 2)), 35)
	check_eq(WorldData.tree_chunk_of_map(Vector3(129.0, 0.0, 300.0)), Vector2i(1, 2))
	check_eq(WorldData.tree_chunk_index(Vector2i(1, 2)), 129)
