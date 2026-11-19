class_name Ids
extends RefCounted
## Integer identifiers (03 §6). Packed ids are pure functions of their
## parts; dynamic ids come from a counter that the save stores.

const FIRST_DYNAMIC := 1 << 40
const REGIONS_PER_SIDE := 16
const CHUNKS_PER_SIDE := 64
const TREE_INDEX_BITS := 12
const OBJECT_INDEX_BITS := 20

static var _next := FIRST_DYNAMIC


## Region index of region (rx, rz), each 0–15.
static func region_index(region: Vector2i) -> int:
	assert(_in_grid(region, REGIONS_PER_SIDE), "region out of range")
	return region.y * REGIONS_PER_SIDE + region.x


## Tree id from its 128 m chunk (cx, cz each 0–63) and index in the chunk.
static func tree_id(chunk: Vector2i, index: int) -> int:
	assert(_in_grid(chunk, CHUNKS_PER_SIDE), "chunk out of range")
	assert(index >= 0 and index < 1 << TREE_INDEX_BITS, "tree index out of range")
	return ((chunk.y * CHUNKS_PER_SIDE + chunk.x) << TREE_INDEX_BITS) | index


## Id of a generator-placed object from its region and index in the region.
static func static_object_id(region: Vector2i, index: int) -> int:
	assert(index >= 0 and index < 1 << OBJECT_INDEX_BITS, "object index out of range")
	return (region_index(region) << OBJECT_INDEX_BITS) | index


## A new dynamic entity id (dropped item, structure, piece, fire, player).
static func next() -> int:
	_next += 1
	return _next - 1


## The counter value to save.
static func counter() -> int:
	return _next


## Restores the counter from a save; values below FIRST_DYNAMIC are refused.
static func set_counter(value: int) -> bool:
	if value < FIRST_DYNAMIC:
		return false
	_next = value
	return true


static func _in_grid(cell: Vector2i, side: int) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < side and cell.y < side
