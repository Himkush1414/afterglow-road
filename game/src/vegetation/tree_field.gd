class_name TreeField
extends Node3D
## The world's trees (06 §A3): reads the tree chunk files (04 §2, 7-byte
## records) and draws
## - the far tier T3: one MultiMesh of billboards per 512 m tile for all
##   models, built on a worker thread when the tile comes within the preset's
##   T3 range and freed when it leaves it (Q-107);
## - the mid tier T2: one MultiMesh per model per 128 m chunk, built on a
##   worker thread for the chunks reaching into the T2 range (Q-108).
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
const T1 := 1
const T2 := 2
const T3 := 3
const CHUNK_RESELECT_M := 16.0
const T2_KEEP_EXTRA_M := 64.0
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
## Instances in the built T2 chunks.
var mid_instances := 0

var _world: WorldData
var _defs: Array = []
var _cfg := {}
## Per tree type: [[cell, side_m, bottom_m, model index or -1] per variant].
var _variants: Array = []
## Per model (index from _variants): {"stem", "height_m", "meshes": [T0, T1, T2]}.
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


func built_chunks() -> Array:
	return _chunks.keys()


func is_settled() -> bool:
	var tiles := _wanted.all(func(t: Vector2i) -> bool: return _tiles.has(t))
	var chunks := _wanted_chunks.all(func(c: Vector2i) -> bool: return _chunks.has(c))
	return _pending.is_empty() and _pending_chunks.is_empty() and tiles and chunks


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
## farthest point beyond T1 end - band / 2 (Q-108).
func mid_chunks(eye: Vector3) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var reach := float(tiers_m[T2]) + _band()
	var inner := float(tiers_m[T1]) - _band() * 0.5
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


## T2 instance buffers of a chunk: {model index: [buffer, count]}; each
## instance turned by the record's yaw, scaled, standing on the ground.
func chunk_buffers(chunk: Vector2i) -> Dictionary:
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
		var entry: Array = out.get_or_add(model, [PackedFloat32Array(), 0])
		var buf: PackedFloat32Array = entry[0]
		buf.append_array([b.x.x, b.y.x, b.z.x, pos.x, b.x.y, b.y.y, b.z.y, pos.y])
		buf.append_array([b.x.z, b.y.z, b.z.z, pos.z])
		buf.append_array(
			[((h >> 8) & 255) / 255.0, ((h >> 16) & 255) / 127.5 - 1.0, 0.0, float(v[0])]
		)
		entry[0] = buf
		entry[1] = int(entry[1]) + 1
	return out


func _build_chunk(chunk: Vector2i) -> void:
	var result := chunk_buffers(chunk)
	_mutex.lock()
	_done_chunks[chunk] = result
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
		_add_chunk(c, result)


func _add_chunk(c: Vector2i, buffers: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Chunk_%d_%d" % [c.x, c.y]
	var count := 0
	for model: int in buffers:
		var entry: Array = buffers[model]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = (_models[model].meshes as Array)[T2]
		mm.instance_count = entry[1]
		mm.buffer = entry[0]
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if t2_shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)
		holder.add_child(node)
		count += int(entry[1])
	add_child(holder)
	_chunks[c] = [holder, count]
	mid_instances += count


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
		var mesh: Mesh = meshes[tier]
		for s in mesh.get_surface_count():
			var leaves := s == 1
			var tset: String = e.get("leaf_set") if leaves else e.get("bark_set")
			var kind := "leaves" if leaves else "bark"
			var m := ShaderMaterial.new()
			m.shader = load(FOLIAGE)
			m.set_shader_parameter("tier", tier)
			m.set_shader_parameter("leaves", leaves)
			m.set_shader_parameter("height_m", float(d.height_m))
			m.set_shader_parameter("flex", flex)
			var colour := "ca" if leaves else "ah"
			m.set_shader_parameter(
				"albedo_tex", _texture(dir, "tree_%s_%s_%s.png" % [tset, kind, colour])
			)
			m.set_shader_parameter(
				"normal_rough_ao", _texture(dir, "tree_%s_%s_nra.png" % [tset, kind])
			)
			mesh.surface_set_material(s, m)
	_models.append({"stem": stem, "height_m": float(d.height_m), "meshes": meshes})
	return _models.size() - 1


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
	if _models.is_empty():
		return
	if eye.distance_to(_last_chunk_eye) >= CHUNK_RESELECT_M:
		_last_chunk_eye = eye
		_wanted_chunks = mid_chunks(eye)
		var far := float(tiers_m[T2]) + _band() + T2_KEEP_EXTRA_M
		for c: Vector2i in _chunks.keys():
			if _chunk_near(eye, c) > far:
				_free_chunk(c)
	_finish_chunks()
	for c in _wanted_chunks:
		if _pending_chunks.size() >= MAX_BUILDS:
			break
		if not _chunks.has(c) and not _pending_chunks.has(c):
			_pending_chunks[c] = WorkerThreadPool.add_task(
				_build_chunk.bind(c), false, "tree chunk"
			)


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
	_models.clear()
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
