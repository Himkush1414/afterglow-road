extends TestCase
## App and Log autoloads.


func test_log_keeps_the_newest_lines() -> void:
	for i in Log.CAPACITY + 10:
		Log.info("test", "line %d" % i)
	var lines := Log.recent()
	check_eq(lines.size(), Log.CAPACITY)
	check(lines[-1].ends_with("line %d" % (Log.CAPACITY + 9)), "newest line last")
	check(lines[0].ends_with("line 10"), "oldest kept line first")


func test_log_respects_the_minimum_level() -> void:
	var before := Log.min_level
	Log.min_level = Log.Level.WARN
	Log.info("test", "hidden")
	Log.warn("test", "shown")
	Log.min_level = before
	var lines := Log.recent()
	check(lines[-1].ends_with("test: shown"), "warn line stored")
	check(not lines[-2].ends_with("test: hidden"), "info line dropped")


func test_show_scene_reports_a_missing_scene() -> void:
	var err: Error = await App.show_scene("res://ui/does_not_exist.tscn")
	check_eq(err, ERR_FILE_NOT_FOUND)
