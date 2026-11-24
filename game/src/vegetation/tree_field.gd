class_name TreeField
extends Node3D
## The world's trees (06 §A3): reads the tree chunk files (04 §2, 7-byte
## records) and draws the far tier T3, one MultiMesh of billboards per 512 m
## tile for all models, built on a worker thread when the tile comes within
## the preset's T3 range and freed when it leaves it (Q-107).
##
## Per record, a hash of (chunk, record index) picks the model variant from
## the type's `models`, the wind phase and the tint. Billboards use the atlas
## and the models manifest written by the asset tools; without them (sample
## content) a flat stand-in quad is drawn.

const MODEL_DIR := "assets/models/trees"
const TEXTURE_DIR := "assets/textures/trees"
const MANIFEST := "tree_models.json"
const SHADER := "res://shaders/impostor.gdshader"
const FOLDER := "trees"
const RECORD_BYTES := 7
## A chunk holds at most 4,095 trees (06 §A6): record indices fit 12 bits.
const RECORD_BITS := 12
const TILE_M := 512.0
const RESELECT_M := 64.0
const KEEP_EXTRA_M := 256.0
const MAX_BUILDS := 2
const T3 := 3
## 16 floats per instance: a 3 x 4 transform, then custom data.
const STRIDE := 16
const CELLS := 64
const STAND_IN_COLOR := Color(0.25, 0.32, 0.2)

var errors: PackedStringArray = []
## Instances in the built tiles (for checks and the perf overlay).
var instances := 0
var tiers_m: Array = []

var _world: WorldData
var _defs: Array = []
var _cfg := {}
## Per tree type: [[cell, side_m, bottom_m] per variant].
var _variants: Array = []
var _material: ShaderMaterial
var _quad := ArrayMesh.new()
var _tiles_per_side := 0
var _tiles := {}
var _pending := {}
var _done := {}
var _mutex := Mutex.new()
var _last_eye := Vector3(INF, INF, INF)
var _wanted: Array[Vector2i] = []


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


## Decoded records of a chunk (empty when it has no trees).
func chunk_records(chunk: Vector2i) -> PackedByteArray:
	var name := "%d_%d.bin" % [chunk.x, chunk.y]
	var entry: Dictionary = _world.index_of(FOLDER).get("files", {}).get(name, {})
	if entry.is_empty():
		return PackedByteArray()
	var size := int(entry.count) * RECORD_BYTES
	return _world.read_indexed_bytes(FOLDER, name).decompress(size, FileAccess.COMPRESSION_ZSTD)


## The MultiMesh buffer of a tile: [buffer, instance count].
func tile_buffer(tile: Vector2i) -> Array:
	var buf := PackedFloat32Array()
	var count := 0
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
	return [buf, count]


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


func built_tiles() -> Array:
	return _tiles.keys()


func is_settled() -> bool:
	return _pending.is_empty() and _wanted.all(func(t: Vector2i) -> bool: return _tiles.has(t))


## Builds read this node from worker threads: finish them before it goes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		for t: Vector2i in _pending.keys():
			WorkerThreadPool.wait_for_task_completion(_pending[t])
		_pending.clear()
		_done.clear()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and is_ready():
		update_for(cam.global_position)


## Starts, finishes and frees tile builds for a camera at `eye`.
func update_for(eye: Vector3) -> void:
	TreeShading.set_camera(eye)
	if eye.distance_to(_last_eye) >= RESELECT_M:
		_last_eye = eye
		_wanted = tiles_within(eye, reach_m())
		var keep := tiles_within(eye, reach_m() + KEEP_EXTRA_M)
		for t: Vector2i in _tiles.keys():
			if not keep.has(t):
				_free_tile(t)
	_finish_builds()
	for t in _wanted:
		if _pending.size() >= MAX_BUILDS:
			break
		if not _tiles.has(t) and not _pending.has(t):
			_pending[t] = WorkerThreadPool.add_task(_build.bind(t), false, "tree tile")


func _build(tile: Vector2i) -> void:
	var result := tile_buffer(tile)
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
		_add_tile(t, result[0], result[1])


func _add_tile(t: Vector2i, buf: PackedFloat32Array, count: int) -> void:
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
	_tiles[t] = node
	instances += count


func _free_tile(t: Vector2i) -> void:
	var node: MultiMeshInstance3D = _tiles[t]
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
				options.append([int(e.cell), float(e.side_m), float(e.bottom_m)])
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
			_variants.append([[0, side, 0.0]])
		_material.set_shader_parameter("atlas_ca", _plain(STAND_IN_COLOR))
		_material.set_shader_parameter("atlas_n", _plain(Color(0.5, 0.5, 1.0)))
		_material.set_shader_parameter("atlas_grid", 1.0)
	_material.set_shader_parameter("cell_flex", flexes)


static func _plain(c: Color) -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
