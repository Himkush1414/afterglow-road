class_name GrassField
extends Node3D
## Ground cover (06 §B): small plants generated at run time in square cells
## of the map, never saved. This part builds one cell's instance arrays,
## deterministically from the cell coordinates (T-06-8).
##
## A cell is split into 4 m sub-cells (the mask cell). Per sub-cell the
## terrain's layer weights are worked out at its centre with the terrain
## shader's rules (05 §5: biome cells bilinear, slope layers, mask R way and
## G wet pulls); the expected plant count is the sum over layers of
## weight x density x area x the preset's density multiplier. Each plant
## picks its layer by weight x density, its type by the layer's shares and a
## variant at random. Nothing grows where the mask's way value reaches
## `road_mask_below`, where the water is deeper than `water_depth_max_m`,
## or inside a hole circle (T-06-9). The random numbers are drawn before
## any of those checks, so a hole only removes plants and never moves the
## others. All numbers come from the "grass" tuning.

## Sub-cell side in metres (one mask texel, 04 §2).
const SUB_M := 4.0
## 16 floats per instance: a 3 x 4 transform, then custom data
## (fade key 0..1, wind phase 0..1, 0, 0).
const STRIDE := 16
## Hole circles at most (06 §B2).
const MAX_HOLES := 64
## Sub-cell patterns in the bank (see _cap).
const PATTERNS := 64

var errors: PackedStringArray = []
## Cell side in metres.
var cell_m := 32.0
## [type name, variant] per draw index; build_cell returns one array each.
var draws: Array = []
## Hole circles (engine x, engine z, radius): no plant stands inside one.
var holes := PackedVector3Array()
## Mask bytes (RGBA8 per 4 m cell, as WorldData.mask()) and their side in
## texels; empty: no way or wet rules.
var mask := PackedByteArray()
var mask_side := 0
## Water depth in metres at an engine position; unset: no water.
var depth_of: Callable

var _world: WorldData
var _cfg := {}
var _mult := 1.0
var _seed := 0
## Per terrain layer: density in plants per m² (0: none).
var _density := PackedFloat32Array()
## Per terrain layer: cumulative shares and the draw index of each type entry.
var _share_sum: Array[PackedFloat32Array] = []
var _share_type: Array[PackedInt32Array] = []
## Per type: first draw index, variants, scale range (packed for the build loop).
var _type_draw := PackedInt32Array()
var _type_variants := PackedInt32Array()
var _type_scale_lo := PackedFloat32Array()
var _type_scale_hi := PackedFloat32Array()
## The pattern bank: PATTERNS sub-cell patterns of _cap plants each, every
## plant's random numbers drawn once in configure (position in the
## sub-cell, layer and type picks 0..1, yaw as cos and sin, size 0..1, fade
## key, wind phase). A sub-cell takes the first n plants of one pattern.
var _cap := 0
var _p_x := PackedFloat32Array()
var _p_z := PackedFloat32Array()
var _p_pick := PackedFloat32Array()
var _p_share := PackedFloat32Array()
var _p_variant := PackedFloat32Array()
var _p_cos := PackedFloat32Array()
var _p_sin := PackedFloat32Array()
var _p_size := PackedFloat32Array()
var _p_fade := PackedFloat32Array()
var _p_phase := PackedFloat32Array()
var _biome_layer := PackedInt32Array()
var _slope_layer := PackedInt32Array()
var _slope_deg := PackedFloat32Array()
var _slope_half := 0.001
var _dirt_layer := -1
var _mud_layer := -1


