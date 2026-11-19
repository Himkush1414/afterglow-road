extends TestCase
## T-18-9 (first part): the loading screen stays until every condition
## holds; each one withheld in turn by the test hook keeps it up.

var _ls: LoadingScreen


func before_each() -> void:
	_ls = App.loading


func after_each() -> void:
	for name: String in ["scenes", "pipelines", "probe"]:
		_ls.hold_back(name, false)
	if _ls.visible:
		await _ls.finished


func test_each_condition_withheld_keeps_the_screen_up() -> void:
	for withheld: String in ["scenes", "pipelines", "probe"]:
		_ls.begin(PackedStringArray([App.TITLE_SCENE]))
		var probe_ready := [false]
		_ls.add_condition("probe", func() -> bool: return probe_ready[0])
		if withheld != "probe":
			probe_ready[0] = true
		_ls.hold_back(withheld, true)
		for i in 40:
			await tree.process_frame
		check(_ls.visible and _ls.root.modulate.a == 1.0, "%s withheld: still up" % withheld)
		check_eq(_ls.pending(), PackedStringArray([withheld]), "only %s pending" % withheld)
		_ls.hold_back(withheld, false)
		probe_ready[0] = true
		var t0 := Time.get_ticks_msec()
		await _ls.finished
		check(not _ls.visible, "%s released: gone" % withheld)
		check(Time.get_ticks_msec() - t0 >= LoadingScreen.FADE_S * 900, "faded, not cut")


func test_pipelines_must_be_quiet_for_the_stable_frames() -> void:
	_ls.begin(PackedStringArray())
	await tree.process_frame
	check(_ls.pending().has("pipelines"), "not quiet yet after one frame")
	await _ls.finished
	check(not _ls.visible, "quiet: done")


func test_starting_a_game_goes_through_the_loading_screen() -> void:
	SaveGame.saves_dir = "user://tests/loading_saves"
	var shown := [false]
	var watch := func(_p: String) -> void: shown[0] = _ls.visible
	App.scene_shown.connect(watch)
	await App.start_game("slot_1", true)
	App.scene_shown.disconnect(watch)
	check(shown[0], "loading screen up when the game scene appeared")
	await _ls.finished
	check_eq(App.current_path, Game.SCENE)
	check_eq(PseudoLocale.raw_texts(_ls.root).size(), 0, "keyed text only")
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	for f in DirAccess.get_files_at("user://tests/loading_saves/slot_1"):
		DirAccess.remove_absolute("user://tests/loading_saves/slot_1/" + f)
