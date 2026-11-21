extends TestCase
## Terrain node: setup from the world files, re-selection thresholds, the
## widened culling volume, and the node inside the running game.

var _world: WorldData
var _terrain: Terrain
var _cam: Camera3D


func before_each() -> void:
	_world = WorldData.new()
	_terrain = Terrain.new()
	_cam = Camera3D.new()
	tree.root.add_child(_terrain)
	tree.root.add_child(_cam)


func after_each() -> void:
	_cam.free()
	_terrain.free()
	_world.free()


func _setup(dir: String) -> bool:
	if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
		return false
	return check(_terrain.setup(_world), "setup %s: %s" % [dir, ", ".join(_terrain.errors)])


func test_setup_on_both_worlds() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _setup(dir):
			continue
		check(_terrain.is_ready(), "draw node added")
		var mat := _terrain.get_child(0) as MultiMeshInstance3D
		var tex: Texture2D = (mat.material_override as ShaderMaterial).get_shader_parameter(
			"height_tex"
		)
		check_eq(tex.get_width(), _world.samples - 1, "height texture drops the last column")
		var y := _world.height_at(0.0, 0.0) + 2.0
		_cam.look_at_from_position(Vector3(0.0, y, 0.0), Vector3(10.0, y - 1.0, 0.0))
		check(_terrain.update_for(_cam), "first update selects")
		check(_terrain.instances > 0, "%s: patches selected" % dir)
		check_eq(mat.multimesh.visible_instance_count, _terrain.instances)


func test_reselects_only_past_the_thresholds() -> void:
	if not _setup(WorldData.default_dir()):
		return
	var y := _world.height_at(0.0, 0.0) + 2.0
	var at := Vector3(0.0, y, 0.0)
	_cam.look_at_from_position(at, at + Vector3(1.0, 0.0, 0.0))
	_terrain.update_for(_cam)
	_cam.global_position = at + Vector3(3.9, 0.0, 0.0)
	check(not _terrain.update_for(_cam), "3.9 m is below the move threshold")
	_cam.rotate_y(deg_to_rad(4.5))
	check(not _terrain.update_for(_cam), "4.5 degrees is below the turn threshold")
	_cam.global_position = at + Vector3(4.1, 0.0, 0.0)
	check(_terrain.update_for(_cam), "4.1 m from the last selection")
	_cam.rotate_y(deg_to_rad(5.5))
	check(_terrain.update_for(_cam), "5.5 degrees from the last selection")
	check_eq(_terrain.selections, 3)


func test_culling_volume_holds_what_the_camera_sees_after_small_moves() -> void:
	# Points inside the frustum of a camera moved < 4 m and turned < 5 degrees
	# must be inside the planes of the original selection.
	_cam.fov = 75.0
	_cam.far = 3000.0
	_cam.look_at_from_position(Vector3(10.0, 50.0, -20.0), Vector3(400.0, 0.0, 300.0))
	var planes := Terrain.culling_planes(_cam)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var outside := 0
	for i in 200:
		var moved := Transform3D(_cam.global_transform)
		moved = moved.rotated_local(Vector3.UP, deg_to_rad(rng.randf_range(-4.9, 4.9)))
		moved.origin += Vector3(rng.randf(), rng.randf(), rng.randf()).normalized() * 3.9
		# a point inside the moved camera's own frustum (vertical fov kept)
		var size := _cam.get_viewport().get_visible_rect().size
		var ty := tan(deg_to_rad(_cam.fov) * 0.5)
		var tx := ty * size.x / size.y
		var z := rng.randf_range(_cam.near, _cam.far)
		var local := Vector3(rng.randf_range(-tx, tx), rng.randf_range(-ty, ty), -1.0) * z
		var p := moved * local
		for pl in planes:
			if pl.distance_to(p) > 0.0:
				outside += 1
				break
	check_eq(outside, 0, "points seen after a small move lie outside the culling volume")


func test_the_game_sets_up_its_terrain() -> void:
	check_eq(await App.start_game("slot_1", true), OK)
	await tree.process_frame
	var game := Game.current
	if not check(game != null, "game scene running"):
		return
	check(game.terrain.is_ready(), "terrain draw node in the game")
