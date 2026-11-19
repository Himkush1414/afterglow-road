extends TestCase
## App lifecycle (P2-12): focus loss and OS pause stop the game behind the
## pause menu and save; a clean quit saves and lets writes finish.

const DIR := "user://tests/lifecycle_saves"


func before_each() -> void:
	SaveGame.saves_dir = DIR
	await App.start_game("slot_1", true)


func after_each() -> void:
	while SaveGame.is_writing():
		await tree.process_frame
	tree.paused = false
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	for f in DirAccess.get_files_at(DIR + "/slot_1"):
		DirAccess.remove_absolute(DIR + "/slot_1/" + f)


func test_focus_loss_pauses_and_saves() -> void:
	Game.clock_of().set_now(2000.0)
	Game.current.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var menu: Control = Game.current.get_node("UI/PauseMenu")
	check(menu.visible and tree.paused, "paused behind the menu")
	while SaveGame.is_writing():
		await tree.process_frame
	SaveGame.load_slot("slot_1")
	check_near(Game.clock_of().now_gmin, 2000.0, 1e-6, "saved on focus loss")
	Game.current.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(menu.visible, "a second focus loss keeps the menu open")


func test_os_pause_pauses_and_saves_at_once() -> void:
	Game.clock_of().set_now(3000.0)
	tree.root.propagate_notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(Game.current.get_node("UI/PauseMenu").visible and tree.paused, "paused")
	check(not SaveGame.is_writing(), "saved synchronously")
	check_eq(int(SaveGame.read_meta("slot_1").day), 3, "saved before returning")


func test_a_clean_quit_saves_and_waits_for_writes() -> void:
	Game.clock_of().set_now(4000.0)
	SaveGame.save_slot_async("slot_1")
	Game.clock_of().set_now(4500.0)
	SaveGame.flush()  # what App.quit does before quitting
	check(not SaveGame.is_writing(), "running write finished")
	SaveGame.load_slot("slot_1")
	check_near(Game.clock_of().now_gmin, 4500.0, 1e-6, "latest state saved")