## Reads the "grass" tuning `cfg` and the "terrain" tuning `terrain` (its
## layer list and rules). False and `errors` when a layer or type is unknown.
func configure(world: WorldData, cfg: Dictionary, terrain: Dictionary, density_mult: float) -> bool:
	errors.clear()
	_world = world
	_cfg = cfg
	_mult = density_mult
	cell_m = float(cfg.cell_m)
	if fmod(cell_m, SUB_M) != 0.0 or fmod(cell_m, world.sample_m) != 0.0:
		errors.append(
			"grass: cell_m %s is not a multiple of %s and %s" % [cell_m, SUB_M, world.sample_m]
		)
	_seed = int(cfg.get("seed", 0))
	mask = world.mask()
	mask_side = world.mask_side() if not mask.is_empty() else 0
	var layers: Array = terrain.get("layers", [])
	var index := {}
	for i in layers.size():
		index[layers[i]] = i
	draws.clear()
	_type_draw.clear()
	_type_variants.clear()
	_type_scale_lo.clear()
	_type_scale_hi.clear()
	var type_index := {}
	var types: Dictionary = cfg.types
	for name: String in types:
		var t: Dictionary = types[name]
		var scale: Array = t.get("scale", [1.0, 1.0])
		type_index[name] = _type_draw.size()
		_type_draw.append(draws.size())
		_type_variants.append(int(t.variants))
		_type_scale_lo.append(float(scale[0]))
		_type_scale_hi.append(float(scale[1]))
		for v in int(t.variants):
			draws.append([name, v])
	_density = PackedFloat32Array()
	_density.resize(layers.size())
	_share_sum.clear()
	_share_type.clear()
	for i in layers.size():
		_share_sum.append(PackedFloat32Array())
		_share_type.append(PackedInt32Array())
	var by_layer: Dictionary = cfg.layers
	for layer: String in by_layer:
		if not index.has(layer):
			errors.append("grass: unknown terrain layer '%s'" % layer)
			continue
		var li: int = index[layer]
		var row: Dictionary = by_layer[layer]
		_density[li] = float(row.density)
		var sum := 0.0
		var shares: Dictionary = row.types
		for name: String in shares:
			if not type_index.has(name):
				errors.append("grass: layer '%s' names unknown type '%s'" % [layer, name])
				continue
			sum += float(shares[name])
			_share_sum[li].append(sum)
			_share_type[li].append(type_index[name])
		if sum <= 0.0:
			_density[li] = 0.0
	_biome_layer = PackedInt32Array()
	var biome_layer: Dictionary = terrain.get("biome_layer", {})
	for key: String in biome_layer:
		var id := int(key)
		if id >= _biome_layer.size():
			var old := _biome_layer.size()
			_biome_layer.resize(id + 1)
			for k in range(old, id + 1):
				_biome_layer[k] = -1
		_biome_layer[id] = index.get(biome_layer[key], -1)
	_slope_layer = PackedInt32Array()
	_slope_deg = PackedFloat32Array()
	for s: Dictionary in terrain.get("slope_layers", []):
		_slope_layer.append(index.get(s.layer, -1))
		_slope_deg.append(float(s.deg))
	_slope_half = maxf(float(terrain.get("slope_blend_deg", 0.0)) * 0.5, 0.001)
	_dirt_layer = index.get(terrain.get("dirt_layer", ""), -1)
	_mud_layer = index.get(terrain.get("mud_layer", ""), -1)
	var top := 0.0
	for d in _density:
		top = maxf(top, d)
	_fill_patterns(maxi(1, ceili(top * SUB_M * SUB_M * _mult)))
	return errors.is_empty()


func _fill_patterns(cap: int) -> void:
	_cap = cap
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed * 2654435761 + 1
	var arrays: Array[PackedFloat32Array] = []
	for a in 10:
		var v := PackedFloat32Array()
		v.resize(PATTERNS * cap)
		arrays.append(v)
	for k in PATTERNS * cap:
		var yaw := rng.randf() * TAU
		var row := [
			rng.randf() * SUB_M,
			rng.randf() * SUB_M,
			rng.randf(),
			rng.randf(),
			rng.randf(),
			cos(yaw),
			sin(yaw),
			rng.randf(),
			rng.randf(),
			rng.randf(),
		]
		for a in 10:
			arrays[a][k] = row[a]
	_p_x = arrays[0]
	_p_z = arrays[1]
	_p_pick = arrays[2]
	_p_share = arrays[3]
	_p_variant = arrays[4]
	_p_cos = arrays[5]
	_p_sin = arrays[6]
	_p_size = arrays[7]
	_p_fade = arrays[8]
	_p_phase = arrays[9]


## Map cell (cx, cz) holding an engine position.
func cell_of(pos: Vector3) -> Vector2i:
	var m := _world.world_to_map(pos)
	return Vector2i(floori(m.x / cell_m), floori(m.z / cell_m))


## Engine position of a cell's map corner (its lowest x and z) at y = 0;
## build_cell's transforms are relative to it in x and z, absolute in y.
func cell_origin(cell: Vector2i) -> Vector3:
	return _world.map_to_world(Vector3(cell.x * cell_m, 0.0, cell.y * cell_m))


