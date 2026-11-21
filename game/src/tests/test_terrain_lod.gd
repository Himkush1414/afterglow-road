extends TestCase
## TerrainLod: tiling of the map and the exact crack check of T-05-3 (a):
## a CPU emulation of the selection and of the terrain vertex shader finds
## no shared patch edge whose two sides disagree.

const CAMERAS := 200
## Eye height above the ground, drawn per camera.
const EYE_HEIGHTS: Array[float] = [1.7, 1.7, 20.0, 150.0, 600.0]
## Both sides of a shared vertex must agree to float32 rounding of heights
## (a 0.7 mm disagreement already showed as a one-pixel hole).
const TOLERANCE_M := 1e-5

var _world: WorldData
var _lod: TerrainLod
var _base_quads := TerrainLod.PATCH_QUADS


func before_each() -> void:
	_world = WorldData.new()
	_lod = TerrainLod.new()


func after_each() -> void:
	_world.free()


func _worlds() -> Array[String]:
	return [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]


func _load(dir: String) -> bool:
	if not check(_world.load_dir(dir), "load %s: %s" % [dir, ", ".join(_world.errors)]):
		return false
	return check(_lod.setup(_world), "setup %s: %s" % [dir, ", ".join(_lod.errors)])


# gdlint:ignore = function-name
func test_T_05_3() -> void:
	for dir in _worlds():
		if not _load(dir):
			continue
		for quads: int in [TerrainLod.PATCH_QUADS, TerrainLod.PATCH_QUADS / 2]:
			_base_quads = quads
			var r := _crack_check(CAMERAS)
			check_eq(r.x, 0, "%s, %d quads: %d of %d shared edges differ" % [dir, quads, r.x, r.y])
			check(r.y > 0, "%s: some shared edges were compared" % dir)


func test_the_crack_check_finds_cracks_with_short_ranges() -> void:
	# The ranges the spike rejected: the check must see their cracks.
	if not _load(WorldData.default_dir()):
		return
	_lod.set_ranges(110.0, 0.7)
	var r := _crack_check(40)
	check(r.x > 0, "no crack found with r0 110 m, morph 0.7 (%d edges)" % r.y)


func test_selection_tiles_the_map_once() -> void:
	for dir in _worlds():
		if not _load(dir):
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = 2
		var cells := int(_world.size_m / TerrainLod.LEAF_M)
		for c in 5:
			var n := _lod.select(_random_eye(rng), [])
			var cover := PackedInt32Array()
			cover.resize(cells * cells)
			for a in n:
				var p := _patch(a)
				var i0 := int((p[0] + _world.origin_offset_m) / TerrainLod.LEAF_M)
				var j0 := int((p[1] + _world.origin_offset_m) / TerrainLod.LEAF_M)
				var k := int(p[2] / TerrainLod.LEAF_M)
				for j in range(j0, j0 + k):
					for i in range(i0, i0 + k):
						cover[j * cells + i] += 1
			var wrong := 0
			for v in cover:
				wrong += 1 if v != 1 else 0
			check_eq(wrong, 0, "%s: leaf cells not covered exactly once" % dir)
			check(not _lod.overflow, "instance limit reached")


func test_a_frustum_drops_patches_behind_the_camera() -> void:
	if not _load(WorldData.default_dir()):
		return
	var eye := Vector3(0.0, _world.height_at(0.0, 0.0) + 20.0, 0.0)
	# one plane, normal pointing out of the volume: everything at x < eye.x is outside
	var behind: Array[Plane] = [Plane(Vector3(-1.0, 0.0, 0.0), -eye.x)]
	var all := _lod.select(eye, [])
	var seen := _lod.select(eye, behind)
	check(seen > 0 and seen < all, "culled %d of %d" % [all - seen, all])
	for a in seen:
		var p := _patch(a)
		check(p[0] + p[2] >= eye.x, "a patch wholly behind the plane was kept")


## Returns (mismatched, compared) shared edges over `cameras` random cameras.
func _crack_check(cameras: int) -> Vector2i:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var bad := 0
	var edges := 0
	for c in cameras:
		var eye := _random_eye(rng)
		var n := _lod.select(eye, [])
		# sides keyed by their line: x = const (east/west) or z = const (south/north)
		var lines := {}
		for a in n:
			var p := _patch(a)
			var ox := int(round((p[0] + _world.origin_offset_m) / _world.sample_m))
			var oz := int(round((p[1] + _world.origin_offset_m) / _world.sample_m))
			var s := int(round(p[2] / _world.sample_m))
			_add_side(lines, Vector3i(0, ox, 0), [a, "W", oz, oz + s])
			_add_side(lines, Vector3i(0, ox + s, 1), [a, "E", oz, oz + s])
			_add_side(lines, Vector3i(1, oz, 0), [a, "N", ox, ox + s])
			_add_side(lines, Vector3i(1, oz + s, 1), [a, "S", ox, ox + s])
		for key: Vector3i in lines:
			if key.z != 1:
				continue
			var other := Vector3i(key.x, key.y, 0)
			if not lines.has(other):
				continue
			for sa: Array in lines[key]:
				for sb: Array in lines[other]:
					if maxi(sa[2], sb[2]) >= mini(sa[3], sb[3]):
						continue
					edges += 1
					var pa := _side_points(sa[0], sa[1], eye)
					var pb := _side_points(sb[0], sb[1], eye)
					var axis := 1 if key.x == 0 else 0
					if not (_on_curve(pa, pb, axis) and _on_curve(pb, pa, axis)):
						bad += 1
	return Vector2i(bad, edges)


