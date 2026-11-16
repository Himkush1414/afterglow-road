class_name TestCase
extends RefCounted
## Base class for tests run by run_tests.gd. A test file extends this class
## and defines methods named test_*; each may await. Failures are recorded,
## not raised, so one failing check does not hide the next.

var failures: PackedStringArray = []
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


func _prefix(message: String) -> String:
	return message + ": " if message != "" else ""
