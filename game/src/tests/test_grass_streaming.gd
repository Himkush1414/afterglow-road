extends TestCase
## GrassField streaming on the sample world: the cells within the radius are
## built on workers and added, far cells are freed, and a hole rebuilds the
## cell it touches without leaving it bare.

const CFG := {
	"cell_m": 32,
	"road_mask_below": 0.5,
	"water_depth_max_m": 0.2,
	"types": {"tuft": {"variants": 2}},
	"layers": {"ground": {"density": 0.5, "types": {"tuft": 1.0}}},
}
const TERRAIN := {
	"layers": ["ground"],
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
}

var _world: WorldData
var _field: GrassField


func before_each() -> void:
	_world = WorldData.new()
	_field = GrassField.new()
	tree.root.add_child(_field)


func after_each() -> void:
	_field.wait_for_builds()
	_field.free()
	_world.free()


func _setup() -> bool:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(_world.errors)):
		return false
	if not check(_field.configure(_world, CFG, TERRAIN, 1.0), ", ".join(_field.errors)):
		return false
	_field.radius_m = 48.0
	var meshes: Array[Mesh] = [BoxMesh.new(), BoxMesh.new()]
	_field.start(meshes)
	return true


func _eye(map_x: float, map_z: float) -> Vector3:
	return _world.map_to_world(Vector3(map_x, 0.0, map_z))


## Updates until settled (at most `steps` updates); false if it never does.
func _settle(eye: Vector3, steps: int = 200) -> bool:
	for i in steps:
		_field.update(eye)
		_field.wait_for_builds()
		if _field.is_settled():
			return true
	return false


static func _plants(arrays: Array[PackedFloat32Array]) -> int:
	var n := 0
	for a in arrays:
		n += a.size() / GrassField.STRIDE
	return n


func test_cells_within_the_radius_nearest_first() -> void:
	if not _setup():
		return
	var eye := _eye(208.0, 208.0)
	var cells := _field.cells_within(eye, 48.0)
	# The eye stands at a cell centre: the 3 x 3 block (edges 16 m away) and
	# the four cells two away in line (48 m); (2, 1) is 50.6 m away.
	check_eq(cells.size(), 13, "3 x 3 and four in line")
	check_eq(cells[0], Vector2i(6, 6), "own cell first")
	var m := _world.world_to_map(eye)
	var last := 0.0
	for c in cells:
		var x := clampf(m.x, c.x * 32.0, c.x * 32.0 + 32.0)
		var z := clampf(m.z, c.y * 32.0, c.y * 32.0 + 32.0)
		var d := Vector2(m.x - x, m.z - z).length()
		check(d <= 48.0 and d >= last - 1e-4, "within the radius, nearest first: %s" % str(c))
		last = d
	check_eq(_field.cells_within(_eye(2.0, 2.0), 48.0).size(), 4, "clipped at the map edge")


func test_streams_cells_around_the_eye() -> void:
	if not _setup():
		return
	var eye := _eye(208.0, 208.0)
	check(_settle(eye), "settles")
	var want := _field.cells_within(eye, 48.0)
	var added := _field.added_cells()
	check_eq(added.size(), want.size(), "every wanted cell added")
	var plants := 0
	for c in want:
		check(added.has(c), "added %s" % str(c))
		plants += _plants(_field.build_cell(c))
	check_eq(_field.instances, plants, "all their plants")
	check(plants > 0, "plants")
	var far := _eye(400.0, 400.0)
	check(_settle(far), "settles after a move")
	var m := _world.world_to_map(far)
	for c: Vector2i in _field.added_cells():
		var x := clampf(m.x, c.x * 32.0, c.x * 32.0 + 32.0)
		var z := clampf(m.z, c.y * 32.0, c.y * 32.0 + 32.0)
		check(
			Vector2(m.x - x, m.z - z).length() <= 48.0 + GrassField.KEEP_EXTRA_M,
			"freed %s" % str(c)
		)
	check(not _field.added_cells().has(Vector2i(6, 6)), "the first cell is gone")


func test_a_hole_rebuilds_its_cell_without_a_gap() -> void:
	if not _setup():
		return
	var eye := _eye(208.0, 208.0)
	check(_settle(eye), "settles")
	var before := _field.instances
	var o := _field.cell_origin(Vector2i(6, 6))
	var hole := Vector3(o.x + 16.0, o.z + 16.0, 6.0)
	var inside := 0
	var arrays := _field.build_cell(Vector2i(6, 6))
	for a in arrays:
		for i in a.size() / GrassField.STRIDE:
			var p := Vector2(a[i * GrassField.STRIDE + 3], a[i * GrassField.STRIDE + 11])
			inside += int(p.distance_to(Vector2(16.0, 16.0)) <= 6.0)
	check(inside > 0, "control: plants where the hole goes")
	_field.set_holes(PackedVector3Array([hole]))
	check(not _field.is_settled(), "the touched cell waits for its rebuild")
	var gaps := 0
	for i in 200:
		_field.update(eye)
		_field.wait_for_builds()
		gaps += int(not _field.added_cells().has(Vector2i(6, 6)))
		if _field.is_settled():
			break
	check(_field.is_settled(), "settles")
	check_eq(gaps, 0, "the cell never went bare")
	check_eq(_field.instances, before - inside, "only the plants in the hole went")
