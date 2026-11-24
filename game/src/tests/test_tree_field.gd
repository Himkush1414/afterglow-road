extends TestCase
## TreeField on the sample world (three trees, one 512 m tile): records,
## billboard buffers, tile selection and streaming.

const TIERS := [40.0, 120.0, 450.0, 2400.0]

var _world: WorldData
var _field: TreeField


func before_each() -> void:
	_world = WorldData.new()
	_field = TreeField.new()
	tree.root.add_child(_field)


func after_each() -> void:
	_field.free()
	_world.free()


func _setup() -> bool:
	if not check(_world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(_world.errors)):
		return false
	var defs: Array = (
		JSON
		. parse_string(FileAccess.get_file_as_string(ContentDB.SAMPLE_ROOT + "/data/trees.json"))
		. trees
	)
	return check(
		_field.setup(_world, defs, {}, TIERS, ContentDB.SAMPLE_ROOT), ", ".join(_field.errors)
	)


func test_records_decode() -> void:
	if not _setup():
		return
	var raw := _field.chunk_records(Vector2i(0, 0))
	check_eq(raw.size(), 2 * TreeField.RECORD_BYTES, "two trees in chunk (0, 0)")
	var r := TreeField.decode(raw, Vector2i(0, 0), 0)
	check_eq(r.model, 0)
	check_eq(r.map, Vector2(20.0, 30.0))
	check(r.scale >= 0.75 and r.scale <= 1.25, "scale in range")
	check_eq(_field.chunk_records(Vector2i(3, 3)).size(), 0, "a chunk without trees")
	check_eq(TreeField.record_hash(5, 7), TreeField.record_hash(5, 7))
	check(TreeField.record_hash(5, 7) != TreeField.record_hash(5, 8), "records differ")


func test_tile_buffer_places_billboards_on_the_ground() -> void:
	if not _setup():
		return
	var result := _field.tile_buffer(Vector2i(0, 0))
	var buf: PackedFloat32Array = result[0]
	check_eq(result[1], 3, "all three sample trees")
	check_eq(buf.size(), 3 * TreeField.STRIDE)
	var r := TreeField.decode(_field.chunk_records(Vector2i(0, 0)), Vector2i(0, 0), 0)
	var pos := _world.map_to_world(Vector3(20.0, 0.0, 30.0))
	check_near(buf[3], pos.x, 1e-3, "x")
	check_near(buf[11], pos.z, 1e-3, "z")
	check_near(buf[7], _world.height_at(pos.x, pos.z), 1e-3, "on the ground (stand-in bottom 0)")
	check_near(buf[0], 8.0 * r.scale, 1e-4, "stand-in side = max(height, 2 x crown) x scale")
	check_eq(buf[1], 0.0)
	check(buf[12] >= 0.0 and buf[12] <= 1.0, "phase 0..1")
	check(buf[13] >= -1.0 and buf[13] <= 1.0, "tint -1..1")
	check_eq(buf[15], 0.0, "stand-in atlas cell")
	check_eq(_field.tile_buffer(Vector2i(0, 0)), result, "deterministic")


func test_tiles_follow_the_far_range() -> void:
	if not _setup():
		return
	var centre := _world.map_to_world(Vector3(256.0, 0.0, 256.0))
	check_eq(_field.tiles_within(centre, _field.reach_m()), [Vector2i(0, 0)])
	var edge := _world.map_to_world(Vector3(256.0, 0.0, 512.0 + 2399.0))
	check_eq(_field.tiles_within(edge, _field.reach_m()), [Vector2i(0, 0)], "just inside")
	var far := _world.map_to_world(Vector3(256.0, 0.0, 512.0 + 2401.0))
	check_eq(_field.tiles_within(far, _field.reach_m()), [], "just outside")


func test_streaming_builds_and_frees_a_tile() -> void:
	if not _setup():
		return
	var centre := _world.map_to_world(Vector3(256.0, 0.0, 256.0))
	for i in 300:
		_field.update_for(centre)
		if _field.is_settled() and not _field.built_tiles().is_empty():
			break
		await tree.process_frame
	check_eq(_field.built_tiles(), [Vector2i(0, 0)])
	check_eq(_field.instances, 3)
	_field.update_for(_world.map_to_world(Vector3(256.0, 0.0, 512.0 + 2400.0 + 300.0)))
	check_eq(_field.built_tiles(), [], "freed beyond the range + keep margin")
	check_eq(_field.instances, 0)


func test_mid_tier_chunks_reach_into_the_t2_range() -> void:
	if not _setup():
		return
	var centre := _world.map_to_world(Vector3(256.0, 0.0, 256.0))
	check_eq(_field.mid_chunks(centre).size(), 16, "all 16 chunks of the sample reach into T2")
	check_eq(_field.chunk_buffers(Vector2i(0, 0)), {}, "no models in the sample: no T2 instances")
	_field.tiers_m = [40.0, 300.0, 450.0, 2400.0]
	var chunks := _field.mid_chunks(centre)
	check(not chunks.has(Vector2i(1, 1)), "a chunk wholly inside T1 is left out")
	check(chunks.has(Vector2i(0, 0)), "a chunk reaching past T1 is kept")
	_field.tiers_m = [40.0, 120.0, 120.0, 2400.0]
	check_eq(_field.mid_chunks(centre), [], "an empty T2 range has no chunks")
