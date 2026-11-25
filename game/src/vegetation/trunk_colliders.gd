class_name TrunkColliders
extends Node3D
## Trunk collision near the players (06 §A5.1): for each tracked body the
## POOL nearest standing trees within RADIUS_M get a capsule on physics
## layer 5 (radius trunk_r_m x scale, height height_m x scale, standing on
## the ground; metadata "tree_id"). The selection runs again once the body
## has moved RESELECT_M. Lying trunks (no crown, lower than LYING_BELOW_M)
## get none yet. Tree chunks within RADIUS_M + PREFETCH_M are read on worker
## threads ahead of the body, so a selection reads no file unless the body
## jumped (spawn, teleport).

const POOL := 48
const RADIUS_M := 14.0
const RESELECT_M := 1.0
const LYING_BELOW_M := 1.0
## Physics layer 5: trees (trunks).
const LAYER := 5
## Extra reach of the chunk read-ahead around each body.
const PREFETCH_M := 32.0
## Floats per standing tree in a decoded chunk: map x, map z, radius, height, id.
const STRIDE := 5

var _field: TreeField
var _world: WorldData
## Per tree type (record model index): [trunk radius m, height m], or [] for
## a lying trunk.
var _sizes: Array = []
## tracked body -> {"at": Vector2 map position of the last selection or NAN,
## "bodies": Array[StaticBody3D]}
var _pools := {}
## Vector2i chunk -> PackedFloat64Array (STRIDE floats per standing tree)
var _cache := {}
## Vector2i chunk -> WorkerThreadPool task id of a read in flight
var _tasks := {}
## Results of finished reads, filled by the workers.
var _done := {}
var _mutex := Mutex.new()


func setup(field: TreeField, world: WorldData, defs: Array) -> void:
	for body: Node3D in _pools.keys():
		untrack(body)
	_field = field
	_world = world
	_sizes.clear()
	for d: Dictionary in defs:
		var height := float(d.height_m)
		var lying := float(d.get("canopy_r_m", 0.0)) <= 0.0 and height < LYING_BELOW_M
		_sizes.append([] if lying else [float(d.trunk_r_m), height])
	_wait_for_reads()
	_cache.clear()


## Keeps trunk colliders around `body` until untrack().
func track(body: Node3D) -> void:
	if _world == null or _pools.has(body):
		return
	var bodies: Array[StaticBody3D] = []
	for i in POOL:
		bodies.append(_new_body())
	_pools[body] = {"at": Vector2(NAN, NAN), "bodies": bodies}
	update(body)


func untrack(body: Node3D) -> void:
	if not _pools.has(body):
		return
	for b: StaticBody3D in _pools[body].bodies:
		b.queue_free()
	_pools.erase(body)


## Enabled colliders of `body` (for tests and the perf overlay).
func colliders_of(body: Node3D) -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	if _pools.has(body):
		for b: StaticBody3D in _pools[body].bodies:
			if not (b.get_child(0) as CollisionShape3D).disabled:
				out.append(b)
	return out


func _physics_process(_delta: float) -> void:
	if _world == null:
		return
	for body: Node3D in _pools.keys():
		if not is_instance_valid(body):
			for b: StaticBody3D in _pools[body].bodies:
				b.queue_free()
			_pools.erase(body)
			continue
		update(body)
	_prefetch()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_wait_for_reads()


## Selects again when `body` moved RESELECT_M since the last selection.
func update(body: Node3D) -> void:
	var pool: Dictionary = _pools[body]
	var m := _world.world_to_map(body.global_position)
	var at := Vector2(m.x, m.z)
	var last: Vector2 = pool.at
	if not is_nan(last.x) and at.distance_to(last) < RESELECT_M:
		return
	pool.at = at
	_assign(pool.bodies, trees_near(at))


## The standing trees within RADIUS_M of a map position, nearest first, at
## most POOL: each [map x, map z, radius, height, id].
func trees_near(at: Vector2) -> Array:
	var found := []
	var lo := WorldData.tree_chunk_of_map(Vector3(at.x - RADIUS_M, 0.0, at.y - RADIUS_M))
	var hi := WorldData.tree_chunk_of_map(Vector3(at.x + RADIUS_M, 0.0, at.y + RADIUS_M))
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var data := _chunk(Vector2i(cx, cz))
			for o in range(0, data.size(), STRIDE):
				var d2 := Vector2(data[o], data[o + 1]).distance_squared_to(at)
				if d2 <= RADIUS_M * RADIUS_M:
					found.append([d2, o, data])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out := []
	for f: Array in found.slice(0, POOL):
		var data: PackedFloat64Array = f[2]
		var o: int = f[1]
		out.append([data[o], data[o + 1], data[o + 2], data[o + 3], int(data[o + 4])])
	return out


