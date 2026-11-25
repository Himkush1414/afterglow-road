extends TestCase
## LeafParticles on the sample world: crown points of the nearest leafy
## trees, emission switched by the wind at the crowns, amount by preset.

const TIERS := [40.0, 120.0, 450.0, 2400.0]
const TREE := Vector2(20.0, 30.0)
const CFG := {
	"min_wind_ms": 14.0,
	"radius_m": 40.0,
	"amount": 200,
	"lifetime_s": 3.0,
	"size_m": 0.08,
	"crown_height": 0.7,
	"points_max": 128,
	"reselect_m": 8.0,
	"drift": 0.6,
	"gravity_ms2": 1.0,
	"colour": [0.36, 0.42, 0.18],
}

var _world: WorldData
var _field: TreeField
var _leaves: LeafParticles
var _defs: Array
var _speed := 0.0


func before_each() -> void:
	_world = WorldData.new()
	_field = TreeField.new()
	tree.root.add_child(_field)
	_leaves = LeafParticles.new()
	_leaves.set_process(false)
	_field.add_child(_leaves)


func after_each() -> void:
	_field.free()
	_world.free()


func _setup(cfg: Dictionary = CFG, mult: float = 1.0) -> bool:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(_world.errors)):
		return false
	_defs = (
		JSON
		. parse_string(FileAccess.get_file_as_string(ContentDB.SAMPLE_ROOT + "/data/trees.json"))
		. trees
	)
	if not check(_field.setup(_world, _defs, {}, TIERS, ContentDB.SAMPLE_ROOT)):
		return false
	var on := _leaves.setup(_field, _world, _defs, null, cfg, mult)
	_leaves.wind_of = func(_p: Vector3) -> float: return _speed
	return on


func _eye(map: Vector2) -> Vector3:
	var e := _world.map_to_world(Vector3(map.x, 0.0, map.y))
	e.y = _world.height_at(e.x, e.z) + 1.62
	return e


func test_crown_points_of_the_trees_in_range() -> void:
	if not check(_setup(), "configured"):
		return
	var eye := _eye(TREE + Vector2(5.0, 0.0))
	_leaves.update(eye)
	_leaves.wait_for_points()
	var want := 0
	for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 1)]:
		var raw := _field.chunk_records(c)
		for i in raw.size() / TreeField.RECORD_BYTES:
			var r := TreeField.decode(raw, c, i)
			want += int((r.map as Vector2).distance_to(TREE + Vector2(5.0, 0.0)) <= 40.0)
	check(want > 0, "a tree in range")
	check_eq(_leaves.points.size(), want, "one point per leafy tree within 40 m")
	var r0 := TreeField.decode(_field.chunk_records(Vector2i(0, 0)), Vector2i(0, 0), 0)
	var at := _world.map_to_world(Vector3(TREE.x, 0.0, TREE.y))
	var crown := _world.height_at(at.x, at.z) + 8.0 * 0.7 * float(r0.scale)
	check(
		_leaves.points[0].is_equal_approx(Vector3(at.x, crown, at.z)),
		"nearest first, at the crown: %s" % str(_leaves.points[0])
	)
	var far := _leaves.crown_points(_eye(Vector2(400.0, 400.0)))
	check_eq(far.size(), 0, "no tree within 40 m")


func test_emission_follows_the_wind_at_the_crowns() -> void:
	if not check(_setup(), "configured"):
		return
	var eye := _eye(TREE + Vector2(5.0, 0.0))
	_leaves.update(eye)
	_leaves.wait_for_points()
	_speed = 13.9
	_leaves.update(eye)
	check(not _leaves.emitting, "calm below 14 m/s")
	_speed = 14.0
	_leaves.update(eye)
	check(_leaves.emitting, "leaves at 14 m/s")
	var pm := _leaves.process_material as ParticleProcessMaterial
	check_eq(pm.emission_point_count, _leaves.points.size(), "emits from the crowns")
	check_near(pm.initial_velocity_max, 14.0 * 0.6 * 1.3, 1e-4, "drift with the wind")
	_leaves.setup(_field, _world, _defs, null, CFG, 1.0)
	_leaves.wind_of = func(_p: Vector3) -> float: return _speed
	_leaves.update(_eye(Vector2(400.0, 400.0)))
	_leaves.wait_for_points()
	_leaves.update(_eye(Vector2(400.0, 400.0)))
	check(not _leaves.emitting, "no crowns, no leaves")


func test_amount_scales_with_the_preset_and_tuning_is_optional() -> void:
	if not check(_setup(CFG, 0.4), "configured"):
		return
	check_eq(_leaves.amount, 80, "200 x 0.4")
	check(not _leaves.setup(_field, _world, _defs, null, {}, 1.0), "off without tuning")
	_leaves.update(_eye(TREE))
	check(not _leaves.emitting, "stays off")
