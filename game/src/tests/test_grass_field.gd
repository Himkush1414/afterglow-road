extends TestCase
## GrassField cell builds on the sample world: identical arrays for the same
## cell (T-06-8), counts by density, and no plant in a hole, on a way or in
## water (T-06-9).

const CELL := Vector2i(5, 6)
const CFG := {
	"cell_m": 32,
	"seed": 3,
	"road_mask_below": 0.5,
	"water_depth_max_m": 0.2,
	"types": {"tuft": {"variants": 3, "scale": [0.8, 1.2]}, "bloom": {"variants": 2}},
	"layers":
	{
		"ground": {"density": 2.0, "types": {"tuft": 0.9, "bloom": 0.1}},
		"stone": {"density": 0.0, "types": {}},
	},
}
## Every biome id grows "ground"; no slope layers: the same weights everywhere.
const TERRAIN := {
	"layers": ["ground", "stone"],
	"biome_layer":
	{
		"0": "ground",
		"1": "ground",
		"2": "ground",
		"3": "ground",
		"4": "ground",
		"5": "ground",
		"6": "ground",
		"7": "ground",
		"8": "ground",
		"9": "ground",
	},
	"dirt_layer": "stone",
}

var _world: WorldData
var _fields: Array[GrassField] = []


func before_each() -> void:
	_world = WorldData.new()


func after_each() -> void:
	for f in _fields:
		f.free()
	_fields.clear()
	_world.free()


func _field(mult: float = 1.0, cfg: Dictionary = CFG) -> GrassField:
	var f := GrassField.new()
	_fields.append(f)
	if not check(_world.is_loaded() or _world.load_dir(ContentDB.SAMPLE_ROOT + "/world")):
		return f
	check(f.configure(_world, cfg, TERRAIN, mult), ", ".join(f.errors))
	return f


static func _count(arrays: Array[PackedFloat32Array]) -> int:
	var n := 0
	for a in arrays:
		n += a.size() / GrassField.STRIDE
	return n


## Engine (x, z) of every instance of a build.
static func _points(f: GrassField, cell: Vector2i, arrays: Array[PackedFloat32Array]) -> Array:
	var o := f.cell_origin(cell)
	var out := []
	for a in arrays:
		for i in a.size() / GrassField.STRIDE:
			out.append(
				Vector2(o.x + a[i * GrassField.STRIDE + 3], o.z + a[i * GrassField.STRIDE + 11])
			)
	return out


func test_same_cell_same_arrays() -> void:
	var a := _field()
	var first := a.build_cell(CELL)
	check(_count(first) > 0, "plants in the cell")
	check(first == a.build_cell(CELL), "same field, same arrays")
	var b := _field()
	check(first == b.build_cell(CELL), "a new field builds the same arrays")
	check(first != a.build_cell(CELL + Vector2i(1, 0)), "the next cell differs")
	check_eq(first.size(), 5, "one array per draw (3 + 2 variants)")


func test_count_follows_density_and_preset() -> void:
	var f := _field()
	var n := _count(f.build_cell(CELL))
	# 2 per m² over 32 m x 32 m: the per-sub-cell rounding keeps it within a few percent.
	check(absf(n - 2048.0) < 2048.0 * 0.05, "about 2,048 plants, got %d" % n)
	var half := _count(_field(0.5).build_cell(CELL))
	check(absf(half - 1024.0) < 1024.0 * 0.05, "half with multiplier 0.5, got %d" % half)
	var arrays := f.build_cell(CELL)
	var tufts := 0
	for d in 3:
		tufts += arrays[d].size() / GrassField.STRIDE
	check(absf(float(tufts) / n - 0.9) < 0.03, "tuft share 0.9, got %.3f" % (float(tufts) / n))


func test_instance_transform_stands_on_the_ground() -> void:
	var f := _field()
	var arrays := f.build_cell(CELL)
	# MultiMesh buffer layout: three basis rows, each followed by an origin
	# component (the headless renderer does not keep buffers to read back).
	var a := arrays[0]
	var t := Transform3D(
		Vector3(a[0], a[4], a[8]),
		Vector3(a[1], a[5], a[9]),
		Vector3(a[2], a[6], a[10]),
		Vector3(a[3], a[7], a[11])
	)
	var o := f.cell_origin(CELL)
	var at := o + Vector3(t.origin.x, 0.0, t.origin.z)
	check_near(t.origin.y, _world.height_at(at.x, at.z), 1e-4, "on the ground")
	var off := 0
	for k in a.size() / GrassField.STRIDE:
		var p := o + Vector3(a[k * GrassField.STRIDE + 3], 0.0, a[k * GrassField.STRIDE + 11])
		off += int(absf(a[k * GrassField.STRIDE + 7] - _world.height_at(p.x, p.z)) > 1e-3)
	check_eq(off, 0, "every plant on the ground")
	check(
		t.origin.x >= 0.0 and t.origin.x < 32.0 and t.origin.z >= 0.0 and t.origin.z < 32.0,
		"in the cell"
	)
	var s := t.basis.get_scale()
	check(s.x >= 0.8 - 1e-4 and s.x <= 1.2 + 1e-4, "scale in range: %s" % str(s))
	check_near(t.basis.y.normalized().y, 1.0, 1e-5, "upright")
	check(a[12] >= 0.0 and a[12] < 1.0 and a[13] >= 0.0 and a[13] < 1.0, "fade key and phase")
	check_near(t.basis.x.dot(t.basis.z), 0.0, 1e-5, "a yaw turn, not a shear")


