extends TestCase
## TrunkColliders on the sample world: capsules for the nearest trees,
## selection following a body, and a body that cannot walk through a trunk.

const TIERS := [40.0, 120.0, 450.0, 2400.0]
## Map position of the first sample tree.
const TREE := Vector2(20.0, 30.0)
const BODY_R := 0.3

var _world: WorldData
var _field: TreeField


func before_each() -> void:
	_world = WorldData.new()
	_field = TreeField.new()
	tree.root.add_child(_field)


func after_each() -> void:
	_field.free()
	_world.free()


func _setup() -> bool:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(_world.errors)):
		return false
	var defs: Array = (
		JSON
		. parse_string(FileAccess.get_file_as_string(ContentDB.SAMPLE_ROOT + "/data/trees.json"))
		. trees
	)
	return check(
		_field.setup(_world, defs, {}, TIERS, ContentDB.SAMPLE_ROOT), ", ".join(_field.errors)
	)


func _marker(map: Vector2) -> Node3D:
	var n := Node3D.new()
	_field.add_child(n)
	n.global_position = _world.map_to_world(Vector3(map.x, 0.0, map.y))
	return n


## Sample trees within RADIUS_M of a map position, read from the records.
func _trees_within(at: Vector2) -> int:
	var n := 0
	for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 1)]:
		var raw := _field.chunk_records(c)
		for i in raw.size() / TreeField.RECORD_BYTES:
			var r := TreeField.decode(raw, c, i)
			n += int((r.map as Vector2).distance_to(at) <= TrunkColliders.RADIUS_M)
	return n


func test_the_nearest_trees_get_capsules() -> void:
	if not _setup():
		return
	var body := _marker(TREE + Vector2(2.0, 0.0))
	_field.trunks.track(body)
	var cols := _field.trunks.colliders_of(body)
	check(_trees_within(TREE + Vector2(2.0, 0.0)) > 0, "the sample has a tree in range")
	check_eq(cols.size(), _trees_within(TREE + Vector2(2.0, 0.0)), "one capsule per tree")
	var r := TreeField.decode(_field.chunk_records(Vector2i(0, 0)), Vector2i(0, 0), 0)
	var id := WorldData.tree_chunk_index(Vector2i(0, 0)) << TreeField.RECORD_BITS
	var first: StaticBody3D = null
	for b in cols:
		if b.get_meta(&"tree_id") == id:
			first = b
	if not check(first != null, "the first tree has a capsule"):
		return
	check_eq(first.collision_layer, 1 << 4, "physics layer 5")
	var shape := (first.get_child(0) as CollisionShape3D).shape as CapsuleShape3D
	check_near(shape.radius, 0.15 * r.scale, 1e-4, "trunk radius x scale")
	check_near(shape.height, 8.0 * r.scale, 1e-4, "height x scale")
	var at := _world.map_to_world(Vector3(TREE.x, 0.0, TREE.y))
	check_near(first.global_position.x, at.x, 1e-3, "x")
	check_near(first.global_position.z, at.z, 1e-3, "z")
	var bottom := first.global_position.y - shape.height * 0.5
	check_near(bottom, _world.height_at(at.x, at.z), 1e-3, "stands on the ground")


func test_the_selection_follows_the_body() -> void:
	if not _setup():
		return
	var body := _marker(Vector2(400.0, 400.0))
	_field.trunks.track(body)
	check_eq(_field.trunks.colliders_of(body).size(), 0, "no tree within 14 m")
	body.global_position = _world.map_to_world(Vector3(TREE.x + 2.0, 0.0, TREE.y))
	_field.trunks.update(body)
	check(_field.trunks.colliders_of(body).size() > 0, "capsules after moving to the trees")
	var far := TrunkColliders.RADIUS_M + 0.5
	body.global_position = _world.map_to_world(Vector3(TREE.x + far, 0.0, TREE.y))
	_field.trunks.update(body)
	var still := _field.trunks.colliders_of(body).size()
	body.global_position += Vector3(0.4, 0.0, 0.0)
	_field.trunks.update(body)
	check_eq(_field.trunks.colliders_of(body).size(), still, "no new selection within 1 m")
	_field.trunks.untrack(body)
	check_eq(_field.trunks.colliders_of(body).size(), 0, "untracked")


