extends TestCase
## Checks the test helpers themselves.


func test_check_records_only_failures() -> void:
	var probe := TestCase.new()
	probe.check(true, "a")
	probe.check(false, "b")
	check_eq(probe.failures, PackedStringArray(["b"]))


func test_check_eq_compares_numbers_by_value() -> void:
	var probe := TestCase.new()
	check(probe.check_eq(2, 2.0), "int and float of equal value")
	check(not probe.check_eq("2", 2), "string and number differ")
	check_eq(probe.failures.size(), 1)


func test_check_near_uses_tolerance() -> void:
	var probe := TestCase.new()
	check(probe.check_near(1.0, 1.05, 0.1))
	check(not probe.check_near(1.0, 1.2, 0.1))


func test_awaiting_a_frame_works() -> void:
	var frame := tree.get_frame()
	await tree.process_frame
	check(tree.get_frame() > frame, "a frame passed")