func test_nothing_in_holes_on_ways_or_in_water() -> void:
	var f := _field()
	var o := f.cell_origin(CELL)
	var plain := _points(f, CELL, f.build_cell(CELL))
	var on_way := func(p: Vector2) -> bool: return p.x - o.x >= 4.0 and p.x - o.x < 8.0
	check(not plain.filter(on_way).is_empty(), "control: plants where the way will be")
	# The way: mask column 1 of the cell (4..8 m) at 0.6, column 2 (8..12 m) at 0.4.
	var side := _world.mask_side()
	f.mask_side = side
	f.mask = PackedByteArray()
	f.mask.resize(side * side * 4)
	var i0 := floori(_world.world_to_map(o).x / 4.0)
	for j in side:
		f.mask[(j * side + i0 + 1) * 4] = 153
		f.mask[(j * side + i0 + 2) * 4] = 102
	var before := _points(f, CELL, f.build_cell(CELL))
	check_eq(before.filter(on_way).size(), 0, "none where the way reaches 0.5")
	var edge := before.filter(
		func(p: Vector2) -> bool: return p.x - o.x >= 8.0 and p.x - o.x < 12.0
	)
	check(not edge.is_empty(), "some at the way's edge (0.4)")
	var hole := Vector3(o.x + 20.0, o.z + 16.0, 5.0)
	var in_hole := func(p: Vector2) -> bool: return p.distance_to(Vector2(hole.x, hole.y)) <= 5.0
	var deep := func(p: Vector2) -> bool: return p.y - o.z > 26.0
	check(not before.filter(in_hole).is_empty(), "control: plants where the hole will be")
	check(not before.filter(deep).is_empty(), "control: plants where the water will be")
	f.holes = PackedVector3Array([hole])
	# The water: 1 m deep beyond 26 m into the cell, 0.1 m from 22 m.
	f.depth_of = func(p: Vector3) -> float:
		return 1.0 if p.z - o.z > 26.0 else (0.1 if p.z - o.z > 22.0 else 0.0)
	var after := _points(f, CELL, f.build_cell(CELL))
	check_eq(after.filter(in_hole).size(), 0, "none in the hole")
	check_eq(after.filter(deep).size(), 0, "none in water deeper than 0.2 m")
	check(
		not after.filter(func(p: Vector2) -> bool: return p.y - o.z > 22.0).is_empty(),
		"some in shallow water"
	)
	var was := {}
	for p: Vector2 in before:
		was[p] = true
	var moved := after.filter(func(p: Vector2) -> bool: return not was.has(p))
	check_eq(moved.size(), 0, "holes and water only remove plants")
	check(after.size() < before.size(), "fewer plants")


func test_unknown_layer_or_type_is_an_error() -> void:
	var cfg := CFG.duplicate(true)
	cfg.layers["lava"] = {"density": 1.0, "types": {"tuft": 1.0}}
	cfg.layers.ground.types["weed"] = 1.0
	var f := GrassField.new()
	_fields.append(f)
	check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"))
	check(not f.configure(_world, cfg, TERRAIN, 1.0), "rejected")
	check_eq(f.errors.size(), 2, str(f.errors))


func test_missing_models_are_reported_by_name() -> void:
	var cfg := CFG.duplicate(true)
	cfg.types["mat"] = {"variants": 1}
	cfg.layers.ground.types["mat"] = 0.1
	var f := _field(1.0, cfg)
	var meshes := f.load_meshes("res://no_such_content", "lo", "lo")
	check_eq(meshes.size(), f.draws.size(), "one entry per draw")
	check_eq(meshes.count(null), meshes.size(), "all missing")
	var text := "\n".join(f.errors)
	for stem: String in ["tuft_1", "tuft_2", "tuft_3", "bloom_1", "bloom_2", "mat"]:
		check(text.contains("ground_cover_%s_lo.glb: missing" % stem), stem)
	check(text.contains("lo/ground_cover_ca.png: missing"), "the atlas")
	check_eq(f.errors.size(), 7, text)
