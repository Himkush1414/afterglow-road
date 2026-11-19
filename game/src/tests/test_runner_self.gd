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


func test_expected_engine_errors_are_matched_once() -> void:
	var probe := TestCase.new()
	probe.expect_engine_error("disk full")
	probe.settle_engine_errors(PackedStringArray(["write: disk full (a.gd:1)", "other (b.gd:2)"]))
	check_eq(probe.failures, PackedStringArray(["engine error: other (b.gd:2)"]))


func test_a_missing_expected_engine_error_fails() -> void:
	var probe := TestCase.new()
	probe.expect_engine_error("disk full")
	probe.settle_engine_errors(PackedStringArray())
	check_eq(probe.failures, PackedStringArray(["expected engine error not raised: disk full"]))


func test_an_expected_engine_error_from_the_engine_passes() -> void:
	expect_engine_error("runner self-test probe")
	push_error("runner self-test probe")
