extends TestCase
## T-18-7: with the pseudo-locale on, every visible text of the screens
## built so far is bracketed (none is hard-coded).

const DIR := "user://tests/pseudo_saves"


func before_each() -> void:
	SaveGame.saves_dir = DIR
	PseudoLocale.enable()


func after_each() -> void:
	PseudoLocale.disable()
	tree.paused = false
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	for f in DirAccess.get_files_at(DIR + "/slot_1"):
		DirAccess.remove_absolute(DIR + "/slot_1/" + f)


func test_title_and_pause_menu_show_only_keyed_text() -> void:
	await App.show_title()
	var title := tree.current_scene
	check(title.find_children("*", "Button").size() >= 3, "title has its buttons")
	check_eq(PseudoLocale.raw_texts(title), PackedStringArray(), "title")
	await App.start_game("slot_1", true)
	InputRouter.intent.emit(&"pause", &"press")
	var menu: Control = Game.current.get_node("UI/PauseMenu")
	check_eq(PseudoLocale.raw_texts(menu), PackedStringArray(), "pause menu")
	menu.save_button.pressed.emit()
	check_eq(PseudoLocale.raw_texts(menu), PackedStringArray(), "pause menu after saving")


func test_the_harness_finds_hard_coded_text() -> void:
	var box := VBoxContainer.new()
	var keyed := Label.new()
	keyed.text = "menu.quit"
	var raw := Button.new()
	raw.name = "Raw"
	raw.text = "Hello"
	box.add_child(keyed)
	box.add_child(raw)
	tree.root.add_child(box)
	check_eq(PseudoLocale.raw_texts(box), PackedStringArray(["Raw: Hello"]))
	box.free()
