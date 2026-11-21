extends TestCase
## Region content: the region file is read (hash-checked through its index),
## cliff faces are drawn per type and collide on the static-world and
## wind-blocker layers, placed on the slope their row describes.

var _world: WorldData
var _streamer: Streamer
var _body: Node3D


func before_each() -> void:
	_world = WorldData.new()
	_streamer = Streamer.new()
	_body = Node3D.new()
	tree.root.add_child(_streamer)
	tree.root.add_child(_body)


func after_each() -> void:
	_body.free()
	_streamer.free()
	_world.free()


func _active_region(dir: String, region: Vector2i) -> Region:
	if not check(_world.load_dir(dir), ", ".join(_world.errors)):
		return null
	_streamer.setup(_world)
	_streamer.track(_body)
	var m := Vector3(
		(region.x + 0.5) * WorldData.REGION_M, 0.0, (region.y + 0.5) * WorldData.REGION_M
	)
	_body.global_position = _world.map_to_world(m)
	for i in 100:
		_streamer.update()
		if _streamer.state_of(region) == Region.State.ACTIVE:
			break
	check_eq(_streamer.state_of(region), Region.State.ACTIVE, "region loaded")
	return _streamer.region_node(region)


func test_the_sample_region_reads_its_file_and_builds_its_cliff() -> void:
	var region := _active_region(ContentDB.SAMPLE_ROOT + "/world", Vector2i(0, 0))
	if region == null:
		return
	check(region.objects.has("node") and region.objects.has("cliff"), "objects read")
	var draws := region.cliff_draws()
	if not check(draws.size() == 1, "one cliff cell"):
		return
	check_eq(draws[0].multimesh.instance_count, 1)
	var body := region.get_node("Cliffs") as StaticBody3D
	check_eq(body.collision_layer, (1 << 1) | (1 << 8), "static world + wind blocker layers")
	check_eq(body.get_child_count(), 1, "one shape per face")
	var row: Array = region.objects.cliff.face_a[0]
	# the shape uses the instance's transform (the headless renderer keeps no instance data)
	var xf := (body.get_child(0) as CollisionShape3D).transform
	check_near(xf.basis.z.angle_to(_expected_normal(row)), 0.0, 1e-4, "face normal = slope normal")
	var centre := xf.origin + xf.basis.y * 3.0 - xf.basis.z * RockKit.FACE_LIFT_M
	check(
		centre.distance_to(_world.map_to_world(Vector3(row[1], row[2], row[3]))) < 1e-3,
		"centre on the point"
	)


func test_cliff_transform_math() -> void:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), "load"):
		return
	# facing map east (yaw 90), leaning 60 degrees
	var xf := Region.cliff_transform(_world, [0, 100.0, 10.0, 100.0, 90, 60])
	check(
		xf.basis.z.is_equal_approx(Vector3(sin(deg_to_rad(60.0)), 0.5, 0.0)),
		"normal %s" % xf.basis.z
	)
	check(xf.basis.y.is_equal_approx(Vector3(-0.5, sin(deg_to_rad(60.0)), 0.0)), "up the slope")
	check(is_equal_approx(xf.basis.determinant(), 1.0), "a rotation")


func test_active_world_cliff_counts_match_the_file() -> void:
	if ContentDB.root == ContentDB.SAMPLE_ROOT:
		return
	# the region with the most cliff rows (the boundary scarp)
	if not check(_world.load_dir(WorldData.default_dir()), "load"):
		return
	var best := Vector2i(-1, -1)
	var most := 0
	var index: Dictionary = JSON.parse_string(_world.read_text("regions/index.json"))
	for name: String in index.files:
		var doc: Dictionary = JSON.parse_string(_world.read_indexed("regions", name))
		var n := 0
		for rows: Array in (doc.objects.get("cliff", {}) as Dictionary).values():
			n += rows.size()
		if n > most:
			most = n
			best = Vector2i(int(name.split("_")[0]), int(name.split("_")[1].trim_suffix(".json")))
	var region := _active_region(WorldData.default_dir(), best)
	if region == null:
		return
	var drawn := 0
	for d in region.cliff_draws():
		drawn += d.multimesh.instance_count
	check_eq(drawn, most, "every cliff row drawn in %s" % best)
	check_eq(region.get_node("Cliffs").get_child_count(), most, "and collides")


func test_a_changed_region_file_loads_empty_with_an_error() -> void:
	var dir := "user://region_test_copy"
	DirAccess.make_dir_recursive_absolute(dir + "/regions")
	var src := ContentDB.SAMPLE_ROOT + "/world"
	for f: String in [
		"meta.json", "height.bin", "biome.bin", "regions/index.json", "regions/0_0.json"
	]:
		DirAccess.copy_absolute(src + "/" + f, dir + "/" + f)
	var f := FileAccess.open(dir + "/regions/0_0.json", FileAccess.READ_WRITE)
	f.seek(3)
	f.store_8(0x20)
	f.close()
	var region := _active_region(dir, Vector2i(0, 0))
	if region != null:
		check(region.objects.is_empty(), "no objects from a changed file")
	for p: String in [
		"meta.json", "height.bin", "biome.bin", "regions/index.json", "regions/0_0.json"
	]:
		DirAccess.remove_absolute(dir + "/" + p)
	DirAccess.remove_absolute(dir + "/regions")
	DirAccess.remove_absolute(dir)


func _expected_normal(row: Array) -> Vector3:
	var yaw := deg_to_rad(float(row[4]))
	var s := deg_to_rad(float(row[5]))
	return Vector3(sin(yaw) * sin(s), cos(s), -cos(yaw) * sin(s))