## The cell's instances, one PackedFloat32Array of STRIDE floats per
## instance for each entry of `draws` (any thread: reads only).
func build_cell(cell: Vector2i) -> Array[PackedFloat32Array]:
	var rng := RandomNumberGenerator.new()
	rng.seed = _cell_seed(cell)
	var origin := cell_origin(cell)
	var cell_holes := _holes_near(origin)
	var max_depth := float(_cfg.water_depth_max_m)
	var road := float(_cfg.road_mask_below)
	var area := SUB_M * SUB_M
	var subs := roundi(cell_m / SUB_M)
	var hs := _height_grid(origin)
	var side := ceili(cell_m / _world.sample_m) + 2
	var inv_step := 1.0 / _world.sample_m
	var w := PackedFloat32Array()
	w.resize(_density.size())
	# Every plant goes to one flat buffer first; split by draw at the end.
	var flat := PackedFloat32Array()
	var ids := PackedInt32Array()
	var count := 0
	for sj in subs:
		for si in subs:
			var x0 := si * SUB_M
			var z0 := sj * SUB_M
			var mw := _weights(origin + Vector3(x0 + SUB_M * 0.5, 0.0, z0 + SUB_M * 0.5), w)
			if mw.x >= road:
				continue  # a way: world data, so skipping its numbers moves nothing else
			var expect := 0.0
			for li in w.size():
				w[li] *= _density[li]
				expect += w[li]
			var weight_sum := expect
			expect *= area * _mult
			var n := floori(expect)
			if rng.randf() < expect - n:
				n += 1
			if n == 0:
				continue
			var water := _water_near(origin + Vector3(x0, 0.0, z0), mw.y)
			if flat.size() < (count + n) * STRIDE:
				flat.resize(maxi(flat.size() * 2, (count + n) * STRIDE))
				ids.resize(flat.size() / STRIDE)
			var base := (rng.randi() % PATTERNS) * _cap
			for k in mini(n, _cap):
				var q := base + k
				var lx := x0 + _p_x[q]
				var lz := z0 + _p_z[q]
				var pick := _p_pick[q] * weight_sum
				var share := _p_share[q]
				var vpick := _p_variant[q]
				var size := _p_size[q]
				var li := 0
				while li < w.size() - 1 and pick >= w[li]:
					pick -= w[li]
					li += 1
				var sums := _share_sum[li]
				if sums.is_empty():
					continue
				share *= sums[sums.size() - 1]
				var e := 0
				while e < sums.size() - 1 and share >= sums[e]:
					e += 1
				var ti := _share_type[li][e]
				var variants := _type_variants[ti]
				var draw := _type_draw[ti] + mini(int(vpick * variants), variants - 1)
				if not cell_holes.is_empty() and _in_hole(cell_holes, origin.x + lx, origin.z + lz):
					continue
				if water:
					var depth := float(depth_of.call(Vector3(origin.x + lx, 0.0, origin.z + lz)))
					if depth > max_depth:
						continue
				# Height on the heightmap's triangles, as WorldData.height_at.
				var fx := lx * inv_step
				var fz := lz * inv_step
				var i := int(fx)
				var j := int(fz)
				var tx := fx - i
				var tz := fz - j
				var o := j * side + i
				var y: float
				if tx + tz <= 1.0:
					y = hs[o] + (hs[o + 1] - hs[o]) * tx + (hs[o + side] - hs[o]) * tz
				else:
					var h11 := hs[o + side + 1]
					y = h11 + (hs[o + side] - h11) * (1.0 - tx) + (hs[o + 1] - h11) * (1.0 - tz)
				var sc := _type_scale_lo[ti] + (_type_scale_hi[ti] - _type_scale_lo[ti]) * size
				var c := _p_cos[q] * sc
				var sn := _p_sin[q] * sc
				var f := count * STRIDE
				flat[f] = c
				flat[f + 1] = 0.0
				flat[f + 2] = sn
				flat[f + 3] = lx
				flat[f + 4] = 0.0
				flat[f + 5] = sc
				flat[f + 6] = 0.0
				flat[f + 7] = y
				flat[f + 8] = -sn
				flat[f + 9] = 0.0
				flat[f + 10] = c
				flat[f + 11] = lz
				flat[f + 12] = _p_fade[q]
				flat[f + 13] = _p_phase[q]
				flat[f + 14] = 0.0
				flat[f + 15] = 0.0
				ids[count] = draw
				count += 1
	var out: Array[PackedFloat32Array] = []
	for d in draws.size():
		out.append(PackedFloat32Array())
	for k in count:
		out[ids[k]].append_array(flat.slice(k * STRIDE, (k + 1) * STRIDE))
	return out


## Heights of the samples around a cell whose engine corner is `origin`:
## rows of ceil(cell_m / sample_m) + 2 values from the sample at or before
## the corner (the cell corner lies on a sample when cell_m is a multiple of
## sample_m).
func _height_grid(origin: Vector3) -> PackedFloat32Array:
	var m := _world.world_to_map(origin)
	var i0 := floori(m.x / _world.sample_m)
	var j0 := floori(m.z / _world.sample_m)
	var side := ceili(cell_m / _world.sample_m) + 2
	var hs := PackedFloat32Array()
	hs.resize(side * side)
	for j in side:
		for i in side:
			hs[j * side + i] = _world.sample(i0 + i, j0 + j)
	return hs


