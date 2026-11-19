class_name LoadingScreen
extends CanvasLayer
## Loading screen (18 §2): a still background, a thin progress bar and one
## line of text. It stays until every condition holds: the requested scenes
## are loaded, no pipeline compiled for STABLE_FRAMES frames, and each
## condition systems add with `add_condition`. Then it fades out.

signal scenes_ready
signal finished

const STABLE_FRAMES := 10
const FADE_S := 0.5

var loader := Loader.new()
## name -> Callable() -> bool
var _conditions := {}
## Test hook: names forced to "not yet" (T-18-9).
var _held_back := {}
var _stable := 0
var _last_counts := {}
var _scenes_announced := false
var _fading := false
var _tween: Tween

@onready var root: Control = $Root
@onready var bar: ProgressBar = %Bar


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	hide()


func _exit_tree() -> void:
	if _tween:
		_tween.kill()
		_tween = null


## Shows the screen and starts loading `scenes`; resets the conditions to
## the built-in ones.
func begin(scenes: PackedStringArray) -> void:
	if _tween:
		_tween.kill()  # a new load while the last one fades out
		_tween = null
	loader = Loader.new()
	loader.request(scenes)
	_conditions = {
		"scenes": func() -> bool: return loader.is_done(),
		"pipelines": func() -> bool: return _stable >= STABLE_FRAMES,
	}
	_stable = 0
	_last_counts = PerfOverlay.pipeline_counts()
	_scenes_announced = false
	_fading = false
	root.modulate.a = 1.0
	bar.value = 0.0
	show()


## Adds a condition the screen waits for (systems call this after begin).
func add_condition(name: String, holds: Callable) -> void:
	_conditions[name] = holds


func hold_back(name: String, held: bool) -> void:
	if held:
		_held_back[name] = true
	else:
		_held_back.erase(name)


## Names of the conditions that do not hold yet.
func pending() -> PackedStringArray:
	var out: PackedStringArray = []
	for name: String in _conditions:
		if _held_back.has(name) or not (_conditions[name] as Callable).call():
			out.append(name)
	return out


func _process(_delta: float) -> void:
	if not visible or _fading:
		return
	loader.poll()
	bar.value = loader.progress() * 100.0
	if loader.is_done() and not _scenes_announced:
		_scenes_announced = true
		scenes_ready.emit()
	var counts := PerfOverlay.pipeline_counts()
	_stable = _stable + 1 if counts == _last_counts else 0
	_last_counts = counts
	if pending().is_empty():
		_fade_out()


func _fade_out() -> void:
	_fading = true
	_tween = create_tween()
	_tween.tween_property(root, "modulate:a", 0.0, FADE_S)
	_tween.finished.connect(_on_faded)


func _on_faded() -> void:
	_tween = null
	_conditions.clear()  # conditions belong to one load
	loader = Loader.new()
	hide()
	finished.emit()
