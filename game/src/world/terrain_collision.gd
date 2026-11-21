class_name TerrainCollision
extends Node3D
## Terrain collision near the players (05 §6): for each tracked body a pool
## of WINDOW x WINDOW static heightmap chunks (CHUNK_M metres, one sample per
## world sample, scaled to the sample spacing) centred on the body's chunk.
## When the body leaves the middle chunk only the newly covered chunks are
## refilled. Guarded bodies more than GUARD_M below the terrain are lifted
## back to the surface (fall-through guard).

const CHUNK_M := 64.0
const WINDOW := 5
const GUARD_M := 1.0
## Physics layer 1: terrain.
const LAYER := 1

## Chunks filled so far (for tests and the perf overlay).
var fills := 0

var _world: WorldData
var _samples_per_chunk := 0
var _chunks := 0
var _window := 0
## tracked body -> {"centre": Vector2i, "bodies": {Vector2i chunk: StaticBody3D}}
var _pools := {}
var _guarded: Array[Node3D] = []


func setup(world: WorldData) -> void:
	for body: Node3D in _pools.keys():
		untrack(body)
	_world = world
	_samples_per_chunk = int(round(CHUNK_M / world.sample_m)) + 1
	_chunks = int(round(world.size_m / CHUNK_M))
	_window = mini(WINDOW, _chunks)


## Keeps collision around `body` until untrack().
func track(body: Node3D) -> void:
	if _world == null or _pools.has(body):
		return
	_pools[body] = {"centre": Vector2i(-1, -1), "bodies": {}}
	_update(body)


func untrack(body: Node3D) -> void:
	if not _pools.has(body):
		return
	for b: StaticBody3D in _pools[body].bodies.values():
		b.queue_free()
	_pools.erase(body)


## Lifts `body` back onto the terrain whenever it falls GUARD_M below it.
func guard(body: Node3D) -> void:
	if not _guarded.has(body):
		_guarded.append(body)


func unguard(body: Node3D) -> void:
	_guarded.erase(body)


## Chunks currently held for `body` (map chunk indices).
func chunks_of(body: Node3D) -> Array:
	return _pools[body].bodies.keys() if _pools.has(body) else []


func _physics_process(_delta: float) -> void:
	if _world == null:
		return
	for body: Node3D in _pools.keys():
		if not is_instance_valid(body):
			_pools.erase(body)
			continue
		_update(body)
	for body: Node3D in _guarded.duplicate():
		if not is_instance_valid(body):
			_guarded.erase(body)
			continue
		lift_if_below(body)


## The fall-through guard for one body. Returns true when it lifted it.
func lift_if_below(body: Node3D) -> bool:
	var p := body.global_position
	var ground := _world.height_at(p.x, p.z)
	if p.y >= ground - GUARD_M:
		return false
	body.global_position = Vector3(p.x, ground, p.z)
	if body is RigidBody3D:
		var rb := body as RigidBody3D
		rb.linear_velocity.y = maxf(rb.linear_velocity.y, 0.0)
	elif body is CharacterBody3D:
		var cb := body as CharacterBody3D
		cb.velocity.y = maxf(cb.velocity.y, 0.0)
	return true


## Map chunk of an engine position, clamped so the window stays on the map.
func centre_chunk(pos: Vector3) -> Vector2i:
	var m := _world.world_to_map(pos)
	var lo := _window / 2
	var hi := _chunks - 1 - (_window - 1 - lo)
	return Vector2i(clampi(floori(m.x / CHUNK_M), lo, hi), clampi(floori(m.z / CHUNK_M), lo, hi))


func _update(body: Node3D) -> void:
	var pool: Dictionary = _pools[body]
	var centre := centre_chunk(body.global_position)
	if centre == pool.centre:
		return
	pool.centre = centre
	var want := {}
	var lo := _window / 2
	for dz in _window:
		for dx in _window:
			want[centre + Vector2i(dx - lo, dz - lo)] = true
	var held: Dictionary = pool.bodies
	var free: Array[StaticBody3D] = []
	for chunk: Vector2i in held.keys():
		if not want.has(chunk):
			free.append(held[chunk])
			held.erase(chunk)
	for chunk: Vector2i in want:
		if held.has(chunk):
			continue
		var b: StaticBody3D = free.pop_back() if not free.is_empty() else _new_body()
		_fill(b, chunk)
		held[chunk] = b
	for b in free:
		b.queue_free()


func _new_body() -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = 1 << (LAYER - 1)
	b.collision_mask = 0
	var shape := HeightMapShape3D.new()
	shape.map_width = _samples_per_chunk
	shape.map_depth = _samples_per_chunk
	var col := CollisionShape3D.new()
	col.shape = shape
	b.add_child(col)
	b.scale = Vector3(_world.sample_m, 1.0, _world.sample_m)
	add_child(b)
	return b


## Fills `b` with the samples of map chunk `chunk` (its far edge included)
## and centres it on the chunk.
func _fill(b: StaticBody3D, chunk: Vector2i) -> void:
	var n := _samples_per_chunk
	var i0 := chunk.x * (n - 1)
	var j0 := chunk.y * (n - 1)
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = _world.sample(i0 + i, j0 + j)
	var shape := (b.get_child(0) as CollisionShape3D).shape as HeightMapShape3D
	shape.map_data = data
	var centre := Vector3((chunk.x + 0.5) * CHUNK_M, 0.0, (chunk.y + 0.5) * CHUNK_M)
	b.global_position = _world.map_to_world(centre)
	fills += 1
