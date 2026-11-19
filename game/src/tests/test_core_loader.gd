extends TestCase
## Loader: batches load on worker threads, report progress and failures.


func test_a_batch_loads_and_reports_progress() -> void:
	var l := Loader.new()
	check(l.is_done() and l.progress() == 1.0, "empty batch is done")
	var paths := PackedStringArray([Game.SCENE, "res://ui/pause_menu.tscn", App.TITLE_SCENE])
	l.request(paths)
	l.request(paths)  # requesting again changes nothing
	var frames := 0
	var last := -1.0
	var monotonic := true
	while not l.is_done() and frames < 600:
		l.poll()
		monotonic = monotonic and l.progress() >= last
		last = l.progress()
		await tree.process_frame
		frames += 1
	check(l.is_done(), "done within 600 frames (took %d)" % frames)
	check(monotonic, "progress never goes back")
	check_eq(l.progress(), 1.0)
	check_eq(l.failed, PackedStringArray())
	for p in paths:
		check(l.take(p) is PackedScene, "%s loaded" % p)


func test_missing_paths_are_reported_not_waited_for() -> void:
	var l := Loader.new()
	l.request(PackedStringArray(["res://no/such/scene.tscn", App.TITLE_SCENE]))
	while not l.is_done():
		l.poll()
		await tree.process_frame
	check_eq(l.failed, PackedStringArray(["res://no/such/scene.tscn"]))
	check(l.take("res://no/such/scene.tscn") == null, "nothing for a missing path")
	check(l.take(App.TITLE_SCENE) is PackedScene, "the rest still loads")
