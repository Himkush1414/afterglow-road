class_name TestCase
extends RefCounted
## Base class for tests run by run_tests.gd. A test file extends this class
## and defines methods named test_*; each may await. Failures are recorded,
## not raised, so one failing check does not hide the next.

var failures: PackedStringArray = []
## Fragments of engine errors this test causes on purpose (expect_engine_error).
var expected_errors: PackedStringArray = []
## Set by the runner: the SceneTree, for tests that need nodes or frames.
var tree: SceneTree


## Called before each test method when overridden.
func before_each() -> void:
	pass


## Called after each test method when overridden, even if checks failed.
func after_each() -> void:
	pass


func check(condition: bool, message: String = "check failed") -> bool:
	if not condition:
		failures.append(message)
	return condition


func check_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	var numbers := [TYPE_INT, TYPE_FLOAT]
	var ok: bool
	if typeof(actual) in numbers and typeof(expected) in numbers:
		ok = float(actual) == float(expected)
	else:
		ok = typeof(actual) == typeof(expected) and actual == expected
	if not ok:
		var shown := [_prefix(message), var_to_str(expected), var_to_str(actual)]
		failures.append("%sexpected %s, got %s" % shown)
	return ok


func check_near(actual: float, expected: float, tolerance: float, message: String = "") -> bool:
	var ok := absf(actual - expected) <= tolerance
	if not ok:
		var shown := [_prefix(message), str(expected), str(tolerance), str(actual)]
		failures.append("%sexpected %s ± %s, got %s" % shown)
	return ok


func fail(message: String) -> void:
	failures.append(message)


## Declares that the test will cause one engine error containing fragment;
## the test fails if it does not happen.
func expect_engine_error(fragment: String) -> void:
	expected_errors.append(fragment)


## Called by the runner with the engine errors seen during the test: each
## expected fragment consumes one matching error; the rest are failures.
func settle_engine_errors(errors: PackedStringArray) -> void:
	var left := errors.duplicate()
	for fragment in expected_errors:
		var hit := -1
		for i in left.size():
			if left[i].contains(fragment):
				hit = i
				break
		if hit < 0:
			fail("expected engine error not raised: " + fragment)
		else:
			left.remove_at(hit)
	for e in left:
		fail("engine error: " + e)


func _prefix(message: String) -> String:
	return message + ": " if message != "" else ""