## Walks a capsule body 6 m toward the first tree from 3 m away; returns its
## final horizontal distance to the trunk centre.
func _walk_into_trunk(body: CharacterBody3D) -> float:
	var at := _world.map_to_world(Vector3(TREE.x, 0.0, TREE.y))
	var start := _world.map_to_world(Vector3(TREE.x - 3.0, 0.0, TREE.y))
	start.y = _world.height_at(at.x, at.z) + 1.5
	body.global_position = start
	await tree.physics_frame
	var dir := Vector3(at.x - start.x, 0.0, at.z - start.z).normalized()
	for i in 90:
		body.velocity = dir * 4.0
		body.move_and_slide()
		await tree.physics_frame
	var p := body.global_position
	return Vector2(p.x - at.x, p.z - at.z).length()


func test_a_body_cannot_walk_through_a_trunk() -> void:
	if not _setup():
		return
	var body := CharacterBody3D.new()
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	body.collision_layer = 1 << 5
	body.collision_mask = 1 << 4
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_R
	capsule.height = 1.8
	col.shape = capsule
	body.add_child(col)
	_field.add_child(body)
	_field.trunks.track(body)
	var r := TreeField.decode(_field.chunk_records(Vector2i(0, 0)), Vector2i(0, 0), 0)
	var contact := 0.15 * float(r.scale) + BODY_R
	var d: float = await _walk_into_trunk(body)
	check(d >= contact - 0.02, "stopped at the trunk (%.3f m, contact %.3f m)" % [d, contact])
	check(d <= contact + 0.1, "reached the trunk (%.3f m)" % d)
	# Control: without the pool the same walk passes the trunk.
	_field.trunks.untrack(body)
	await tree.process_frame  # the freed capsules leave the space
	d = await _walk_into_trunk(body)
	check(d > 2.0, "walks on without colliders (%.3f m)" % d)


func test_the_main_axis_of_a_lying_trunk() -> void:
	# Rings of a 4 m trunk (radius 0.2 m) lying at 30 degrees around (1, -0.5).
	var axis := Vector3(cos(PI / 6.0), 0.0, sin(PI / 6.0))
	var side := axis.cross(Vector3.UP)
	var verts := PackedVector3Array()
	for k in 9:
		for j in 8:
			var a := TAU * j / 8.0
			var ring := side * cos(a) * 0.2 + Vector3.UP * (0.2 + sin(a) * 0.2)
			verts.append(Vector3(1.0, 0.0, -0.5) + axis * (k / 8.0 * 4.0 - 2.0) + ring)
	var got := TrunkColliders.lying_axis(verts)
	var dir: Vector2 = got[0]
	check_near(absf(dir.dot(Vector2(axis.x, axis.z))), 1.0, 1e-4, "along the trunk")
	check_near(got[1], 4.0, 1e-3, "length")
	check((got[2] as Vector2).is_equal_approx(Vector2(1.0, -0.5)), "centre %s" % str(got[2]))
	check_eq(TrunkColliders.lying_axis(PackedVector3Array()), [], "no vertices")


func test_a_lying_trunk_without_a_model_gets_no_capsule() -> void:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(_world.errors)):
		return
	var d: Dictionary = (
		JSON
		. parse_string(FileAccess.get_file_as_string(ContentDB.SAMPLE_ROOT + "/data/trees.json"))
		. trees
	)[0]
	d.height_m = 0.5
	d.canopy_r_m = 0.0
	if not check(_field.setup(_world, [d], {}, TIERS, ContentDB.SAMPLE_ROOT)):
		return
	var body := _marker(TREE + Vector2(2.0, 0.0))
	_field.trunks.track(body)
	check_eq(_field.trunks.colliders_of(body).size(), 0, "sample has no models")
