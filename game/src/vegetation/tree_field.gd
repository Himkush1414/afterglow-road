class_name TreeField
extends Node3D
## The world's trees (06 §A3): reads the tree chunk files (04 §2, 7-byte
## records) and draws
## - the far tier T3: one MultiMesh of billboards per 512 m tile for all
##   models, built on a worker thread when the tile comes within the preset's
##   T3 range and freed when it leaves it (Q-107);
## - the mid tier T2: one MultiMesh per model per 128 m chunk, built on a
##   worker thread for the chunks reaching into the T2 range (Q-108);
## - the near set T0/T1: per model one MultiMesh per tier, refilled from a
##   worker thread when the camera crosses a 16 m line (Q-108).
##
## Per record, a hash of (chunk, record index) picks the model variant from
## the type's `models`, the wind phase and the tint. Billboards use the atlas
## and the models manifest written by the asset tools; without them (sample
## content) a flat stand-in quad is drawn.

const MODEL_DIR := "assets/models/trees"
const TEXTURE_DIR := "assets/textures/trees"
const MANIFEST := "tree_models.json"
const SHADER := "res://shaders/impostor.gdshader"
const FOLIAGE := "res://shaders/foliage.gdshader"
const FOLDER := "trees"
const RECORD_BYTES := 7
## A chunk holds at most 4,095 trees (06 §A6): record indices fit 12 bits.
const RECORD_BITS := 12
const TILE_M := 512.0
const RESELECT_M := 64.0
const KEEP_EXTRA_M := 256.0
const MAX_BUILDS := 2
const T0 := 0
const T1 := 1
## Near kinds (see _near): the tier whose buffer and fade each one uses.
const NEAR_KIND_TIER := [0, 1, 1, 0, 2]
const NEAR_LINE_M := 16.0
## How far the camera can move between near-set rebuilds (a 16 m cell's diagonal).
const NEAR_SLACK_M := 22.7
const NEAR_SLICE_USEC := 700
## The near-set cut (near_cut_m) is worked out again when the eye moved this
## far; the cut is widened by the same distance.
const CUT_STEP_M := 1.0
const T2 := 2
const T3 := 3
const CHUNK_RESELECT_M := 16.0
const T2_KEEP_EXTRA_M := 64.0
## Mid-tier chunk cut (_chunk_cut_m): worked out again when the eye moved this
## far, and widened by the same distance.
const CHUNK_CUT_STEP_M := 4.0
## A kept chunk is sorted again around the eye once the eye is this far from
## the point its instances were sorted around.
const CHUNK_RESORT_M := 64.0
## A kept billboard tile is sorted again once the eye is this far from its
## sort point.
const TILE_RESORT_M := 128.0
## 16 floats per instance: a 3 x 4 transform, then custom data.
const STRIDE := 16
const CELLS := 64
const STAND_IN_COLOR := Color(0.25, 0.32, 0.2)

var errors: PackedStringArray = []
## Instances in the built tiles (for checks and the perf overlay).
var instances := 0
var tiers_m: Array = []
## Whether T2 trees cast sun shadows (quality preset), set before setup.
var t2_shadows := false
## Sun shadow distance in metres (quality preset), set before setup: T2
## shadows are cast by a near-set ring out to here (t2_ring()).
var shadow_distance_m := 0.0
## Angular sectors the near set is split into around its build point, so
## frustum and shadow-cascade culling can drop the ones out of view (quality
## preset; 1 = no split). Set before setup.
var near_sectors := 1
## Instances in the built T2 chunks.
var mid_instances := 0
## Instances in the near set, per tier [T0, T1].
var near_instances := [0, 0]
## Longest main-thread slice of the last near-set assignment (T-06-6), in
## microseconds; the assignment is spread over frames in slices of
## NEAR_SLICE_USEC.
var near_assign_usec := 0
## Map position the current near set was built around.
var near_map := Vector3(INF, INF, INF)
## Trunk colliders around the players (06 §A5.1).
var trunks: TrunkColliders

var _world: WorldData
var _defs: Array = []
var _cfg := {}
## Per tree type: [[cell, side_m, bottom_m, model index or -1] per variant].
var _variants: Array = []
## Per model (index from _variants): {"stem", "height_m", "meshes": [T0, T1, T2],
## "shadow": the T2 mesh with T1 materials, "shadow_t0": the T1 mesh with T0
## materials}.
var _models: Array = []
var _textures := {}
var _material: ShaderMaterial
var _quad := ArrayMesh.new()
var _tiles_per_side := 0
var _tiles := {}
var _pending := {}
var _done := {}
var _mutex := Mutex.new()
var _last_eye := Vector3(INF, INF, INF)
var _wanted: Array[Vector2i] = []
var _chunks := {}
var _pending_chunks := {}
var _done_chunks := {}
var _last_chunk_eye := Vector3(INF, INF, INF)
var _wanted_chunks: Array[Vector2i] = []
## Eye (map) at the last mid-tier chunk cut.
var _chunk_cut_eye := Vector3(INF, INF, INF)
## Per model: MultiMeshInstance3D or null for each (kind, sector) at
## kind * near_sectors + sector; kinds T0, T1, T1 shadow caster, T0 shadow
## caster, T2 shadow caster. Shadows are cast one mesh coarser (06 §A3,
## Q-109f): the T1 instances drawn again as shadow-only T2 meshes, the T0
## instances as shadow-only T1 meshes; T2 trees within the shadow distance
## cast as shadow-only T2 meshes (Q-109g).
var _near: Array = []
var _near_line := Vector2i(1 << 30, 1 << 30)
var _near_task := -1
var _near_result: Variant = null
## A near set being assigned: [map, buffers, next model, instance totals].
var _near_assigning: Array = []
## Per model: the map position its near buffers were built around and, per
## node of _near, the sorted distances of its instances from there.
var _near_from: Array[Vector3] = []
var _near_dists: Array = []
## Eye (map) at the last near-set cut.
var _cut_eye := Vector3(INF, INF, INF)


