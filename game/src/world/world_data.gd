class_name WorldData
extends Node
## Read-only queries on the generated world (05 §6). Queries take engine
## coordinates; files, saves and logs use map coordinates. This is the only
## place that converts between them (D-20): the offset comes from meta.json.

## Region size and tree chunk size in metres (03 §7).
const REGION_M := 512.0
const REGIONS_PER_SIDE := 16
const TREE_CHUNK_M := 128.0
const TREE_CHUNKS_PER_SIDE := 64
## Biome cell size in metres (04 §2).
const BIOME_CELL_M := 16.0

var errors: PackedStringArray = []
var size_m := 0.0
var sample_m := 0.0
var origin_offset_m := 0.0
var samples := 0
var biome_cells := 0
var _height_scale := 0.0
var _height_offset := 0.0
var _heights := PackedByteArray()
var _biomes := PackedByteArray()
var _dir := ""
var _hashes := {}


## The world folder of the active content.
static func default_dir() -> String:
	return ContentDB.root + "/world"


## Loads meta.json, the height and biome files of `dir`, checking every
## file against its SHA-256 in meta.json. Returns true on success; otherwise
## `errors` says why and no data is kept.
func load_dir(dir: String) -> bool:
	errors.clear()
	_heights = PackedByteArray()
	_biomes = PackedByteArray()
	var meta_text := FileAccess.get_file_as_string(dir + "/meta.json")
	var meta: Variant = JSON.parse_string(meta_text)
	if not meta is Dictionary:
		errors.append("%s/meta.json: missing or not a JSON object" % dir)
		return false
	var m: Dictionary = meta
	size_m = float(m.get("size_m", 0.0))
	sample_m = float(m.get("sample_m", 0.0))
	origin_offset_m = float(m.get("origin_offset_m", 0.0))
	_height_scale = float(m.get("height_scale", 0.0))
	_height_offset = float(m.get("height_offset_m", 0.0))
	if size_m <= 0.0 or sample_m <= 0.0 or _height_scale <= 0.0:
		errors.append("%s/meta.json: size, sample spacing or height scale missing" % dir)
		return false
	samples = int(round(size_m / sample_m)) + 1
	_dir = dir
	_hashes = m.get("sha256", {})
	var cells := int(round(size_m / BIOME_CELL_M))
	var heights := read_layer("height.bin", samples * samples * 2)
	var biomes := read_layer("biome.bin", cells * cells)
	if not errors.is_empty():
		return false
	_heights = heights
	_biomes = biomes
	biome_cells = cells
	return true


## Decoded bytes of a ZSTD world file of the loaded folder (heights, biomes,
## LOD boxes, normals), checked against meta.json. Returns an
## empty array and appends to `errors` when the file is missing, changed or
## does not decode to `decoded_size` bytes.
func read_layer(file_name: String, decoded_size: int) -> PackedByteArray:
	var data := FileAccess.get_file_as_bytes(_dir + "/" + file_name)
	if data.is_empty():
		errors.append("%s/%s: missing or empty" % [_dir, file_name])
		return PackedByteArray()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	if ctx.finish().hex_encode() != str(_hashes.get(file_name, "")):
		errors.append("%s/%s: SHA-256 differs from meta.json" % [_dir, file_name])
		return PackedByteArray()
	var out := data.decompress(decoded_size, FileAccess.COMPRESSION_ZSTD)
	if out.size() != decoded_size:
		errors.append("%s/%s: %d bytes decoded" % [_dir, file_name, out.size()])
		return PackedByteArray()
	return out


## Text of a plain world file of the loaded folder (for example the water
## description), checked against meta.json. Returns "" and appends to
## `errors` when the file is missing or changed.
func read_text(file_name: String) -> String:
	var data := FileAccess.get_file_as_bytes(_dir + "/" + file_name)
	if data.is_empty():
		errors.append("%s/%s: missing or empty" % [_dir, file_name])
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	if ctx.finish().hex_encode() != str(_hashes.get(file_name, "")):
		errors.append("%s/%s: SHA-256 differs from meta.json" % [_dir, file_name])
		return ""
	return data.get_string_from_utf8()


## True when meta.json lists `file_name` (optional layers may be absent).
func has_layer(file_name: String) -> bool:
	return _hashes.has(file_name)


## The folder the world was loaded from.
func folder() -> String:
	return _dir


func is_loaded() -> bool:
	return not _heights.is_empty()


func map_to_world(v: Vector3) -> Vector3:
	return Vector3(v.x - origin_offset_m, v.y, v.z - origin_offset_m)


func world_to_map(v: Vector3) -> Vector3:
	return Vector3(v.x + origin_offset_m, v.y, v.z + origin_offset_m)


## Height of the encoded sample at column i, row j (map grid), clamped.
func sample(i: int, j: int) -> float:
	i = clampi(i, 0, samples - 1)
	j = clampi(j, 0, samples - 1)
	return _heights.decode_u16((j * samples + i) * 2) * _height_scale - _height_offset


## Height of a u16 height code (height.bin, minmax.bin).
func height_of_code(code: int) -> float:
	return code * _height_scale - _height_offset


## Terrain height at engine (x, z), on the triangles of the heightmap
## collision: each 2 m cell is split along the diagonal from (1, 0) to (0, 1).
func height_at(x: float, z: float) -> float:
	var fx := clampf((x + origin_offset_m) / sample_m, 0.0, samples - 1.0)
	var fz := clampf((z + origin_offset_m) / sample_m, 0.0, samples - 1.0)
	var i := mini(floori(fx), samples - 2)
	var j := mini(floori(fz), samples - 2)
	var tx := fx - i
	var tz := fz - j
	if tx + tz <= 1.0:
		var h00 := sample(i, j)
		return h00 + (sample(i + 1, j) - h00) * tx + (sample(i, j + 1) - h00) * tz
	var h11 := sample(i + 1, j + 1)
	return h11 + (sample(i, j + 1) - h11) * (1.0 - tx) + (sample(i + 1, j) - h11) * (1.0 - tz)


## Biome id at engine (x, z): the biome cell containing the point.
func biome_at(x: float, z: float) -> int:
	var i := clampi(floori((x + origin_offset_m) / BIOME_CELL_M), 0, biome_cells - 1)
	var j := clampi(floori((z + origin_offset_m) / BIOME_CELL_M), 0, biome_cells - 1)
	return _biomes[j * biome_cells + i]


## Region (rx, rz) of an engine position.
func region_of(pos: Vector3) -> Vector2i:
	return region_of_map(world_to_map(pos))


## Region (rx, rz) of a map position, clamped to the map.
static func region_of_map(map_pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(floori(map_pos.x / REGION_M), 0, REGIONS_PER_SIDE - 1),
		clampi(floori(map_pos.z / REGION_M), 0, REGIONS_PER_SIDE - 1)
	)


static func region_index(region: Vector2i) -> int:
	return region.y * REGIONS_PER_SIDE + region.x


## Tree chunk (cx, cz) of an engine position.
func tree_chunk_of(pos: Vector3) -> Vector2i:
	return tree_chunk_of_map(world_to_map(pos))


static func tree_chunk_of_map(map_pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(floori(map_pos.x / TREE_CHUNK_M), 0, TREE_CHUNKS_PER_SIDE - 1),
		clampi(floori(map_pos.z / TREE_CHUNK_M), 0, TREE_CHUNKS_PER_SIDE - 1)
	)


static func tree_chunk_index(chunk: Vector2i) -> int:
	return chunk.y * TREE_CHUNKS_PER_SIDE + chunk.x
