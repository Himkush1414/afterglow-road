extends SceneTree
## Headless test runner (decision D-14).
##   godot --headless -s res://src/tests/run_tests.gd [-- --filter <text>]
## Runs every test_*.gd under res://src/tests/ and, when present,
## res://content/tests/. Prints one line per test and exits 1 on failure.

const ROOTS: PackedStringArray = ["res://src/tests", "res://content/tests"]

var _errors := ErrorCatcher.new()


## Collects engine and script errors so a test that errors cannot pass.
class ErrorCatcher:
	extends Logger
	var _lock := Mutex.new()
	var _seen: PackedStringArray = []

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if rationale != "" else code
		_lock.lock()
		_seen.append("%s (%s:%d in %s)" % [text, file.get_file(), line, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_seen.clear()
		_lock.unlock()
		return out


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	OS.add_logger(_errors)
	var filter := _arg_value("--filter")
	var files := PackedStringArray()
	for root in ROOTS:
		if DirAccess.dir_exists_absolute(root):
			_collect(root, files)
	files.sort()
	var passed := 0
	var failed := 0
	var started := Time.get_ticks_msec()
	for path in files:
		var script: Script = load(path)
		if script == null or not script.can_instantiate():
			print("FAIL  %s (script did not load)" % path)
			failed += 1
			continue
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if (
				not name.begins_with("test_")
				or (filter != "" and not (path + ":" + name).contains(filter))
			):
				continue
			var case: TestCase = script.new()
			case.tree = self
			var t0 := Time.get_ticks_usec()
			_errors.take()
			# Hooks may await (scene changes); each finishes before the next step.
			await Callable(case, "before_each").call()
			await Callable(case, name).call()
			await Callable(case, "after_each").call()
			case.settle_engine_errors(_errors.take())
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			var label := "%s:%s" % [path.get_file().get_basename(), name]
			if case.failures.is_empty():
				passed += 1
				print("PASS  %s (%.1f ms)" % [label, ms])
			else:
				failed += 1
				print("FAIL  %s" % label)
				for f in case.failures:
					print("      - " + f)
	var total_s := (Time.get_ticks_msec() - started) / 1000.0
	print("tests: %d passed, %d failed, %.1f s" % [passed, failed, total_s])
	quit(1 if failed > 0 or passed == 0 else 0)


func _collect(dir: String, out: PackedStringArray) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(sub), out)
	for file in DirAccess.get_files_at(dir):
		if file.begins_with("test_") and file.ends_with(".gd") and file != "test_case.gd":
			out.append(dir.path_join(file))


func _arg_value(key: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""
