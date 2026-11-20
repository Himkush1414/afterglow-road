extends TestCase
## T-05-11: map/engine conversion, index helpers from both coordinate kinds,
## the running game's coordinate bound, and the D-20 lint (the origin offset constant
## appears nowhere in src/ outside WorldData; spike code is exempt).

const DIR := "user://tests/world_coords_saves"
const BOUND := 4200.0
## Vector3 is float32 here: adding and removing the offset rounds near 8,192.
const ROUND_TRIP_M := 0.001

var _world: WorldData
var _counter := 0


func before_each() -> void:
	_world = WorldData.new()
	_wipe(DIR)
	SaveGame.saves_dir = DIR
	_counter = Ids.counter()


func after_each() -> void:
	_world.free()
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	Ids.set_counter(_counter)
	_wipe(DIR)


# gdlint:ignore = function-name
func test_T_05_11() -> void:
	# the active world, and the public sample world (what CI has)
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if check(_world.load_dir(dir), "%s: %s" % [dir, ", ".join(_world.errors)]):
			_check_conversions(dir)


func _check_conversions(dir: String) -> void:
	var size := _world.size_m
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var points: Array[Vector3] = [
		Vector3(0, 0, 0), Vector3(size, 0, 0), Vector3(0, 0, size), Vector3(size, 0, size)
	]
	for i in 1000:
		points.append(Vector3(rng.randf() * size, rng.randf() * 300.0, rng.randf() * size))
	var worst := 0.0
	for m: Vector3 in points:
		var e := _world.map_to_world(m)
		worst = maxf(worst, (_world.map_to_world(_world.world_to_map(e)) - e).length())
		check_eq(_world.region_of(e), WorldData.region_of_map(m), "%s region at %s" % [dir, m])
		check_eq(
			_world.tree_chunk_of(e), WorldData.tree_chunk_of_map(m), "%s chunk at %s" % [dir, m]
		)
		check(absf(e.x) <= BOUND and absf(e.z) <= BOUND, "%s: %s within the bound" % [dir, e])
	check(worst <= ROUND_TRIP_M, "%s: round trip off by %.6f m" % [dir, worst])


func test_the_running_game_stays_within_the_bound() -> void:
	check_eq(await App.start_game("slot_1", true), OK)
	await tree.process_frame
	var game := Game.current
	if not check(game != null and Game.world_of().is_loaded(), "game with a loaded world"):
		return
	var far: Array[String] = []
	var stack: Array[Node] = [game]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is Node3D:
			var p := (node as Node3D).global_position
			if absf(p.x) > BOUND or absf(p.y) > BOUND or absf(p.z) > BOUND:
				far.append("%s %s" % [node.get_path(), p])
	check(far.is_empty(), "nodes beyond ±%d: %s" % [int(BOUND), ", ".join(far)])


func test_no_origin_constant_outside_world_data() -> void:
	var hits: PackedStringArray = []
	var dirs: Array[String] = ["res://src"]
	while not dirs.is_empty():
		var dir: String = dirs.pop_back()
		if dir == "res://src/spikes":
			continue
		for sub in DirAccess.get_directories_at(dir):
			dirs.append(dir + "/" + sub)
		for f in DirAccess.get_files_at(dir):
			var path := dir + "/" + f
			if not f.ends_with(".gd") or path == "res://src/world/world_data.gd":
				continue
			var lines := FileAccess.get_file_as_string(path).split("\n")
			for i in lines.size():
				if lines[i].contains(str(8192 / 2)):
					hits.append("%s:%d" % [path, i + 1])
	check(hits.is_empty(), "the origin offset appears outside WorldData: %s" % ", ".join(hits))


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir + "/" + sub)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)
