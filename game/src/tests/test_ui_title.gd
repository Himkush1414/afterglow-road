extends TestCase
## Title menu: entries follow the saves; New game and Continue enter the game.

const DIR := "user://tests/title_saves"


func before_each() -> void:
	_wipe(DIR)
	SaveGame.saves_dir = DIR


func after_each() -> void:
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	_wipe(DIR)


func test_entries_follow_the_saves_and_start_the_game() -> void:
	await App.show_title()
	var title := tree.current_scene
	check(title.continue_button.disabled, "no save: Continue disabled")
	check(not title.new_game_button.disabled, "New game enabled")
	check_eq(title.continue_button.text, "ui.title.continue", "text is a key")
	check_eq(title.tr(title.continue_button.text), "Continue", "key is translated")
	title.new_game_button.pressed.emit()
	await App.scene_shown
	await tree.process_frame
	check_eq(App.current_path, Game.SCENE, "New game enters the game")
	check(SaveGame.has_save("slot_1"), "new game saved in the first slot")
	await App.show_title()
	title = tree.current_scene
	check(not title.continue_button.disabled, "a save: Continue enabled")
	title.continue_button.pressed.emit()
	await App.scene_shown
	await tree.process_frame
	check_eq([App.current_path, SaveGame.active_slot], [Game.SCENE, "slot_1"], "continued")


func test_new_game_is_disabled_when_every_slot_is_used() -> void:
	for s: String in Game.SLOTS:
		await App.start_game(s, true)
	await App.show_title()
	check(tree.current_scene.new_game_button.disabled, "all slots used")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
