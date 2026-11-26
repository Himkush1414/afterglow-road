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
##
## Streaming (06 §B2, §B5): every cell reaching within `radius_m` of the eye
## is built on a worker thread (EMPTY -> BUILDING), at most MAX_BUILDS at a
## time, nearest first; a finished cell is assembled one MultiMesh per draw
## per update and shown when complete (VISIBLE); cells beyond radius_m + KEEP_EXTRA_M are
## freed (FREED). A change of the holes rebuilds the cells it touches and
## swaps them in when done, so they never go bare.

## Sub-cell side in metres (one mask texel, 04 §2).
const SUB_M := 4.0
## 16 floats per instance: a 3 x 4 transform, then custom data
## (fade key 0..1, wind phase 0..1, 0, 0).
const STRIDE := 16
## Hole circles at most (06 §B2).
const MAX_HOLES := 64
## Sub-cell patterns in the bank (see _cap).
const PATTERNS := 64
const MAX_BUILDS := 2
const KEEP_EXTRA_M := 8.0
## The wanted cells are worked out again when the eye moved this far.
const RESELECT_M := 4.0
## Fade-key buckets: a cell's draws hold their plants ordered by bucket
## (key × FADE_BUCKETS), so a prefix holds every plant the fade can show.
const FADE_BUCKETS := 16
## The cells' drawn prefixes are worked out again when the eye moved this
## far; each cut is widened by the same distance.
const CUT_STEP_M := 1.0
const MODEL_DIR := "assets/models/ground_cover"
const TEXTURE_DIR := "assets/textures/ground_cover"
const CATEGORY := "ground_cover"
const SHADER := "res://shaders/grass.gdshader"
## Shader parameters taken from the "shader" object of the "grass" tuning.
const SHADER_KEYS := [
	"lean_base", "lean_per_ms", "flutter_m", "flutter_hz", "fade_band", "bend_push", "alpha_cut"
]

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
## Streaming radius in metres (quality preset).
var radius_m := 48.0
## Plants in the added cells.
var instances := 0
## Longest main-thread time of one update() in microseconds (T-06-10).
var worst_update_usec := 0
## Longest drawn-prefix cut of all cells in one update() in microseconds
## (part of worst_update_usec).
var worst_cut_usec := 0
## Longest worker build of one cell in microseconds (T-06-10).
var worst_build_usec := 0

var _world: WorldData
var _cfg := {}
var _mult := 1.0
## The shader's fade band (share of radius_m); -1: not in the tuning.
var _fade_band := -1.0
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
var _meshes: Array[Mesh] = []
## Added cells: cell -> [holder Node3D, plant count, Array of
## [MultiMesh, bucket ends], fade bucket of the last cut (-1: none yet)].
var _cells := {}
## Cells being built: cell -> worker task id.
var _pending := {}
## Finished builds, written by the workers: cell -> [Array[PackedFloat32Array],
## bucket ends per draw (build_cell's ends_out)].
var _done := {}
var _mutex := Mutex.new()
var _wanted: Array[Vector2i] = []
## Added cells waiting for a rebuild after a hole change.
var _stale := {}
## The cell being assembled: [cell, holder, arrays, next draw, plants,
## bucket ends per draw, [MultiMesh, bucket ends] added so far], or [].
var _assembly: Array = []
var _last_eye := Vector3(INF, INF, INF)
## Eye (map) at the last cut of the cells' drawn prefixes.
var _cut_eye := Vector3(INF, INF, INF)
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
	var params: Dictionary = cfg.get("shader", {})
	_fade_band = maxf(float(params.fade_band), 0.0) if params.has("fade_band") else -1.0
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
## instance for each entry of `draws` (any thread: reads only). Each draw's
## plants are ordered by fade-key bucket; `ends_out`, when given, receives
## per draw the plant count of buckets 0..b for every bucket b.
func build_cell(cell: Vector2i, ends_out: Array = []) -> Array[PackedFloat32Array]:
	return _build_cell(cell, holes, ends_out)


