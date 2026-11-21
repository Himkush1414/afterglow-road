extends TestCase
## TerrainCollision: T-05-6, rays against the data, re-centring, the window
## at the map edge and the fall-through guard.

const RADIUS := 0.1
const REST_TOLERANCE_M := 0.05
const SETTLE_FRAMES := 240

var _world: WorldData
var _col: TerrainCollision
var _nodes: Array[Node] = []


func before_each() -> void:
	_world = WorldData.new()
	_col = TerrainCollision.new()
	tree.root.add_child(_col)
	_nodes.clear()


func after_each() -> void:
	for n in _nodes:
		n.free()
	_col.free()
	_world.free()


func _load(dir: String) -> bool:
	if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
		return false
	_col.setup(_world)
	return true


func _target(pos: Vector3) -> Node3D:
	var n := Node3D.new()
	tree.root.add_child(n)
	n.global_position = pos
	_nodes.append(n)
	return n


func _random_land(rng: RandomNumberGenerator) -> Vector3:
	for attempt in 1000:
		var x := rng.randf_range(0.02, 0.98) * _world.size_m - _world.origin_offset_m
		var z := rng.randf_range(0.02, 0.98) * _world.size_m - _world.origin_offset_m
		var y := _world.height_at(x, z)
		if y > 0.0:
			return Vector3(x, y, z)
	return Vector3.INF


# gdlint:ignore = function-name
func test_T_05_6() -> void:
	# 1,000 spheres on the active world (and 200 on the sample world) dropped
	# on random land points near tracked bodies come to rest on height_at.
	for case: Array in [
		[WorldData.default_dir(), 20, 50], [ContentDB.SAMPLE_ROOT + "/world", 4, 50]
	]:
		if not _load(case[0]):
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = 6
		var balls: Array[RigidBody3D] = []
		var shape := SphereShape3D.new()
		shape.radius = RADIUS
		for t in int(case[1]):
			var centre := _random_land(rng)
			_col.track(_target(centre))
			for k in int(case[2]):
				var p := Vector3.INF
				while p == Vector3.INF:
					var x := centre.x + rng.randf_range(-48.0, 48.0)
					var z := centre.z + rng.randf_range(-48.0, 48.0)
					var y := _world.height_at(x, z)
					if (
						y > 0.0
						and absf(x) < _world.size_m * 0.49
						and absf(z) < _world.size_m * 0.49
					):
						p = Vector3(x, y + rng.randf_range(1.0, 3.0), z)
				var b := RigidBody3D.new()
				var c := CollisionShape3D.new()
				c.shape = shape
				b.add_child(c)
				b.lock_rotation = true
				b.linear_damp = 3.0
				var mat := PhysicsMaterial.new()
				mat.friction = 1.0
				mat.rough = true
				b.physics_material_override = mat
				tree.root.add_child(b)
				b.global_position = p
				_nodes.append(b)
				balls.append(b)
		for f in SETTLE_FRAMES:
			await tree.physics_frame
		var worst := 0.0
		for b in balls:
			worst = maxf(worst, absf(_surface_distance(b.global_position) - RADIUS))
		print("  T-05-6 %s: %d spheres, worst %.4f m" % [case[0], balls.size(), worst])
		check(
			worst <= REST_TOLERANCE_M,
			"%s: %d spheres, worst %.4f m off the surface" % [case[0], balls.size(), worst]
		)
		for b in balls:
			_nodes.erase(b)
			b.free()


## Distance from `p` to the terrain surface along its normal (a sphere on a
## slope rests with its centre r / cos(slope) above the ground below it).
func _surface_distance(p: Vector3) -> float:
	var e := 0.01
	var hx := (_world.height_at(p.x + e, p.z) - _world.height_at(p.x - e, p.z)) / (2.0 * e)
	var hz := (_world.height_at(p.x, p.z + e) - _world.height_at(p.x, p.z - e)) / (2.0 * e)
	var n := Vector3(-hx, 1.0, -hz).normalized()
	return (p.y - _world.height_at(p.x, p.z)) * n.y


