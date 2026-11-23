extends TestCase
## Game scene: a new game enters the empty world and is saved at once;
## Continue restores the clock and the ids counter; slot choice.

const DIR := "user://tests/game_saves"

var _counter := 0


func before_each() -> void:
	_wipe(DIR)
	SaveGame.saves_dir = DIR
	_counter = Ids.counter()


func after_each() -> void:
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	Ids.set_counter(_counter)
	_wipe(DIR)


func test_new_game_enters_the_world_and_saves() -> void:
	check_eq(Game.free_slot(), "slot_1")
	check_eq(await App.start_game("slot_1", true), OK)
	check_eq(App.current_path, Game.SCENE)
	var clock := Game.clock_of()
	check(clock != null and clock.is_configured(), "clock ready")
	var start := float(ContentDB.tuning("clock").start_gmin)
	check_near(clock.now_gmin, start, 1.0, "clock at the start time")
	check(SaveGame.has_save("slot_1"), "saved at once")
	var game := Game.current
	check(game.wind.is_configured(), "wind configured")
	check(game.weather.wind == game.wind, "weather drives the wind")
	check(game.wind.world == game.world, "wind reads the world's biomes")
	var meta: Dictionary = SaveGame.read_meta("slot_1")
	check_eq([int(meta.day), meta.difficulty], [1, "standard"])
	check_eq(Game.newest_slot(), "slot_1")
	check_eq(Game.free_slot(), "slot_2")


func test_continue_restores_the_saved_state() -> void:
	await App.start_game("slot_2", true)
	Game.clock_of().set_now(5000.0)
	var next_id := Ids.next()
	check_eq(SaveGame.save_slot("slot_2"), OK)
	await App.show_title()
	Ids.set_counter(Ids.FIRST_DYNAMIC)
	check_eq(await App.start_game("slot_2", false), OK)
	check_near(Game.clock_of().now_gmin, 5000.0, 1.0, "clock restored")
	check_eq(Ids.counter(), next_id + 1, "ids counter restored")
	check_eq(SaveGame.active_slot, "slot_2")


func test_a_missing_save_returns_to_the_title() -> void:
	check_eq(await App.start_game("slot_3", false), ERR_FILE_CORRUPT)
	check_eq(App.current_path, App.TITLE_SCENE)
	check_eq(SaveGame.active_slot, "", "no active slot on the title")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
