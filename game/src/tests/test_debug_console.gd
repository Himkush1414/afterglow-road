extends TestCase
## Debug console: present in dev builds, opens by intent, runs commands.

const DIR := "user://tests/console_saves"

var _c: DebugConsole


func before_each() -> void:
	SaveGame.saves_dir = DIR
	await App.start_game("slot_1", true)
	_c = Game.current.get_node("UI/DebugConsole")


func after_each() -> void:
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	for f in DirAccess.get_files_at(DIR + "/slot_1"):
		DirAccess.remove_absolute(DIR + "/slot_1/" + f)


func test_console_opens_by_intent_in_dev_builds() -> void:
	check(App.is_dev(), "tests run as a dev build")
	check(not _c.visible, "hidden at start")
	InputRouter.intent.emit(&"console", &"press")
	check(_c.visible, "open")
	InputRouter.intent.emit(&"console", &"press")
	check(not _c.visible, "closed")


func test_time_command_sets_the_clock_on_the_same_day() -> void:
	var clock := Game.clock_of()
	clock.set_now(2 * 1440.0 + 100.0)
	check_eq(_c.run("time 13:05"), "time set to day 3, 13:05")
	check_eq([clock.day(), clock.hour, clock.minute()], [3, 13, 5])
	for bad: String in ["time", "time 24:00", "time 7:60", "time ab:cd", "time 1:2:3"]:
		check_eq(_c.run(bad), "usage: time <hh:mm>", bad)
	check_eq([clock.hour, clock.minute()], [13, 5], "bad input changes nothing")


func test_other_commands_and_registry() -> void:
	check_eq(_c.run("nope 1"), "unknown command 'nope' (help lists them)")
	check_eq(_c.run("   "), "")
	check(_c.run("help").contains("time <hh:mm>"), "help lists usages")
	check(not _c.register("time", func(_a: PackedStringArray) -> String: return "", "x"), "taken")
	check(
		_c.register("echo", func(a: PackedStringArray) -> String: return " ".join(a), "echo"), "new"
	)
	check_eq(_c.run("echo a  b"), "a b", "words split on spaces")
	Game.clock_of().set_now(3000.0)
	check_eq(_c.run("save"), "saved slot_1")
	check_eq(int(SaveGame.read_meta("slot_1").day), 3, "save wrote the current state")
	check_eq(_c.run("load"), "loading slot_1")
	await App.scene_shown
	await tree.process_frame
	check_near(Game.clock_of().now_gmin, 3000.0, 1.0, "load restored the save")


func test_perf_command_toggles_the_overlay() -> void:
	var perf: PerfOverlay = Game.current.get_node("UI/PerfOverlay")
	check(not perf.visible, "hidden at start")
	check_eq(_c.run("perf"), "perf overlay on")
	check(perf.visible, "shown")
	for key: String in ["fps", "frame", "draw calls", "primitives", "video", "static", "pipelines"]:
		check(perf.text.contains(key), "shows %s" % key)
	PerfOverlay.record("probe", 1.25)
	await tree.create_timer(PerfOverlay.REFRESH_S + 0.1, true).timeout
	check(perf.text.contains("probe 1.25 ms"), "per-system time shown after a refresh")
	PerfOverlay.system_ms.erase("probe")
	check_eq(_c.run("perf"), "perf overlay off")
	check(not perf.visible, "hidden again")


func test_pipeline_monitors_are_counted_and_shown() -> void:
	var counts := PerfOverlay.pipeline_counts()
	check_eq(counts.keys(), ["canvas", "mesh", "surface", "draw", "specialization"])
	var overlay := PerfOverlay.new()
	var text := overlay.stats_text()
	overlay.free()
	for name: String in counts:
		var live := int(Performance.get_monitor(PerfOverlay.PIPELINES[name]))
		check(counts[name] >= 0 and counts[name] <= live, "%s matches the monitor" % name)
		check(text.contains("%s " % name), "%s shown" % name)
