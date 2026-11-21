class_name Streamer
extends Node3D
## Region lifecycle (03 §10, 05 §8): a region is loaded while a tracked body
## is within LOAD_M of its box and unloaded once every tracked body is beyond
## UNLOAD_M; states UNLOADED -> LOADING -> ACTIVE -> UNLOADING -> UNLOADED.
## Load steps are spread over frames within the preset's time budget. Saved
## deltas come from the active save slot; deltas of unloaded regions are kept
## until the next save.

const LOAD_M := 384.0
const UNLOAD_M := 448.0
## Budget per frame when no quality preset is applied, milliseconds.
const DEFAULT_BUDGET_MS := 2.0

var budget_ms := DEFAULT_BUDGET_MS

var _world: WorldData
var _per_side := 0
var _bodies: Array[Node3D] = []
## Vector2i -> Region (loading or active)
var _regions := {}
## Vector2i regions waiting to load, in request order.
var _queue: Array[Vector2i] = []
## Vector2i -> delta of regions unloaded since the last save
var _kept := {}


func setup(world: WorldData) -> void:
	for r: Vector2i in _regions.keys():
		_unload(r)
	_world = world
	_per_side = ceili(world.size_m / WorldData.REGION_M)
	var budget: Variant = Quality.value("region_budget_ms")
	budget_ms = float(budget) if budget != null else DEFAULT_BUDGET_MS


func track(body: Node3D) -> void:
	if not _bodies.has(body):
		_bodies.append(body)


func untrack(body: Node3D) -> void:
	_bodies.erase(body)


func state_of(region: Vector2i) -> Region.State:
	return (_regions[region] as Region).state if _regions.has(region) else Region.State.UNLOADED


func region_node(region: Vector2i) -> Region:
	return _regions.get(region)


func loaded_regions() -> Array:
	return _regions.keys()


## Deltas to save: every loaded region's plus those kept from unloaded ones,
## leaving out empty ones (SaveGame.region_source).
func deltas() -> Dictionary:
	var out := _kept.duplicate(true)
	for r: Vector2i in _regions:
		var d := (_regions[r] as Region).delta()
		if not d.is_empty():
			out[r] = d
	return out


## Distance in the map plane from map point `m` to the box of `region`.
func distance_to_region(m: Vector2, region: Vector2i) -> float:
	var lo := Vector2(region) * WorldData.REGION_M
	var hi := lo + Vector2(WorldData.REGION_M, WorldData.REGION_M)
	return m.distance_to(m.clamp(lo, hi))


func _process(_delta: float) -> void:
	if _world != null:
		update()


## One streaming tick: decide loads and unloads, then run load steps until
## the budget is used (at least one step).
func update() -> void:
	var points: Array[Vector2] = []
	for b in _bodies:
		if is_instance_valid(b):
			var m := _world.world_to_map(b.global_position)
			points.append(Vector2(m.x, m.z))
	for rz in _per_side:
		for rx in _per_side:
			var r := Vector2i(rx, rz)
			var near := INF
			for p in points:
				near = minf(near, distance_to_region(p, r))
			if near <= LOAD_M and not _regions.has(r):
				_request(r)
			elif near > UNLOAD_M and _regions.has(r):
				_unload(r)
	var start := Time.get_ticks_usec()
	while not _queue.is_empty():
		var region: Region = _regions[_queue[0]]
		if region.load_step():
			_queue.pop_front()
		if (Time.get_ticks_usec() - start) / 1000.0 >= budget_ms:
			break


func _request(r: Vector2i) -> void:
	var region := Region.new(r)
	add_child(region)
	var delta: Dictionary = _kept.get(r, {})
	_kept.erase(r)
	if delta.is_empty() and SaveGame.active_slot != "":
		delta = SaveGame.load_region(SaveGame.active_slot, r)
	region.begin_load(delta)
	_regions[r] = region
	_queue.append(r)


func _unload(r: Vector2i) -> void:
	var region: Region = _regions[r]
	region.state = Region.State.UNLOADING
	var d := region.delta()
	if not d.is_empty():
		_kept[r] = d
	_queue.erase(r)
	_regions.erase(r)
	region.state = Region.State.UNLOADED
	region.queue_free()
