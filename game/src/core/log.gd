extends Node
## Autoload "Log". Writes through the engine's print functions (which also
## reach the engine's file log in user://logs/) and keeps the newest lines
## in a ring buffer for the in-game console. Engine and script errors are
## captured into the same buffer.

signal line_added(line: String)

enum Level { DEBUG, INFO, WARN, ERROR }

const CAPACITY := 512
const LEVEL_TAGS: PackedStringArray = ["debug", "info", "warn", "error"]

var min_level: Level = Level.INFO
var _lines: PackedStringArray = []
var _next := 0
var _catcher := EngineErrors.new()


## Forwards engine errors into the buffer. Called from any thread.
class EngineErrors:
	extends Logger
	var pending: PackedStringArray = []
	var _lock := Mutex.new()

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
		var kind := "warn" if error_type == ERROR_TYPE_WARNING else "error"
		var text := rationale if rationale != "" else code
		_lock.lock()
		pending.append("[%s] engine: %s (%s:%d %s)" % [kind, text, file.get_file(), line, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func drain() -> PackedStringArray:
		_lock.lock()
		var out := pending.duplicate()
		pending.clear()
		_lock.unlock()
		return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_feature("dev") or OS.has_feature("editor"):
		min_level = Level.DEBUG
	OS.add_logger(_catcher)


func _process(_delta: float) -> void:
	for line in _catcher.drain():
		_store(line)


func _exit_tree() -> void:
	OS.remove_logger(_catcher)


func debug(source: String, message: String) -> void:
	_write(Level.DEBUG, source, message)


func info(source: String, message: String) -> void:
	_write(Level.INFO, source, message)


func warn(source: String, message: String) -> void:
	_write(Level.WARN, source, message)


func error(source: String, message: String) -> void:
	_write(Level.ERROR, source, message)


## Newest lines last; at most CAPACITY.
func recent() -> PackedStringArray:
	if _lines.size() < CAPACITY:
		return _lines.duplicate()
	return _lines.slice(_next) + _lines.slice(0, _next)


func _write(level: Level, source: String, message: String) -> void:
	if level < min_level:
		return
	var line := "[%s] %s: %s" % [LEVEL_TAGS[level], source, message]
	match level:
		Level.ERROR:
			printerr(line)
		Level.WARN:
			print_rich("[color=yellow]%s[/color]" % line)
		_:
			print(line)
	_store(line)


func _store(line: String) -> void:
	if _lines.size() < CAPACITY:
		_lines.append(line)
	else:
		_lines[_next] = line
		_next = (_next + 1) % CAPACITY
	line_added.emit(line)
