extends TestCase
## Ids and Rng: packed forms, the dynamic counter, deterministic streams.

const GOLDEN_WORLD: Array[int] = [2324639331, 4260556648, 4068321135, 4151160043]
const GOLDEN_SAVE: Array[int] = [21680400, 538770504, 2256468282, 732013040]

var _counter := 0
var _world := 0
var _save := 0


func before_each() -> void:
	_counter = Ids.counter()
	_world = Rng.world_seed
	_save = Rng.save_seed


func after_each() -> void:
	Ids.set_counter(_counter)
	Rng.world_seed = _world
	Rng.save_seed = _save


func test_packed_ids_follow_the_written_forms() -> void:
	check_eq(Ids.region_index(Vector2i(3, 5)), 5 * 16 + 3)
	check_eq(Ids.tree_id(Vector2i(2, 1), 7), ((1 * 64 + 2) << 12) | 7)
	check_eq(Ids.static_object_id(Vector2i(15, 15), (1 << 20) - 1), (255 << 20) | ((1 << 20) - 1))
	check(Ids.tree_id(Vector2i(63, 63), 4095) < 1 << 24, "tree ids fit 24 bits")
	check(
		Ids.static_object_id(Vector2i(15, 15), (1 << 20) - 1) < Ids.FIRST_DYNAMIC,
		"static ids stay below dynamic ids"
	)


func test_dynamic_ids_count_up_from_the_saved_counter() -> void:
	check(Ids.set_counter(Ids.FIRST_DYNAMIC + 10))
	check_eq(Ids.next(), Ids.FIRST_DYNAMIC + 10)
	check_eq(Ids.next(), Ids.FIRST_DYNAMIC + 11)
	check_eq(Ids.counter(), Ids.FIRST_DYNAMIC + 12)
	check(not Ids.set_counter(5), "counter below the dynamic range refused")
	check_eq(Ids.counter(), Ids.FIRST_DYNAMIC + 12)


func test_streams_repeat_for_the_same_key() -> void:
	Rng.world_seed = 12345
	check_eq(_draw(Rng.for_key(678)), _draw(Rng.for_key(678)))
	check(_draw(Rng.for_key(678)) != _draw(Rng.for_key(679)), "neighbouring keys differ")
	Rng.world_seed = 12346
	check(_draw(Rng.for_key(678)) != _draw_with_seed(12345, 678), "world seed changes streams")


func test_save_seed_changes_only_save_streams() -> void:
	Rng.world_seed = 12345
	Rng.save_seed = 1
	var world_a := _draw(Rng.for_key(678))
	var save_a := _draw(Rng.for_save_key(678))
	Rng.save_seed = 2
	check_eq(_draw(Rng.for_key(678)), world_a, "world stream ignores the save seed")
	check(_draw(Rng.for_save_key(678)) != save_a, "save stream follows the save seed")


func test_streams_match_the_recorded_values() -> void:
	# Saves and worlds rely on these; a change in hash() or the generator
	# shows up here first.
	Rng.world_seed = 12345
	Rng.save_seed = 7
	check_eq(_draw(Rng.for_key(678)), GOLDEN_WORLD)
	check_eq(_draw(Rng.for_save_key(678)), GOLDEN_SAVE)


func _draw(rng: RandomNumberGenerator) -> Array[int]:
	var out: Array[int] = []
	for i in 4:
		out.append(rng.randi())
	return out


func _draw_with_seed(world_seed: int, key: int) -> Array[int]:
	var keep := Rng.world_seed
	Rng.world_seed = world_seed
	var out := _draw(Rng.for_key(key))
	Rng.world_seed = keep
	return out
