extends TestCase
## Pause menu: opens and closes by intent, stops the game clock, saves, and
## quits to the title with a save.

const DIR := "user://tests/pause_saves"

var _menu: Control


func before_each() -> void:
	_wipe(DIR)
	SaveGame.saves_dir = DIR
	await App.start_game("slot_1", true)
	_menu = Game.current.get_node("UI/PauseMenu")


func after_each() -> void:
	tree.paused = false
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	_wipe(DIR)


func test_pause_intent_opens_and_stops_the_clock() -> void:
	check(not _menu.visible, "hidden in play")
	InputRouter.intent.emit(&"pause", &"press")
	check(_menu.visible and tree.paused, "open and paused")
	var t := Game.clock_of().now_gmin
	for i in 10:
		await tree.process_frame
	check_eq(Game.clock_of().now_gmin, t, "clock stopped while paused")
	InputRouter.intent.emit(&"back", &"press")
	check(not _menu.visible and not tree.paused, "back closes")
	InputRouter.intent.emit(&"pause", &"press")
	InputRouter.intent.emit(&"pause", &"release")
	InputRouter.intent.emit(&"pause", &"press")
	check(not _menu.visible, "pause again closes; releases are ignored")
	InputRouter.intent.emit(&"back", &"press")
	check(not tree.paused, "back without the menu changes nothing")


func test_save_and_quit_to_title() -> void:
	InputRouter.intent.emit(&"pause", &"press")
	Game.clock_of().set_now(4321.0)
	_menu.save_button.pressed.emit()
	check_eq(_menu.status.text, "ui.pause.saved")
	SaveGame.load_slot("slot_1")
	check_near(Game.clock_of().now_gmin, 4321.0, 1e-6, "saved state")
	Game.clock_of().set_now(5555.0)
	_menu.quit_button.pressed.emit()
	await App.scene_shown
	check_eq(App.current_path, App.TITLE_SCENE)
	check(not tree.paused, "title is not paused")
	check_eq(SaveGame.read_meta("slot_1").clock, "20:35", "quit saved first (day 4, 20:35)")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