func _build_cell(
	cell: Vector2i, hole_list: PackedVector3Array, ends_out: Array = []
) -> Array[PackedFloat32Array]:
	var rng := RandomNumberGenerator.new()
	rng.seed = _cell_seed(cell)
	var origin := cell_origin(cell)
	var cell_holes := _holes_near(origin, hole_list)
	var max_depth := float(_cfg.water_depth_max_m)
	var road := float(_cfg.road_mask_below)
	var area := SUB_M * SUB_M
	var subs := roundi(cell_m / SUB_M)
	var hs := _height_grid(origin)
	var side := ceili(cell_m / _world.sample_m) + 2
	var inv_step := 1.0 / _world.sample_m
	var w := PackedFloat32Array()
	w.resize(_density.size())
	# Every plant goes to the list of its draw and fade-key bucket; each
	# draw's lists are joined in bucket order at the end.
	var parts: Array[PackedFloat32Array] = []
	parts.resize(draws.size() * FADE_BUCKETS)
	var sizes := PackedInt32Array()
	sizes.resize(parts.size())
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
				var key := _p_fade[q]
				var slot := draw * FADE_BUCKETS + mini(int(key * FADE_BUCKETS), FADE_BUCKETS - 1)
				parts[slot].append_array(
					PackedFloat32Array(
						[
							c,
							0.0,
							sn,
							lx,
							0.0,
							sc,
							0.0,
							y,
							-sn,
							0.0,
							c,
							lz,
							key,
							_p_phase[q],
							0.0,
							0.0
						]
					)
				)
				sizes[slot] += 1
	ends_out.clear()
	var out: Array[PackedFloat32Array] = []
	for d in draws.size():
		var arr := PackedFloat32Array()
		var e := PackedInt32Array()
		e.resize(FADE_BUCKETS)
		var run := 0
		for b in FADE_BUCKETS:
			arr.append_array(parts[d * FADE_BUCKETS + b])
			run += sizes[d * FADE_BUCKETS + b]
			e[b] = run
		out.append(arr)
		ends_out.append(e)
	return out


## How many plants of a draw (bucket ends `ends`) a cell must draw when its
## nearest point is `near_m` from the eye: every plant whose fade key is
## below the shader's fade factor there (1 inside, falling to 0 over the
## last fade_band of radius_m); -1: all of them, also when the tuning sets
## no fade_band (the shader then uses its own default).
func fade_cut(ends: PackedInt32Array, near_m: float) -> int:
	var b := fade_bucket(near_m)
	return -1 if b >= FADE_BUCKETS or ends.is_empty() else ends[b]


