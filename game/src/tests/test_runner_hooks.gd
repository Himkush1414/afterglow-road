extends TestCase
## The runner awaits hooks: an awaiting before_each ends before the test.
## (Own file, so the awaited frame does not touch the frame self-test.)

var _hook_done := false


func before_each() -> void:
	await tree.process_frame
	_hook_done = true


func test_an_awaiting_hook_finishes_before_the_test() -> void:
	check(_hook_done, "before_each ran to its end first")
