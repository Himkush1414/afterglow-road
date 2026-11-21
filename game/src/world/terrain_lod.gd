class_name TerrainLod
extends RefCounted
## CDLOD node selection for the terrain (05 §5, Strugar's method). Fills an
## instance buffer for one MultiMesh: identity transform, then custom data
## (corner x, corner z, size, level + 0.5 when drawn as a quadrant), in
## engine coordinates. The quadtree and its node boxes come from minmax.bin.
##
## Distance (selection and morph alike) is sqrt(horizontal^2 + lift^2), with
## lift = the eye's height above its own ground at selection time. Unlike the
## full 3-D distance it cannot be broken by steep node boxes, so the crack-free
## rule depends on node widths only; the shader takes the same eye and lift.

## Edge of a level-0 node; level L covers LEAF_M * 2^L metres.
const LEAF_M := 64.0
## Quads per patch side (desktop); phones fold the grid to half.
const PATCH_QUADS := 32
## Range of level 0 and morph start (fraction of the range). Crack-free only
## while (2 * MORPH_START - 1) * R0_M >= sqrt(2) * LEAF_M.
const R0_M := 160.0
const MORPH_START := 0.8
const MAX_INSTANCES := 512
const FLOATS_PER_INSTANCE := 16

var errors: PackedStringArray = []
## Number of levels (L = 0 .. levels - 1); the roots are 2 x 2 nodes.
var levels := 0
var r0 := R0_M
var morph_start := MORPH_START
## Range of each level: r0 * 2^L.
var ranges := PackedFloat64Array()
var buffer := PackedFloat32Array()
var count := 0
## True when the last selection wanted more than MAX_INSTANCES patches.
var overflow := false
## Eye (engine coordinates) and lift of the last selection, for the shader.
var eye := Vector3.ZERO
var lift := 0.0

var _offset := 0.0
var _mins: Array[PackedFloat32Array] = []
var _maxs: Array[PackedFloat32Array] = []
var _per_side := PackedInt32Array()
var _frustum: Array[Plane] = []
var _world: WorldData


## Reads the node boxes of `world` (loaded). Returns false and fills
## `errors` when the file is missing or the map size does not fit the tree.
func setup(world: WorldData) -> bool:
	errors.clear()
	var roots := world.size_m / (2.0 * LEAF_M)
	levels = int(round(log(roots) / log(2.0))) + 1
	if roots < 1.0 or not is_equal_approx(LEAF_M * pow(2.0, levels - 1) * 2.0, world.size_m):
		errors.append("terrain: map size %.0f m is not 2 x 2 roots of 64 m * 2^L" % world.size_m)
		return false
	_world = world
	_offset = world.origin_offset_m
	_per_side.clear()
	var nodes := 0
	for level in levels:
		var k := int(world.size_m / (LEAF_M * pow(2.0, level)))
		_per_side.append(k)
		nodes += k * k
	var raw := world.read_layer("minmax.bin", nodes * 4)
	if raw.is_empty():
		errors.append_array(world.errors)
		return false
	var at := 0
	_mins.clear()
	_maxs.clear()
	for level in levels:
		var n := _per_side[level] * _per_side[level]
		var lo := PackedFloat32Array()
		var hi := PackedFloat32Array()
		lo.resize(n)
		hi.resize(n)
		for i in n:
			lo[i] = _decode(world, raw, at)
			hi[i] = _decode(world, raw, at + 2)
			at += 4
		_mins.append(lo)
		_maxs.append(hi)
	set_ranges(r0, morph_start)
	buffer.resize(MAX_INSTANCES * FLOATS_PER_INSTANCE)
	buffer.fill(0.0)
	for i in MAX_INSTANCES:
		var o := i * FLOATS_PER_INSTANCE
		buffer[o] = 1.0
		buffer[o + 5] = 1.0
		buffer[o + 10] = 1.0
	return true


## Changes the level-0 range and morph start (tests use other values).
func set_ranges(range0: float, morph: float) -> void:
	r0 = range0
	morph_start = morph
	ranges.resize(levels)
	for level in levels:
		ranges[level] = r0 * pow(2.0, level)


## Selects the patches for a camera at `eye` (engine coordinates). An empty
## `frustum` disables culling. Returns the number of instances written.
func select(at: Vector3, frustum: Array[Plane]) -> int:
	eye = at
	lift = maxf(at.y - _world.height_at(at.x, at.z), 0.0)
	_frustum = frustum
	count = 0
	overflow = false
	var top := levels - 1
	for iz in _per_side[top]:
		for ix in _per_side[top]:
			_visit(top, ix, iz)
	return count


## Node box in engine coordinates, including the node's far-edge samples.
func node_box(level: int, ix: int, iz: int) -> AABB:
	var size := LEAF_M * pow(2.0, level)
	var i := iz * _per_side[level] + ix
	var lo := _mins[level][i]
	var hi := _maxs[level][i]
	return AABB(Vector3(ix * size - _offset, lo, iz * size - _offset), Vector3(size, hi - lo, size))


func _visit(level: int, ix: int, iz: int) -> void:
	# A node that reaches into the next finer range is split; children that
	# do not reach into it are drawn by this node, at this level, as quadrants.
	var box := node_box(level, ix, iz)
	if not _in_frustum(box):
		return
	if level == 0 or _nearest(box) > ranges[level - 1]:
		_emit(box, level, false)
		return
	for dz in 2:
		for dx in 2:
			var cx := ix * 2 + dx
			var cz := iz * 2 + dz
			var child := node_box(level - 1, cx, cz)
			if _nearest(child) > ranges[level - 1]:
				if _in_frustum(child):
					_emit(child, level, true)
			else:
				_visit(level - 1, cx, cz)


func _nearest(box: AABB) -> float:
	var dx := eye.x - clampf(eye.x, box.position.x, box.end.x)
	var dz := eye.z - clampf(eye.z, box.position.z, box.end.z)
	return sqrt(dx * dx + dz * dz + lift * lift)


func _in_frustum(box: AABB) -> bool:
	for p in _frustum:
		var v := Vector3(
			box.position.x + (box.size.x if p.normal.x < 0.0 else 0.0),
			box.position.y + (box.size.y if p.normal.y < 0.0 else 0.0),
			box.position.z + (box.size.z if p.normal.z < 0.0 else 0.0)
		)
		if p.distance_to(v) > 0.0:
			return false
	return true


func _emit(box: AABB, level: int, quadrant: bool) -> void:
	if count >= MAX_INSTANCES:
		overflow = true
		return
	var o := count * FLOATS_PER_INSTANCE + 12
	buffer[o] = box.position.x
	buffer[o + 1] = box.position.z
	buffer[o + 2] = box.size.x
	buffer[o + 3] = float(level) + (0.5 if quadrant else 0.0)
	count += 1


static func _decode(world: WorldData, raw: PackedByteArray, at: int) -> float:
	return world.height_of_code(raw.decode_u16(at))
