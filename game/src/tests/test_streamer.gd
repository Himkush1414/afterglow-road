extends TestCase
## Streamer: load within 384 m of a region's box, unload beyond 448 m,
## load steps within the frame budget, and deltas kept across unloads.

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


func _load(dir: String) -> bool:
	if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
		return false
	_streamer.setup(_world)
	_streamer.track(_body)
	return true


## Puts the body `d` metres west of the box of `region` (map coordinates),
## level with the box's middle.
func _west_of(region: Vector2i, d: float) -> void:
	var m := Vector3(region.x * WorldData.REGION_M - d, 0.0, (region.y + 0.5) * WorldData.REGION_M)
	_body.global_position = _world.map_to_world(m)


func test_load_and_unload_thresholds() -> void:
	if not _load(WorldData.default_dir()):
		return
	var r := Vector2i(6, 6)
	_west_of(r, 390.0)
	_streamer.update()
	check_eq(_streamer.state_of(r), Region.State.UNLOADED, "390 m: not loaded")
	_west_of(r, 380.0)
	_streamer.update()
	check(_streamer.state_of(r) != Region.State.UNLOADED, "380 m: loading or loaded")
	for i in 10:
		_streamer.update()
	_west_of(r, 440.0)
	_streamer.update()
	check_eq(_streamer.state_of(r), Region.State.ACTIVE, "440 m: still loaded (hysteresis)")
	_west_of(r, 450.0)
	_streamer.update()
	check_eq(_streamer.state_of(r), Region.State.UNLOADED, "450 m: unloaded")
	_west_of(r, 420.0)
	_streamer.update()
	check_eq(_streamer.state_of(r), Region.State.UNLOADED, "420 m from unloaded: stays unloaded")
	await tree.process_frame
	for n in _streamer.get_children():
		check(n is Region and _streamer.loaded_regions().has((n as Region).coord), "no stale nodes")


func test_inside_a_region_loads_its_neighbours_within_range() -> void:
	if not _load(WorldData.default_dir()):
		return
	_body.global_position = _world.map_to_world(Vector3(3328.0, 0.0, 3328.0))  # middle of (6, 6)
	_streamer.update()
	var loaded := _streamer.loaded_regions()
	loaded.sort()
	var want := []
	for rz in range(5, 8):
		for rx in range(5, 8):
			want.append(Vector2i(rx, rz))
	want.sort()
	check_eq(loaded, want, "the region and its 8 neighbours (256 m from the box edges)")


func test_load_steps_stay_within_the_budget() -> void:
	if not _load(WorldData.default_dir()):
		return
	_streamer.budget_ms = 0.0
	_body.global_position = _world.map_to_world(Vector3(3328.0, 0.0, 3328.0))
	var ticks := 0
	while ticks < 50:
		_streamer.update()
		ticks += 1
		var all_active := true
		for r: Vector2i in _streamer.loaded_regions():
			all_active = all_active and _streamer.state_of(r) == Region.State.ACTIVE
		if all_active:
			break
	# a zero budget runs one load step per tick: 9 regions x 3 steps (read, delta, cliffs)
	check_eq(ticks, 27, "one load step per tick")


func test_deltas_survive_unload_and_return_on_load() -> void:
	if not _load(WorldData.default_dir()):
		return
	var r := Vector2i(6, 6)
	_west_of(r, 100.0)
	_streamer.update()
	var region := _streamer.region_node(r)
	region.begin_load({"changed": 1})
	region.load_step()
	check_eq(_streamer.deltas().get(r), {"changed": 1}, "loaded region's delta is saved")
	_west_of(r, 500.0)
	_streamer.update()
	check_eq(_streamer.deltas().get(r), {"changed": 1}, "kept after unload")
	_west_of(r, 100.0)
	_streamer.update()
	_streamer.update()
	check_eq(_streamer.region_node(r).delta(), {"changed": 1}, "applied again on load")


func test_the_sample_world_has_one_region() -> void:
	if not _load(ContentDB.SAMPLE_ROOT + "/world"):
		return
	_body.global_position = Vector3.ZERO
	_streamer.update()
	check_eq(_streamer.loaded_regions(), [Vector2i(0, 0)])


func test_the_game_saves_streamer_deltas() -> void:
	check_eq(await App.start_game("slot_1", true), OK)
	await tree.process_frame
	var game := Game.current
	if check(game != null, "game running"):
		check_eq(SaveGame.region_source.call(), game.streamer.deltas(), "region source")