## The last fade-key bucket the fade can show at `near_m` from the eye;
## FADE_BUCKETS: every bucket.
func fade_bucket(near_m: float) -> int:
	if _fade_band < 0.0:
		return FADE_BUCKETS
	var keep := clampf((radius_m - near_m) / maxf(_fade_band * radius_m, 0.001), 0.0, 1.0)
	return mini(int(keep * FADE_BUCKETS), FADE_BUCKETS)


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
func _holes_near(origin: Vector3, hole_list: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in mini(hole_list.size(), MAX_HOLES):
		var h := hole_list[i]
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


## One mesh per entry of `draws` from the content's ground-cover models at
## level of detail `lod` ("hi" or "lo"), each given a grass.gdshader
## material with the atlas of `texture_set` and the "shader" numbers of the
## tuning; null for a draw whose model is missing (with an error). A type
## with several variants uses <type>_<n>, n from 1.
func load_meshes(root: String, lod: String, texture_set: String) -> Array[Mesh]:
	var out: Array[Mesh] = []
	var atlas_path := root.path_join(TEXTURE_DIR).path_join(texture_set).path_join(
		CATEGORY + "_ca.png"
	)
	var atlas: Texture2D = load(atlas_path) if ResourceLoader.exists(atlas_path) else null
	if atlas == null:
		errors.append("%s: missing" % atlas_path)
	var shader: Shader = load(SHADER)
	var params: Dictionary = _cfg.get("shader", {})
	for d: Array in draws:
		var types: Dictionary = _cfg.types
		var stem: String = (
			d[0] if int(types[d[0]].variants) == 1 else "%s_%d" % [d[0], int(d[1]) + 1]
		)
		var path := root.path_join(MODEL_DIR).path_join("%s_%s_%s.glb" % [CATEGORY, stem, lod])
		if not ResourceLoader.exists(path):
			errors.append("%s: missing" % path)
			out.append(null)
			continue
		var node := (load(path) as PackedScene).instantiate()
		var found := node.find_children("*", "MeshInstance3D", true, false)
		var mesh: Mesh = (found[0] as MeshInstance3D).mesh if not found.is_empty() else null
		node.free()
		if mesh == null:
			errors.append("%s: no mesh" % path)
			out.append(null)
			continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("use_texture", atlas != null)
		mat.set_shader_parameter("albedo_tex", atlas)
		mat.set_shader_parameter("blade_height_m", maxf(mesh.get_aabb().end.y, 0.01))
		mat.set_shader_parameter("radius_m", radius_m)
		for key: String in SHADER_KEYS:
			if params.has(key):
				mat.set_shader_parameter(key, float(params[key]))
		mesh.surface_set_material(0, mat)
		out.append(mesh)
	return out


## Bender spheres (engine x, y, z, radius), at most 4; the rest are unused.
func set_benders(points: Array[Vector4]) -> void:
	var list: Array[Vector4] = []
	for i in 4:
		list.append(points[i] if i < points.size() else Vector4.ZERO)
	for m in _meshes:
		if m != null:
			(m.surface_get_material(0) as ShaderMaterial).set_shader_parameter("benders", list)


## Starts streaming with one mesh per entry of `draws` (null: nothing drawn
## for that draw).
func start(meshes: Array[Mesh]) -> void:
	_meshes = meshes
	_last_eye = Vector3(INF, INF, INF)


## The cells reaching within `r` metres of engine `eye` (in x and z),
## nearest first.
func cells_within(eye: Vector3, r: float) -> Array[Vector2i]:
	var m := _world.world_to_map(eye)
	# One cell more below: a cell whose far edge lies exactly r away counts.
	var lo := Vector2i(floori((m.x - r) / cell_m) - 1, floori((m.z - r) / cell_m) - 1)
	var hi := Vector2i(floori((m.x + r) / cell_m), floori((m.z + r) / cell_m))
	var last := floori(_world.size_m / cell_m) - 1
	var found := []
	for cz in range(maxi(lo.y, 0), mini(hi.y, last) + 1):
		for cx in range(maxi(lo.x, 0), mini(hi.x, last) + 1):
			var d := _cell_distance(m, Vector2i(cx, cz))
			if d <= r:
				found.append([d, Vector2i(cx, cz)])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[Vector2i] = []
	for f: Array in found:
		out.append(f[1])
	return out


## Builds, adds and frees cells for the eye at engine `eye`.
func update(eye: Vector3) -> void:
	if _world == null or _meshes.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	if Vector2(eye.x - _last_eye.x, eye.z - _last_eye.z).length() >= RESELECT_M:
		_last_eye = eye
		_wanted = cells_within(eye, radius_m)
		var m := _world.world_to_map(eye)
		for c: Vector2i in _cells.keys():
			if _cell_distance(m, c) > radius_m + KEEP_EXTRA_M:
				_free_cell(c)
	_assemble_step()
	_finish_one()
	_cut_cells(eye)
	for c in _wanted:
		if _pending.size() >= MAX_BUILDS:
			break
		if not _pending.has(c) and (not _cells.has(c) or _stale.has(c)):
			_stale.erase(c)
			_pending[c] = WorkerThreadPool.add_task(_build.bind(c, holes), false, "grass cell")
	worst_update_usec = maxi(worst_update_usec, Time.get_ticks_usec() - t0)


## Replaces the hole circles; the added cells they touch (old or new) are
## rebuilt.
func set_holes(list: PackedVector3Array) -> void:
	var touched := {}
	for h in holes:
		if not list.has(h):
			touched[h] = true
	for h in list:
		if not holes.has(h):
			touched[h] = true
	holes = list
	for c: Vector2i in _cells:
		for h: Vector3 in touched:
			if not _holes_near(cell_origin(c), PackedVector3Array([h])).is_empty():
				_stale[c] = true
				break


## True when every wanted cell is added and nothing is building.
func is_settled() -> bool:
	if not _pending.is_empty() or not _stale.is_empty() or not _assembly.is_empty():
		return false
	for c in _wanted:
		if not _cells.has(c):
			return false
	return true


## The added cells (for checks).
func added_cells() -> Array:
	return _cells.keys()


## Waits for the builds in flight (for tests); update() then adds them.
func wait_for_builds() -> void:
	for c: Vector2i in _pending.keys():
		if _pending[c] >= 0:
			WorkerThreadPool.wait_for_task_completion(_pending[c])
			_pending[c] = -1


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		update(cam.global_position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if not _assembly.is_empty():
			(_assembly[1] as Node3D).free()
		for c: Vector2i in _pending:
			if _pending[c] >= 0:
				WorkerThreadPool.wait_for_task_completion(_pending[c])


func _cell_distance(map: Vector3, c: Vector2i) -> float:
	var x := clampf(map.x, c.x * cell_m, (c.x + 1) * cell_m)
	var z := clampf(map.z, c.y * cell_m, (c.y + 1) * cell_m)
	return Vector2(map.x - x, map.z - z).length()


func _build(cell: Vector2i, hole_list: PackedVector3Array) -> void:
	var t0 := Time.get_ticks_usec()
	var ends: Array = []
	var arrays := _build_cell(cell, hole_list, ends)
	var took := Time.get_ticks_usec() - t0
	_mutex.lock()
	_done[cell] = [arrays, ends]
	worst_build_usec = maxi(worst_build_usec, took)
	_mutex.unlock()


## Takes the first finished build when no cell is being assembled.
func _finish_one() -> void:
	if not _assembly.is_empty():
		return
	for c: Vector2i in _pending.keys():
		var task: int = _pending[c]
		if task >= 0:
			if not WorkerThreadPool.is_task_completed(task):
				continue
			WorkerThreadPool.wait_for_task_completion(task)
		_pending.erase(c)
		_mutex.lock()
		var built: Variant = _done.get(c)
		_done.erase(c)
		_mutex.unlock()
		if built == null or not _wanted.has(c):
			continue
		var holder := Node3D.new()
		holder.name = "Cell_%d_%d" % [c.x, c.y]
		holder.position = cell_origin(c)
		# In the tree but hidden: each MultiMesh enters the tree in its own step.
		holder.visible = false
		add_child(holder)
		_assembly = [c, holder, built[0], 0, 0, built[1], []]
		return


## One step of the cell being assembled: one MultiMesh (one buffer upload)
## per update keeps the main thread short when crossing cells; when every
## draw is in, the cell replaces its old version in one go, so it never
## shows half built or bare.
func _assemble_step() -> void:
	if _assembly.is_empty():
		return
	var c: Vector2i = _assembly[0]
	var holder: Node3D = _assembly[1]
	var arrays: Array[PackedFloat32Array] = _assembly[2]
	if not _wanted.has(c):
		holder.free()
		_assembly = []
		return
	var d: int = _assembly[3]
	while d < arrays.size():
		var n := arrays[d].size() / STRIDE
		if n > 0 and d < _meshes.size() and _meshes[d] != null:
			break
		d += 1
	if d < arrays.size():
		var n := arrays[d].size() / STRIDE
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _meshes[d]
		mm.instance_count = n
		mm.buffer = arrays[d]
		var node := MultiMeshInstance3D.new()
		node.name = "%s_%d" % [draws[d][0], draws[d][1]]
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(node)
		(_assembly[6] as Array).append([mm, (_assembly[5] as Array)[d]])
		_assembly[3] = d + 1
		_assembly[4] = int(_assembly[4]) + n
		return
	if _cells.has(c):
		_free_cell(c)
	holder.visible = true
	_cells[c] = [holder, int(_assembly[4]), _assembly[6], -1]
	instances += int(_assembly[4])
	_assembly = []
	_cut_eye = Vector3(INF, INF, INF)


## Draws only the plants of each cell that the fade can show from `eye`
## (fade_cut at the cell's nearest point, CUT_STEP_M nearer), worked out
## again when the eye moved CUT_STEP_M or a cell was added.
func _cut_cells(eye: Vector3) -> void:
	var m := _world.world_to_map(eye)
	if Vector2(m.x - _cut_eye.x, m.z - _cut_eye.z).length() < CUT_STEP_M:
		return
	var t0 := Time.get_ticks_usec()
	_cut_eye = m
	for c: Vector2i in _cells:
		var entry: Array = _cells[c]
		var b := fade_bucket(maxf(_cell_distance(m, c) - CUT_STEP_M, 0.0))
		if b == int(entry[3]):
			continue  # every draw of the cell keeps its cut
		entry[3] = b
		for pair: Array in entry[2]:
			var mm: MultiMesh = pair[0]
			var ends: PackedInt32Array = pair[1]
			var n := -1 if b >= FADE_BUCKETS else ends[b]
			if n >= mm.instance_count:
				n = -1
			if mm.visible_instance_count != n:
				mm.visible_instance_count = n
	worst_cut_usec = maxi(worst_cut_usec, Time.get_ticks_usec() - t0)


func _free_cell(c: Vector2i) -> void:
	var entry: Array = _cells[c]
	instances -= int(entry[1])
	(entry[0] as Node3D).queue_free()
	_cells.erase(c)
	_stale.erase(c)