## False with `errors` when the tree data cannot be read. `defs`: the tree
## types in file order (the record's model index); `cfg`: the `trees` tuning
## group; `tiers`: [T0 end, T1 end, T2 end, T3 end] in metres; `root`: the
## content folder holding the models manifest and atlas.
func setup(world: WorldData, defs: Array, cfg: Dictionary, tiers: Array, root: String = "") -> bool:
	errors.clear()
	_world = world
	_defs = defs
	_cfg = cfg
	tiers_m = tiers
	_tiles_per_side = maxi(1, roundi((world.samples - 1) * world.sample_m / TILE_M))
	if tiers.size() != 4:
		errors.append("tree tiers: expected 4 ranges, got %s" % str(tiers))
	if world.index_of(FOLDER).is_empty():
		errors.append("%s/index.json: missing or changed" % FOLDER)
	TreeShading.push(cfg, tiers)
	_quad = unit_quad()
	_setup_models(root if root != "" else String(ContentDB.root))
	if trunks == null:
		trunks = TrunkColliders.new()
		add_child(trunks)
	trunks.setup(self, world, defs)
	return errors.is_empty()


func is_ready() -> bool:
	return _world != null and errors.is_empty()


## The billboard quad: x -0.5..0.5, y 0..1, facing +Z, UV v 0 at the top.
static func unit_quad() -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array(
		[Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)]
	)
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array(
		[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	)
	a[Mesh.ARRAY_NORMAL] = PackedVector3Array(
		[Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK]
	)
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return mesh


## A 32-bit hash of a record: variant, phase and tint come from its bits.
static func record_hash(chunk_index: int, i: int) -> int:
	var h := (((chunk_index << RECORD_BITS) | i) * 0x9E3779B1) & 0xFFFFFFFF
	h ^= h >> 16
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h ^= h >> 13
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h ^= h >> 16
	return h


## Record i of a chunk's decoded bytes: {model, map (x, z in map metres),
## yaw (radians), scale}.
static func decode(raw: PackedByteArray, chunk: Vector2i, i: int) -> Dictionary:
	var o := i * RECORD_BYTES
	return {
		"model": raw[o],
		"map":
		Vector2(
			chunk.x * WorldData.TREE_CHUNK_M + raw.decode_u16(o + 1) / 512.0,
			chunk.y * WorldData.TREE_CHUNK_M + raw.decode_u16(o + 3) / 512.0
		),
		"yaw": raw[o + 5] / 256.0 * TAU,
		"scale": 0.75 + raw[o + 6] / 510.0,
	}


## The T1 mesh of each variant of a tree type (null where no model loaded),
## in the order a record's hash picks them.
func variant_meshes(type: int) -> Array[Mesh]:
	var out: Array[Mesh] = []
	for v: Array in _variants[type] if type < _variants.size() else []:
		var model: int = v[3]
		out.append((_models[model].meshes as Array)[T1] if model >= 0 else null)
	return out


## Decoded records of a chunk (empty when it has no trees).
func chunk_records(chunk: Vector2i) -> PackedByteArray:
	var name := "%d_%d.bin" % [chunk.x, chunk.y]
	var entry: Dictionary = _world.index_of(FOLDER).get("files", {}).get(name, {})
	if entry.is_empty():
		return PackedByteArray()
	var size := int(entry.count) * RECORD_BYTES
	return _world.read_indexed_bytes(FOLDER, name).decompress(size, FileAccess.COMPRESSION_ZSTD)


## The MultiMesh buffer of a tile: [buffer, instance count].
## Billboard buffer of a tile: [buffer, count, keys, sign]. With a finite
## `from` (map position) the instances are ordered by key = sign x their
## distance from it: sign -1 (farthest first) when the whole tile lies
## within the far reach seen from `from`, so a prefix drops the billboards
## nearer than the T3 start; +1 otherwise, so a prefix drops those past the
## T3 end. With `from` = INF: record order, no keys, sign 0.
func tile_buffer(tile: Vector2i, from: Vector3 = Vector3.INF) -> Array:
	var buf := PackedFloat32Array()
	var keys := PackedFloat32Array()
	var count := 0
	var sorted := from.is_finite()
	var sign := 0
	if sorted:
		var lo := Vector2(tile) * TILE_M
		var dx := maxf(absf(from.x - lo.x), absf(from.x - lo.x - TILE_M))
		var dz := maxf(absf(from.z - lo.y), absf(from.z - lo.y - TILE_M))
		sign = -1 if Vector2(dx, dz).length() <= _far_edge_m(T3, true) else 1
	var per := int(TILE_M / WorldData.TREE_CHUNK_M)
	for cz in per:
		for cx in per:
			var chunk := Vector2i(tile.x * per + cx, tile.y * per + cz)
			var raw := chunk_records(chunk)
			var ci := WorldData.tree_chunk_index(chunk)
			for i in raw.size() / RECORD_BYTES:
				var r := decode(raw, chunk, i)
				if r.model >= _variants.size() or (_variants[r.model] as Array).is_empty():
					continue
				var h := record_hash(ci, i)
				var options: Array = _variants[r.model]
				var v: Array = options[h % options.size()]
				var k: float = v[1] * r.scale
				var pos := _world.map_to_world(Vector3(r.map.x, 0.0, r.map.y))
				pos.y = _world.height_at(pos.x, pos.z) + float(v[2]) * r.scale
				var tint := ((h >> 16) & 255) / 127.5 - 1.0
				buf.append_array([k, 0.0, 0.0, pos.x, 0.0, k, 0.0, pos.y, 0.0, 0.0, k, pos.z])
				buf.append_array([((h >> 8) & 255) / 255.0, tint, 0.0, float(v[0])])
				count += 1
				if sorted:
					keys.append(sign * Vector2(r.map.x - from.x, r.map.y - from.z).length())
	if sorted:
		var slot := [buf, count, keys]
		_sort_slot(slot)
		buf = slot[0]
		keys = slot[2]
	return [buf, count, keys, sign]


## Tier k's visible range edge (T2 chunks, T3 tiles): the end + half a band
## (`outer`), or the start - half a band.
func _far_edge_m(k: int, outer: bool) -> float:
	if outer:
		return float(tiers_m[k]) + _band() * 0.5
	return float(tiers_m[k - 1]) - _band() * 0.5


## Tiles whose nearest point is within `reach_m` of the engine position.
func tiles_within(eye: Vector3, reach_m: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var m := _world.world_to_map(eye)
	for tz in _tiles_per_side:
		for tx in _tiles_per_side:
			var nx := clampf(m.x, tx * TILE_M, (tx + 1) * TILE_M)
			var nz := clampf(m.z, tz * TILE_M, (tz + 1) * TILE_M)
			if Vector2(m.x - nx, m.z - nz).length() <= reach_m:
				out.append(Vector2i(tx, tz))
	return out


## The far reach: T3 end plus the fade band.
func reach_m() -> float:
	return float(tiers_m[T3]) + float(_cfg.get("fade_band_m", 0.0))


## Tiles are built this far: the far reach plus the distance the camera can
## move before tiles are selected again.
func build_reach_m() -> float:
	return reach_m() + RESELECT_M


func built_tiles() -> Array:
	return _tiles.keys()


func built_chunks() -> Array:
	return _chunks.keys()


func is_settled() -> bool:
	var tiles := _wanted.all(func(t: Vector2i) -> bool: return _tiles.has(t))
	var chunks := _wanted_chunks.all(func(c: Vector2i) -> bool: return _chunks.has(c))
	var near := (
		_models.is_empty()
		or (_near_task < 0 and _near_assigning.is_empty() and _near_line.x != 1 << 30)
	)
	return _pending.is_empty() and _pending_chunks.is_empty() and tiles and chunks and near


## Whether T2 shadows come from the near set (06 §A3, Q-109g): T2 casts,
## and the shadow distance reaches past the T1 end into the T2 range.
func t2_ring() -> bool:
	return (
		t2_shadows
		and float(tiers_m[T2]) > float(tiers_m[T1])
		and shadow_distance_m > float(tiers_m[T1])
	)


## Where the near buffer of tier k ends before padding: the tier's end; for
## T2 (shadow casters only) the shadow distance, within the T2 range.
func _near_end(k: int) -> float:
	if k == T2:
		return minf(shadow_distance_m, float(tiers_m[T2])) if t2_ring() else 0.0
	return float(tiers_m[k])


## Distance window [from, to] (metres) in which a tree goes into tier k's
## near buffer (T0, T1, T2 casters): the range widened by half a band and
## the slack.
func near_window(k: int) -> Vector2:
	var start := 0.0 if k == 0 else float(tiers_m[k - 1])
	var end := _near_end(k)
	if end <= start:
		return Vector2(1.0, 0.0)
	var pad := _band() * 0.5 + NEAR_SLACK_M
	return Vector2(maxf(0.0, start - pad) if start > 0.0 else 0.0, end + pad)


## Near-set buffers around a map position: per model index an array of
## [buffer, count, distances] slots at tier * near_sectors + sector (tiers
## T0, T1, T2 casters), each slot's instances ordered by their distance from `map`
## (ascending, in `distances`) so a prefix holds the nearer trees.
func near_buffers(map: Vector3) -> Dictionary:
	var out := {}
	var sectors := maxi(1, near_sectors)
	var windows := [near_window(T0), near_window(T1), near_window(T2)]
	var reach := 0.0
	for w: Vector2 in windows:
		reach = maxf(reach, w.y)
	var lo := WorldData.tree_chunk_of_map(map - Vector3(reach, 0.0, reach))
	var hi := WorldData.tree_chunk_of_map(map + Vector3(reach, 0.0, reach))
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var chunk := Vector2i(cx, cz)
			var raw := chunk_records(chunk)
			var ci := WorldData.tree_chunk_index(chunk)
			for i in raw.size() / RECORD_BYTES:
				var r := decode(raw, chunk, i)
				var d := Vector2(r.map.x - map.x, r.map.y - map.z).length()
				if d > reach or r.model >= _variants.size():
					continue
				var options: Array = _variants[r.model]
				if options.is_empty():
					continue
				var h := record_hash(ci, i)
				var v: Array = options[h % options.size()]
				if int(v[3]) < 0:
					continue
				var entry: Array = out.get_or_add(int(v[3]), _empty_slots(3 * sectors))
				var angle := atan2(r.map.y - map.z, r.map.x - map.x) + PI
				var sector := mini(int(angle / TAU * sectors), sectors - 1)
				var row := PackedFloat32Array()
				for k in 3:
					var w: Vector2 = windows[k]
					if d < w.x or d > w.y:
						continue
					if row.is_empty():
						row = _instance_row(r, h, v)
					var slot: Array = entry[k * sectors + sector]
					var buf: PackedFloat32Array = slot[0]
					buf.append_array(row)
					slot[0] = buf
					slot[1] = int(slot[1]) + 1
					var dists: PackedFloat32Array = slot[2]
					dists.append(d)
					slot[2] = dists
	for entry: Array in out.values():
		for slot: Array in entry:
			_sort_slot(slot)
	return out


## Orders a near-set slot's instances by distance (Vector2 sorts by x first).
static func _sort_slot(slot: Array) -> void:
	var dists: PackedFloat32Array = slot[2]
	if dists.size() < 2:
		return
	var keys: Array[Vector2] = []
	for i in dists.size():
		keys.append(Vector2(dists[i], i))
	keys.sort()
	var src: PackedFloat32Array = slot[0]
	var buf := PackedFloat32Array()
	buf.resize(src.size())
	for n in keys.size():
		var i := int(keys[n].y)
		dists[n] = keys[n].x
		for c in STRIDE:
			buf[n * STRIDE + c] = src[i * STRIDE + c]
	slot[0] = buf
	slot[2] = dists


## Distance from a near set's build point beyond which no tree of tier k
## (T0, T1; T2 casters) can be visible while the eye is `offset_m` from
## that point: the shader fades on the distance to the eye and keeps nothing
## past the tier's end + half a band (06 §A3); T2 casters end at the shadow
## distance.
func near_cut_m(k: int, offset_m: float) -> float:
	return _near_end(k) + _band() * 0.5 + offset_m


static func _empty_slots(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append([PackedFloat32Array(), 0, PackedFloat32Array()])
	return out


func _instance_row(r: Dictionary, h: int, v: Array) -> PackedFloat32Array:
	var pos := _world.map_to_world(Vector3(r.map.x, 0.0, r.map.y))
	pos.y = _world.height_at(pos.x, pos.z)
	var b := Basis(Vector3.UP, r.yaw).scaled(Vector3.ONE * r.scale)
	var row := PackedFloat32Array([b.x.x, b.y.x, b.z.x, pos.x, b.x.y, b.y.y, b.z.y, pos.y])
	row.append_array([b.x.z, b.y.z, b.z.z, pos.z])
	row.append_array([((h >> 8) & 255) / 255.0, ((h >> 16) & 255) / 127.5 - 1.0, 0.0, float(v[0])])
	return row


func _update_near(eye: Vector3) -> void:
	var map := _world.world_to_map(eye)
	if _near_task >= 0 and WorkerThreadPool.is_task_completed(_near_task):
		WorkerThreadPool.wait_for_task_completion(_near_task)
		_near_task = -1
		_mutex.lock()
		var result: Variant = _near_result
		_near_result = null
		_mutex.unlock()
		if result is Array:
			_near_assigning = [result[0], result[1], 0, [0, 0]]
			near_assign_usec = 0
	if not _near_assigning.is_empty():
		_assign_near_slice()
	_cut_near(map)
	var line := Vector2i(floori(map.x / NEAR_LINE_M), floori(map.z / NEAR_LINE_M))
	if line != _near_line and _near_task < 0:
		_near_line = line
		_near_task = WorkerThreadPool.add_task(_build_near.bind(map), false, "tree near set")


func _build_near(map: Vector3) -> void:
	var result := near_buffers(map)
	_mutex.lock()
	_near_result = [map, result]
	_mutex.unlock()


## Assigns the pending near set's models until the time slice is used.
func _assign_near_slice() -> void:
	var t0 := Time.get_ticks_usec()
	var buffers: Dictionary = _near_assigning[1]
	var totals: Array = _near_assigning[3]
	var sectors := maxi(1, near_sectors)
	var model: int = _near_assigning[2]
	while model < _models.size() and Time.get_ticks_usec() - t0 < NEAR_SLICE_USEC:
		var entry: Array = buffers.get(model, _empty_slots(3 * sectors))
		for j in NEAR_KIND_TIER.size() * sectors:
			var k := j / sectors
			var slot: Array = entry[int(NEAR_KIND_TIER[k]) * sectors + j % sectors]
			var node: MultiMeshInstance3D = (_near[model] as Array)[j]
			if node == null:
				if int(slot[1]) == 0:
					continue
				node = _near_node(model, k, j)
			var mm := node.multimesh
			mm.visible_instance_count = -1
			if mm.instance_count != int(slot[1]):
				mm.instance_count = int(slot[1])
			if int(slot[1]) > 0:
				mm.buffer = slot[0]
			node.visible = int(slot[1]) > 0
			(_near_dists[model] as Array)[j] = slot[2]
			if k < 2:
				totals[k] += int(slot[1])
		_near_from[model] = _near_assigning[0]
		_cut_eye = Vector3(INF, INF, INF)
		model += 1
	_near_assigning[2] = model
	near_assign_usec = maxi(near_assign_usec, Time.get_ticks_usec() - t0)
	if model >= _models.size():
		near_map = _near_assigning[0]
		near_instances = totals
		_near_assigning = []


## The cut now in use for tier k (T0, T1) of the near set built around
## near_map: trees farther from near_map are in the buffer but not drawn.
func near_cut_now_m(k: int) -> float:
	var o := Vector2(_cut_eye.x - near_map.x, _cut_eye.z - near_map.z).length()
	return near_cut_m(k, o + CUT_STEP_M)


## Draws only the prefix of each near buffer that can be visible from the
## eye at `map` (near_cut_m), widened by CUT_STEP_M and worked out again
## when the eye moved that far. A shadow caster is cut like its tier.
func _cut_near(map: Vector3) -> void:
	if Vector2(map.x - _cut_eye.x, map.z - _cut_eye.z).length() < CUT_STEP_M:
		return
	_cut_eye = map
	var sectors := maxi(1, near_sectors)
	for model in _near.size():
		var from: Vector3 = _near_from[model]
		var offset := Vector2(map.x - from.x, map.z - from.z).length() + CUT_STEP_M
		var nodes: Array = _near[model]
		for j in nodes.size():
			var node: MultiMeshInstance3D = nodes[j]
			if node == null or not node.visible:
				continue
			var dists: PackedFloat32Array = (_near_dists[model] as Array)[j]
			var n := dists.bsearch(near_cut_m(NEAR_KIND_TIER[j / sectors], offset), false)
			var mm := node.multimesh
			if n >= mm.instance_count:
				n = -1
			if mm.visible_instance_count != n:
				mm.visible_instance_count = n
	for t: Vector2i in _tiles:
		var tile: Array = _tiles[t]
		var keys: PackedFloat32Array = tile[2]
		var mm: MultiMesh = (tile[0] as MultiMeshInstance3D).multimesh
		var at: Vector3 = tile[1]
		var off := Vector2(map.x - at.x, map.z - at.z).length() + CHUNK_CUT_STEP_M
		var limit := _tile_cut_key(int(tile[3]), off)
		var n := -1
		if limit < INF and not keys.is_empty():
			n = keys.bsearch(limit, false)
			if n >= mm.instance_count:
				n = -1
		if mm.visible_instance_count != n:
			mm.visible_instance_count = n


## k: 0 T0, 1 T1 (both draw only), 2 T1's shadow caster (T2 mesh), 3 T0's
## shadow caster (T1 mesh), 4 T2's shadow caster (T2 mesh, the ring of
## t2_ring()); j: its slot (kind * near_sectors + sector).
func _near_node(model: int, k: int, j: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var m: Dictionary = _models[model]
	var meshes: Array = m.meshes
	mm.mesh = [meshes[T0], meshes[T1], m.shadow, m.shadow_t0, meshes[T2]][k]
	var node := MultiMeshInstance3D.new()
	var kinds := ["t0", "t1", "t1_shadow", "t0_shadow", "t2_shadow"]
	node.name = "Near_%s_%s_%d" % [m.stem, kinds[k], j]
	node.multimesh = mm
	node.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if k < 2
		else GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	)
	add_child(node)
	(_near[model] as Array)[j] = node
	return node


func _band() -> float:
	return float(_cfg.get("fade_band_m", 0.0))


## Nearest and farthest horizontal distance from an engine position to a chunk.
func _chunk_near(eye: Vector3, c: Vector2i) -> float:
	var m := _world.world_to_map(eye)
	var lo := Vector2(c) * WorldData.TREE_CHUNK_M
	var p := Vector2(m.x, m.z)
	return p.distance_to(p.clamp(lo, lo + Vector2.ONE * WorldData.TREE_CHUNK_M))


func _chunk_far(eye: Vector3, c: Vector2i) -> float:
	var m := _world.world_to_map(eye)
	var lo := Vector2(c) * WorldData.TREE_CHUNK_M
	var dx := maxf(absf(m.x - lo.x), absf(m.x - lo.x - WorldData.TREE_CHUNK_M))
	var dz := maxf(absf(m.z - lo.y), absf(m.z - lo.y - WorldData.TREE_CHUNK_M))
	return Vector2(dx, dz).length()


## Chunks reaching into the T2 range: nearest point within T2 end + band and
## farthest point beyond T1 end - band / 2 (Q-108), each widened by the
## distance the camera can move before chunks are selected again.
func mid_chunks(eye: Vector3) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var reach := float(tiers_m[T2]) + _band() + CHUNK_RESELECT_M
	var inner := float(tiers_m[T1]) - _band() * 0.5 - CHUNK_RESELECT_M
	if float(tiers_m[T2]) <= float(tiers_m[T1]):
		return out
	var m := _world.world_to_map(eye)
	var n := int(ceil(reach / WorldData.TREE_CHUNK_M)) + 1
	var at := WorldData.tree_chunk_of_map(m)
	var side := mini(
		WorldData.TREE_CHUNKS_PER_SIDE, _tiles_per_side * int(TILE_M / WorldData.TREE_CHUNK_M)
	)
	for cz in range(maxi(0, at.y - n), mini(side, at.y + n + 1)):
		for cx in range(maxi(0, at.x - n), mini(side, at.x + n + 1)):
			var c := Vector2i(cx, cz)
			if _chunk_near(eye, c) <= reach and _chunk_far(eye, c) > inner:
				out.append(c)
	return out


## T2 instance buffers of a chunk: {model index: [buffer, count, distances]};
## each instance turned by the record's yaw, scaled, standing on the ground,
## and ordered by its distance from map position `from` (ascending, in
## distances), so a prefix holds the nearer trees.
func chunk_buffers(chunk: Vector2i, from: Vector3 = Vector3.ZERO) -> Dictionary:
	var out := {}
	var raw := chunk_records(chunk)
	var ci := WorldData.tree_chunk_index(chunk)
	for i in raw.size() / RECORD_BYTES:
		var r := decode(raw, chunk, i)
		if r.model >= _variants.size() or (_variants[r.model] as Array).is_empty():
			continue
		var h := record_hash(ci, i)
		var options: Array = _variants[r.model]
		var v: Array = options[h % options.size()]
		var model: int = v[3]
		if model < 0:
			continue
		var pos := _world.map_to_world(Vector3(r.map.x, 0.0, r.map.y))
		pos.y = _world.height_at(pos.x, pos.z)
		var b := Basis(Vector3.UP, r.yaw).scaled(Vector3.ONE * r.scale)
		var entry: Array = out.get_or_add(model, [PackedFloat32Array(), 0, PackedFloat32Array()])
		var buf: PackedFloat32Array = entry[0]
		buf.append_array([b.x.x, b.y.x, b.z.x, pos.x, b.x.y, b.y.y, b.z.y, pos.y])
		buf.append_array([b.x.z, b.y.z, b.z.z, pos.z])
		buf.append_array(
			[((h >> 8) & 255) / 255.0, ((h >> 16) & 255) / 127.5 - 1.0, 0.0, float(v[0])]
		)
		entry[0] = buf
		entry[1] = int(entry[1]) + 1
		var dists: PackedFloat32Array = entry[2]
		dists.append(Vector2(r.map.x - from.x, r.map.y - from.z).length())
		entry[2] = dists
	for entry: Array in out.values():
		_sort_slot(entry)
	return out


## Distance from a chunk's sort point beyond which no T2 tree can be visible
## while the eye is `offset_m` from that point (T2 end + half a band).
func _chunk_cut_m(offset_m: float) -> float:
	return _far_edge_m(T2, true) + offset_m


## Key limit of a tile sorted with `sign` while the eye is `offset_m` from
## its sort point: billboards with a larger key cannot be visible; INF: none
## cut.
func _tile_cut_key(sign: int, offset_m: float) -> float:
	if sign > 0:
		return _far_edge_m(T3, true) + offset_m
	if sign < 0:
		var inner := _far_edge_m(T3, false) - offset_m
		return -inner if inner > 0.0 else INF
	return INF


## The cut now in use for a built T2 chunk or T3 tile `cell` (k = T2 or T3):
## [sort point (map), sign, key limit]; an instance whose key (sign x its
## distance from the sort point) is above the limit is in the buffer but not
## drawn.
func far_cut_now(k: int, cell: Vector2i) -> Array:
	if k == T2:
		var entry: Array = _chunks[cell]
		var from: Vector3 = entry[2]
		var o := Vector2(_chunk_cut_eye.x - from.x, _chunk_cut_eye.z - from.z).length()
		return [from, 1, _chunk_cut_m(o + CHUNK_CUT_STEP_M)]
	var tile: Array = _tiles[cell]
	var at: Vector3 = tile[1]
	var off := Vector2(_chunk_cut_eye.x - at.x, _chunk_cut_eye.z - at.z).length()
	return [at, int(tile[3]), _tile_cut_key(int(tile[3]), off + CHUNK_CUT_STEP_M)]


func _build_chunk(chunk: Vector2i, from: Vector3) -> void:
	var result := chunk_buffers(chunk, from)
	_mutex.lock()
	_done_chunks[chunk] = [from, result]
	_mutex.unlock()


func _finish_chunks() -> void:
	for c: Vector2i in _pending_chunks.keys():
		if not WorkerThreadPool.is_task_completed(_pending_chunks[c]):
			continue
		WorkerThreadPool.wait_for_task_completion(_pending_chunks[c])
		_pending_chunks.erase(c)
		_mutex.lock()
		var result: Variant = _done_chunks.get(c)
		_done_chunks.erase(c)
		_mutex.unlock()
		if result == null or not _wanted_chunks.has(c):
			continue
		if _chunks.has(c):
			_free_chunk(c)  # sorted again: the new version replaces it
		_add_chunk(c, result[1], result[0])


func _add_chunk(c: Vector2i, buffers: Dictionary, from: Vector3) -> void:
	var holder := Node3D.new()
	holder.name = "Chunk_%d_%d" % [c.x, c.y]
	var count := 0
	var cuts: Array = []
	for model: int in buffers:
		var entry: Array = buffers[model]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = (_models[model].meshes as Array)[T2]
		mm.instance_count = entry[1]
		mm.buffer = entry[0]
		var node := MultiMeshInstance3D.new()
		node.name = "Mid_%s" % _models[model].stem
		node.multimesh = mm
		node.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if t2_shadows and not t2_ring()
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		holder.add_child(node)
		count += int(entry[1])
		cuts.append([mm, entry[2]])
	add_child(holder)
	_chunks[c] = [holder, count, from, cuts]
	mid_instances += count
	_chunk_cut_eye = Vector3(INF, INF, INF)


## Draws only the prefix of each chunk and tile buffer that can be visible
## from the eye at map position `map` (_chunk_cut_m, _tile_cut_key), widened
## by CHUNK_CUT_STEP_M and worked out again when the eye moved that far.
func _cut_chunks(map: Vector3) -> void:
	if Vector2(map.x - _chunk_cut_eye.x, map.z - _chunk_cut_eye.z).length() < CHUNK_CUT_STEP_M:
		return
	_chunk_cut_eye = map
	for c: Vector2i in _chunks:
		var entry: Array = _chunks[c]
		var from: Vector3 = entry[2]
		var cut := _chunk_cut_m(Vector2(map.x - from.x, map.z - from.z).length() + CHUNK_CUT_STEP_M)
		var lo := Vector2(c) * WorldData.TREE_CHUNK_M
		var p := Vector2(from.x, from.z)
		var dx := maxf(absf(p.x - lo.x), absf(p.x - lo.x - WorldData.TREE_CHUNK_M))
		var dz := maxf(absf(p.y - lo.y), absf(p.y - lo.y - WorldData.TREE_CHUNK_M))
		var whole := Vector2(dx, dz).length() <= cut
		for pair: Array in entry[3]:
			var mm: MultiMesh = pair[0]
			var n := -1
			if not whole:
				n = (pair[1] as PackedFloat32Array).bsearch(cut, false)
				if n >= mm.instance_count:
					n = -1
			if mm.visible_instance_count != n:
				mm.visible_instance_count = n


func _free_chunk(c: Vector2i) -> void:
	var entry: Array = _chunks[c]
	mid_instances -= int(entry[1])
	(entry[0] as Node3D).queue_free()
	_chunks.erase(c)


## Loads a model's tier meshes and gives each tier surface its material;
## returns its index in _models, or -1 (with an error) when it cannot.
func _load_model(root: String, stem: String, e: Dictionary, d: Dictionary) -> int:
	var path := root.path_join(MODEL_DIR).path_join(stem + ".glb")
	if not ResourceLoader.exists(path):
		errors.append("%s: missing" % path)
		return -1
	var node := (load(path) as PackedScene).instantiate()
	var meshes: Array = []
	for tier in 3:
		var found := node.find_children("*_t%d" % tier, "MeshInstance3D", true, false)
		meshes.append((found[0] as MeshInstance3D).mesh if not found.is_empty() else null)
	node.free()
	if meshes.has(null):
		errors.append("%s: missing a tier mesh" % path)
		return -1
	var dir := root.path_join(TEXTURE_DIR)
	var flex := TreeShading.flex(_cfg, String(d.species))
	for tier in 3:
		meshes[tier] = merged_surfaces(meshes[tier])
	# The T2 mesh again, faded as T1: the shadow caster of the T1 instances;
	# the T1 mesh again, faded as T0: the shadow caster of the T0 instances.
	var shadow: Mesh = (meshes[T2] as Mesh).duplicate()
	var shadow_t0: Mesh = (meshes[T1] as Mesh).duplicate()
	var bark: String = e.get("bark_set")
	var leaf: Variant = e.get("leaf_set")
	var targets: Array[Mesh] = [meshes[T0], meshes[T1], meshes[T2], shadow, shadow_t0]
	for tier in targets.size():
		var m := ShaderMaterial.new()
		m.shader = load(FOLIAGE)
		m.set_shader_parameter("tier", [T0, T1, T2, T1, T0][tier])
		m.set_shader_parameter("height_m", float(d.height_m))
		m.set_shader_parameter("flex", flex)
		m.set_shader_parameter("bark_albedo", _texture(dir, "tree_%s_bark_ah.png" % bark))
		m.set_shader_parameter("bark_nra", _texture(dir, "tree_%s_bark_nra.png" % bark))
		if leaf is String:
			m.set_shader_parameter("leaf_albedo", _texture(dir, "tree_%s_leaves_ca.png" % leaf))
			m.set_shader_parameter("leaf_nra", _texture(dir, "tree_%s_leaves_nra.png" % leaf))
		targets[tier].surface_set_material(0, m)
	(
		_models
		. append(
			{
				"stem": stem,
				"height_m": float(d.height_m),
				"meshes": meshes,
				"shadow": shadow,
				"shadow_t0": shadow_t0,
			}
		)
	)
	var slots: Array = []
	slots.resize(NEAR_KIND_TIER.size() * maxi(1, near_sectors))
	_near.append(slots)
	var dists: Array = []
	dists.resize(slots.size())
	_near_dists.append(dists)
	_near_from.append(Vector3(INF, INF, INF))
	return _models.size() - 1


## One surface holding all of a mesh's surfaces (bark and leaf cards share
## one material, Q-110).
static func merged_surfaces(mesh: Mesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in mesh.get_surface_count():
		st.append_from(mesh, s, Transform3D.IDENTITY)
	return st.commit()


func _texture(dir: String, name: String) -> Texture2D:
	var path := dir.path_join(name)
	if not _textures.has(path):
		_textures[path] = load(path)
	return _textures[path]


## Builds read this node from worker threads: finish them before it goes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		for t: Vector2i in _pending.keys():
			WorkerThreadPool.wait_for_task_completion(_pending[t])
		for c: Vector2i in _pending_chunks.keys():
			WorkerThreadPool.wait_for_task_completion(_pending_chunks[c])
		_pending.clear()
		_done.clear()
		_pending_chunks.clear()
		_done_chunks.clear()
		if _near_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_near_task)
			_near_task = -1


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and is_ready():
		update_for(cam.global_position)


## Starts, finishes and frees tile builds for a camera at `eye`.
func update_for(eye: Vector3) -> void:
	TreeShading.set_camera(eye)
	if eye.distance_to(_last_eye) >= RESELECT_M:
		_last_eye = eye
		_wanted = tiles_within(eye, build_reach_m())
		var keep := tiles_within(eye, build_reach_m() + KEEP_EXTRA_M)
		for t: Vector2i in _tiles.keys():
			if not keep.has(t):
				_free_tile(t)
	_finish_builds()
	var eye_map := _world.world_to_map(eye)
	for t in _wanted:
		if _pending.size() >= MAX_BUILDS:
			break
		if _pending.has(t):
			continue
		var stale := false
		if _tiles.has(t):
			var at: Vector3 = (_tiles[t] as Array)[1]
			stale = Vector2(eye_map.x - at.x, eye_map.z - at.z).length() > TILE_RESORT_M
		if not _tiles.has(t) or stale:
			_pending[t] = WorkerThreadPool.add_task(_build.bind(t, eye_map), false, "tree tile")
	if _models.is_empty():
		return
	_update_near(eye)
	if eye.distance_to(_last_chunk_eye) >= CHUNK_RESELECT_M:
		_last_chunk_eye = eye
		_wanted_chunks = mid_chunks(eye)
		var far := float(tiers_m[T2]) + _band() + T2_KEEP_EXTRA_M
		for c: Vector2i in _chunks.keys():
			if _chunk_near(eye, c) > far:
				_free_chunk(c)
	_finish_chunks()
	var map := _world.world_to_map(eye)
	_cut_chunks(map)
	for c in _wanted_chunks:
		if _pending_chunks.size() >= MAX_BUILDS:
			break
		if _pending_chunks.has(c):
			continue
		var stale := false
		if _chunks.has(c):
			var from: Vector3 = (_chunks[c] as Array)[2]
			stale = Vector2(map.x - from.x, map.z - from.z).length() > CHUNK_RESORT_M
		if not _chunks.has(c) or stale:
			_pending_chunks[c] = WorkerThreadPool.add_task(
				_build_chunk.bind(c, map), false, "tree chunk"
			)


func _build(tile: Vector2i, from: Vector3) -> void:
	var result := tile_buffer(tile, from)
	result.append(from)
	_mutex.lock()
	_done[tile] = result
	_mutex.unlock()


func _finish_builds() -> void:
	for t: Vector2i in _pending.keys():
		if not WorkerThreadPool.is_task_completed(_pending[t]):
			continue
		WorkerThreadPool.wait_for_task_completion(_pending[t])
		_pending.erase(t)
		_mutex.lock()
		var result: Array = _done.get(t, [])
		_done.erase(t)
		_mutex.unlock()
		if result.is_empty() or not _wanted.has(t):
			continue
		if _tiles.has(t):
			_free_tile(t)  # sorted again: the new version replaces it
		_add_tile(t, result)


## Adds a tile from a finished build: [buffer, count, keys, sign, sort point].
func _add_tile(t: Vector2i, result: Array) -> void:
	var buf: PackedFloat32Array = result[0]
	var count: int = result[1]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _quad
	mm.instance_count = count
	if count > 0:
		mm.buffer = buf
	var node := MultiMeshInstance3D.new()
	node.name = "Tile_%d_%d" % [t.x, t.y]
	node.multimesh = mm
	node.material_override = _material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lo := _world.map_to_world(Vector3(t.x * TILE_M, 0.0, t.y * TILE_M))
	node.custom_aabb = AABB(Vector3(lo.x, -200.0, lo.z), Vector3(TILE_M, 2400.0, TILE_M))
	add_child(node)
	_tiles[t] = [node, result[4], result[2], result[3]]
	instances += count
	_chunk_cut_eye = Vector3(INF, INF, INF)


func _free_tile(t: Vector2i) -> void:
	var node: MultiMeshInstance3D = (_tiles[t] as Array)[0]
	instances -= node.multimesh.instance_count
	node.queue_free()
	_tiles.erase(t)


## Fills _variants and _material from the manifest and atlas, or stand-ins.
func _setup_models(root: String) -> void:
	var manifest_path := root.path_join(MODEL_DIR).path_join(MANIFEST)
	var atlas := root.path_join(TEXTURE_DIR).path_join("tree_billboards_%s.png")
	var manifest: Variant = null
	if FileAccess.file_exists(manifest_path) and ResourceLoader.exists(atlas % "ca"):
		manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	_material = ShaderMaterial.new()
	_material.shader = load(SHADER)
	_variants.clear()
	_models.clear()
	_near.clear()
	var flexes := PackedFloat32Array()
	flexes.resize(CELLS)
	if manifest is Dictionary:
		var models: Dictionary = manifest.get("models", {})
		for d: Dictionary in _defs:
			var options: Array = []
			for stem: String in d.get("models", []):
				if not models.has(stem):
					errors.append("%s: no billboard for model %s" % [MANIFEST, stem])
					continue
				var e: Dictionary = models[stem]
				var model := _load_model(root, stem, e, d)
				options.append([int(e.cell), float(e.side_m), float(e.bottom_m), model])
				flexes[clampi(int(e.cell), 0, CELLS - 1)] = TreeShading.flex(
					_cfg, String(d.species)
				)
			_variants.append(options)
		_material.set_shader_parameter("atlas_ca", load(atlas % "ca"))
		_material.set_shader_parameter("atlas_n", load(atlas % "n"))
		_material.set_shader_parameter("atlas_grid", float(manifest.get("grid", 1)))
	else:
		for d: Dictionary in _defs:
			var side := maxf(float(d.height_m), 2.0 * float(d.canopy_r_m))
			_variants.append([[0, side, 0.0, -1]])
		_material.set_shader_parameter("atlas_ca", _plain(STAND_IN_COLOR))
		_material.set_shader_parameter("atlas_n", _plain(Color(0.5, 0.5, 1.0)))
		_material.set_shader_parameter("atlas_grid", 1.0)
	_material.set_shader_parameter("cell_flex", flexes)


static func _plain(c: Color) -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