## Standing trees of a chunk: from the cache, from a finished or running
## read (waited for), or read here when nothing asked for it yet.
func _chunk(c: Vector2i) -> PackedFloat64Array:
	_collect_reads()
	if not _cache.has(c) and _tasks.has(c):
		WorkerThreadPool.wait_for_task_completion(_tasks[c])
		_collect_reads()
	if not _cache.has(c):
		_cache[c] = _read(c)
	return _cache[c]


## Starts reads of the chunks around every body and drops chunks no body
## is near any more.
func _prefetch() -> void:
	_collect_reads()
	var want := {}
	var reach := RADIUS_M + PREFETCH_M
	for body: Node3D in _pools.keys():
		var m := _world.world_to_map(body.global_position)
		var lo := WorldData.tree_chunk_of_map(m - Vector3(reach, 0.0, reach))
		var hi := WorldData.tree_chunk_of_map(m + Vector3(reach, 0.0, reach))
		for cz in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				want[Vector2i(cx, cz)] = true
	for c: Vector2i in _cache.keys():
		if not want.has(c):
			_cache.erase(c)
	for c: Vector2i in want:
		if not _cache.has(c) and not _tasks.has(c):
			_tasks[c] = WorkerThreadPool.add_task(_read_task.bind(c), false, "trunk chunk")


func _read_task(c: Vector2i) -> void:
	var data := _read(c)
	_mutex.lock()
	_done[c] = data
	_mutex.unlock()


func _collect_reads() -> void:
	for c: Vector2i in _tasks.keys():
		if WorkerThreadPool.is_task_completed(_tasks[c]):
			WorkerThreadPool.wait_for_task_completion(_tasks[c])
			_tasks.erase(c)
	_mutex.lock()
	for c: Vector2i in _done:
		_cache[c] = _done[c]
	_done.clear()
	_mutex.unlock()


func _wait_for_reads() -> void:
	for c: Vector2i in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(_tasks[c])
	_tasks.clear()
	_mutex.lock()
	_done.clear()
	_mutex.unlock()


## Decodes the standing trees of a chunk (any thread: reads only).
func _read(c: Vector2i) -> PackedFloat64Array:
	var data := PackedFloat64Array()
	if c.x < 0 or c.y < 0:
		return data
	var raw := _field.chunk_records(c)
	var base := WorldData.tree_chunk_index(c) << TreeField.RECORD_BITS
	for i in raw.size() / TreeField.RECORD_BYTES:
		var r := TreeField.decode(raw, c, i)
		var size: Array = _sizes[r.model] if r.model < _sizes.size() else []
		if size.is_empty():
			continue
		data.append_array(
			[r.map.x, r.map.y, float(size[0]) * r.scale, float(size[1]) * r.scale, float(base | i)]
		)
	return data


## Gives the selected trees a collider each; bodies already on a selected
## tree stay where they are, the rest are moved or switched off.
func _assign(bodies: Array[StaticBody3D], trees: Array) -> void:
	var want := {}
	for t: Array in trees:
		want[t[4]] = t
	var free: Array[StaticBody3D] = []
	for b in bodies:
		var id: int = b.get_meta(&"tree_id", -1)
		if want.has(id):
			want.erase(id)
		else:
			free.append(b)
	for id: int in want:
		var t: Array = want[id]
		var b: StaticBody3D = free.pop_back()
		var col := b.get_child(0) as CollisionShape3D
		var shape := col.shape as CapsuleShape3D
		var radius: float = t[2]
		var height := maxf(float(t[3]), radius * 2.0)
		shape.radius = radius
		shape.height = height
		var pos := _world.map_to_world(Vector3(t[0], 0.0, t[1]))
		pos.y = _world.height_at(pos.x, pos.z) + height * 0.5
		b.global_position = pos
		b.set_meta(&"tree_id", id)
		col.disabled = false
	for b in free:
		(b.get_child(0) as CollisionShape3D).disabled = true
		b.set_meta(&"tree_id", -1)


func _new_body() -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = 1 << (LAYER - 1)
	b.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = CapsuleShape3D.new()
	col.disabled = true
	b.add_child(col)
	b.set_meta(&"tree_id", -1)
	add_child(b)
	return b