func test_rays_meet_height_at() -> void:
	if not _load(WorldData.default_dir()):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var centre := _random_land(rng)
	_col.track(_target(centre))
	await tree.physics_frame
	var space := _col.get_world_3d().direct_space_state
	var worst := 0.0
	var misses := 0
	for k in 500:
		var x := centre.x + rng.randf_range(-150.0, 150.0)
		var z := centre.z + rng.randf_range(-150.0, 150.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 2000.0, z), Vector3(x, -500.0, z))
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			misses += 1
			continue
		worst = maxf(worst, absf(float(hit.position.y) - _world.height_at(x, z)))
	check_eq(misses, 0, "rays inside the window all hit")
	check(worst <= 0.001, "ray hits differ from height_at by %.5f m" % worst)


func test_recentring_refills_only_new_chunks() -> void:
	if not _load(WorldData.default_dir()):
		return
	var at := _world.map_to_world(Vector3(10.5, 0.0, 10.5) * TerrainCollision.CHUNK_M)
	var body := _target(at)
	_col.track(body)
	check_eq(_col.fills, 25, "first window")
	check_eq(_col.get_child_count(), 25, "pool size")
	body.global_position += Vector3(TerrainCollision.CHUNK_M, 0.0, 0.0)
	await tree.physics_frame
	check_eq(_col.fills, 30, "one chunk east: 5 new")
	body.global_position += Vector3(TerrainCollision.CHUNK_M, 0.0, TerrainCollision.CHUNK_M)
	await tree.physics_frame
	check_eq(_col.fills, 39, "one chunk diagonally: 9 new")
	body.global_position += Vector3(10.0, 0.0, 10.0)
	await tree.physics_frame
	check_eq(_col.fills, 39, "inside the middle chunk: nothing")
	var want := []
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			want.append(Vector2i(12 + dx, 11 + dz))
	var have := _col.chunks_of(body)
	have.sort()
	want.sort()
	check_eq(have, want, "window around chunk (12, 11)")
	_col.untrack(body)
	await tree.process_frame
	check_eq(_col.get_child_count(), 0, "untrack frees the pool")


func test_window_stays_on_the_map() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		if not _load(dir):
			continue
		var body := _target(_world.map_to_world(Vector3(1.0, 0.0, _world.size_m - 1.0)))
		_col.track(body)
		var last := int(round(_world.size_m / TerrainCollision.CHUNK_M)) - 1
		var window := mini(TerrainCollision.WINDOW, last + 1)
		var chunks := _col.chunks_of(body)
		check_eq(chunks.size(), window * window, "%s window" % dir)
		for c: Vector2i in chunks:
			check(c.x >= 0 and c.y >= 0 and c.x <= last and c.y <= last, "%s chunk %s" % [dir, c])
		_col.untrack(body)


func test_the_guard_lifts_bodies_below_the_terrain() -> void:
	if not _load(WorldData.default_dir()):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var p := _random_land(rng)
	var deep := RigidBody3D.new()
	deep.gravity_scale = 0.0
	tree.root.add_child(deep)
	_nodes.append(deep)
	deep.global_position = p - Vector3(0.0, 2.0, 0.0)
	deep.linear_velocity = Vector3(1.0, -5.0, 0.0)
	var shallow := _target(p - Vector3(0.0, 0.5, 0.0))
	_col.guard(deep)
	_col.guard(shallow)
	await tree.physics_frame
	await tree.physics_frame
	check_near(deep.global_position.y, p.y, 0.05, "lifted onto the surface")
	check(deep.linear_velocity.y >= 0.0, "falling speed removed")
	check_near(shallow.global_position.y, p.y - 0.5, 1e-4, "0.5 m below is left alone")