func _cell_seed(cell: Vector2i) -> int:
	# A fixed integer mix of the cell coordinates (not hash(), which may change
	# between engine versions).
	var h := (cell.x * 73856093) ^ (cell.y * 19349663) ^ (_seed * 83492791)
	h = (h ^ (h >> 13)) * 0x5bd1e995
	return h ^ (h >> 15)


## Fills `w` with the terrain layer weights at engine `pos` and returns the
## mask's way and wet values there (0..1 each).
func _weights(pos: Vector3, w: PackedFloat32Array) -> Vector2:
	w.fill(0.0)
	var m := _world.world_to_map(pos)
	var c := Vector2(m.x, m.z) / WorldData.BIOME_CELL_M - Vector2(0.5, 0.5)
	var c0 := Vector2i(floori(c.x), floori(c.y))
	var f := c - Vector2(c0)
	var last := _world.biome_cells - 1
	for k in 4:
		var ox := k & 1
		var oz := k >> 1
		var bx := clampi(c0.x + ox, 0, last)
		var bz := clampi(c0.y + oz, 0, last)
		var id := _world.biome_at(
			(bx + 0.5) * WorldData.BIOME_CELL_M - _world.origin_offset_m,
			(bz + 0.5) * WorldData.BIOME_CELL_M - _world.origin_offset_m
		)
		var layer := _biome_layer[id] if id < _biome_layer.size() else -1
		if layer >= 0:
			w[layer] += (f.x if ox == 1 else 1.0 - f.x) * (f.y if oz == 1 else 1.0 - f.y)
	var slope := _slope_deg_at(pos)
	for s in _slope_layer.size():
		_pull(
			w,
			_slope_layer[s],
			smoothstep(_slope_deg[s] - _slope_half, _slope_deg[s] + _slope_half, slope)
		)
	if mask.is_empty():
		return Vector2.ZERO
	var i := clampi(floori(m.x / WorldData.MASK_CELL_M), 0, mask_side - 1)
	var j := clampi(floori(m.z / WorldData.MASK_CELL_M), 0, mask_side - 1)
	var o := (j * mask_side + i) * 4
	var mw := Vector2(mask[o] / 255.0, mask[o + 1] / 255.0)
	_pull(w, _dirt_layer, mw.x)
	_pull(w, _mud_layer, mw.y)
	return mw


## Moves `amount` of every weight onto `layer` (the terrain shader's pull).
static func _pull(w: PackedFloat32Array, layer: int, amount: float) -> void:
	if layer < 0 or amount <= 0.0:
		return
	for i in w.size():
		w[i] *= 1.0 - amount
	w[layer] += amount


## Ground slope in degrees at engine `pos`, from the heights one sample away.
func _slope_deg_at(pos: Vector3) -> float:
	var d := _world.sample_m
	var dx := _world.height_at(pos.x + d, pos.z) - _world.height_at(pos.x - d, pos.z)
	var dz := _world.height_at(pos.x, pos.z + d) - _world.height_at(pos.x, pos.z - d)
	var n := Vector3(-dx, 2.0 * d, -dz).normalized()
	return rad_to_deg(acos(clampf(n.y, -1.0, 1.0)))


## Whether the plants of the sub-cell at engine corner `at` need a depth
## check: the mask marks it wet (near a river, lake or marsh), or water
## stands on one of nine points 2 m apart.
func _water_near(at: Vector3, wet: float) -> bool:
	if not depth_of.is_valid():
		return false
	if wet > 0.0:
		return true
	for k in 9:
		var p := Vector3(k % 3, 0.0, floori(k / 3.0)) * (SUB_M * 0.5)
		if float(depth_of.call(at + p)) > 0.0:
			return true
	return false


## The holes reaching into the cell whose engine corner is `origin`.
func _holes_near(origin: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in mini(holes.size(), MAX_HOLES):
		var h := holes[i]
		var cx := clampf(h.x, origin.x, origin.x + cell_m)
		var cz := clampf(h.y, origin.z, origin.z + cell_m)
		if Vector2(h.x - cx, h.y - cz).length_squared() <= h.z * h.z:
			out.append(h)
	return out


static func _in_hole(near: PackedVector3Array, x: float, z: float) -> bool:
	for h in near:
		if Vector2(x - h.x, z - h.y).length_squared() <= h.z * h.z:
			return true
	return false