func _add_side(lines: Dictionary, key: Vector3i, side: Array) -> void:
	if not lines.has(key):
		lines[key] = []
	lines[key].append(side)


func _random_eye(rng: RandomNumberGenerator) -> Vector3:
	var x := rng.randf_range(0.05, 0.95) * _world.size_m - _world.origin_offset_m
	var z := rng.randf_range(0.05, 0.95) * _world.size_m - _world.origin_offset_m
	var up: float = EYE_HEIGHTS[rng.randi_range(0, EYE_HEIGHTS.size() - 1)]
	return Vector3(x, _world.height_at(x, z) + up, z)


## Custom data of instance `a`: corner x, corner z, size, level code.
func _patch(a: int) -> PackedFloat32Array:
	var o := a * TerrainLod.FLOATS_PER_INSTANCE + 12
	return _lod.buffer.slice(o, o + 4)


## Vertices along one side of a patch after the vertex shader, as
## (x index, z index, height).
func _side_points(a: int, side: String, eye: Vector3) -> Array[Vector3]:
	var p := _patch(a)
	var quads := _base_quads / 2 if fmod(p[3], 1.0) > 0.25 else _base_quads
	var out: Array[Vector3] = []
	for i in quads + 1:
		var g := Vector2(0, i)
		match side:
			"E":
				g = Vector2(quads, i)
			"N":
				g = Vector2(i, 0)
			"S":
				g = Vector2(i, quads)
		out.append(_vertex(p, quads, g, eye))
	return out


## The terrain vertex shader on the CPU (05 §5): whole-sample positions,
## morph towards the coarser grid, height by bilinear filtering of the
## height texture (which drops the last row and column).
func _vertex(p: PackedFloat32Array, quads: int, g: Vector2, eye: Vector3) -> Vector3:
	var s := _world.sample_m
	var origin := Vector2(
		round((p[0] + _world.origin_offset_m) / s), round((p[1] + _world.origin_offset_m) / s)
	)
	var step := p[2] / (quads * s)
	var rng_m: float = _lod.ranges[int(p[3])]
	var grid := origin / step + g
	var idx := grid * step
	var map_eye := _world.world_to_map(eye)
	var d := Vector3(idx.x * s - map_eye.x, _lod.lift, idx.y * s - map_eye.z).length()
	var k := clampf((d - _lod.morph_start * rng_m) / ((1.0 - _lod.morph_start) * rng_m), 0.0, 1.0)
	grid.x -= fposmod(grid.x * 0.5, 1.0) * 2.0 * k
	grid.y -= fposmod(grid.y * 0.5, 1.0) * 2.0 * k
	idx = grid * step
	return Vector3(idx.x, idx.y, _height(idx))


func _height(idx: Vector2) -> float:
	var last := _world.samples - 2
	var i := clampi(floori(idx.x), 0, last)
	var j := clampi(floori(idx.y), 0, last)
	var fx := idx.x - i
	var fz := idx.y - j
	var a := lerpf(_world.sample(i, j), _world.sample(mini(i + 1, last), j), fx)
	var b := lerpf(
		_world.sample(i, mini(j + 1, last)), _world.sample(mini(i + 1, last), mini(j + 1, last)), fx
	)
	return lerpf(a, b, fz)


## True when every point of `pts` lies on the polyline `curve` (both sorted
## along `axis`); points outside the curve's span are checked from the other
## neighbour.
func _on_curve(pts: Array[Vector3], curve: Array[Vector3], axis: int) -> bool:
	for q in pts:
		var t := q[axis]
		var lo := 0
		var hi := curve.size() - 1
		if t < curve[lo][axis] - 1e-6 or t > curve[hi][axis] + 1e-6:
			continue
		while hi - lo > 1:
			var mid := (lo + hi) / 2
			if curve[mid][axis] <= t:
				lo = mid
			else:
				hi = mid
		var a := curve[lo]
		var b := curve[hi]
		var span := b[axis] - a[axis]
		var y := a.z if span < 1e-9 else lerpf(a.z, b.z, clampf((t - a[axis]) / span, 0.0, 1.0))
		if absf(q.z - y) > TOLERANCE_M:
			if span < 1e-9 and absf(q.z - b.z) <= TOLERANCE_M:
				continue
			return false
	return true
