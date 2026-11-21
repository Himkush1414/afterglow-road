class_name Region
extends Node3D
## One 512 m region of the world (03 §10): holds the region's objects while
## it is loaded. Loading happens in steps the Streamer spreads over frames;
## on load the region applies its saved change set ("delta"), and delta()
## returns what must be saved. Regions have no content yet (later steps
## add buildings, props, nodes and items as load steps and delta entries).

enum State { UNLOADED, LOADING, ACTIVE, UNLOADING }

var coord := Vector2i.ZERO
var state := State.UNLOADED
var _delta := {}
var _steps: Array[Callable] = []


func _init(region: Vector2i = Vector2i.ZERO) -> void:
	coord = region
	name = "Region_%d_%d" % [region.x, region.y]


## Starts loading with the saved `delta`; the work is done by load_step().
func begin_load(delta: Dictionary) -> void:
	state = State.LOADING
	_delta = delta.duplicate(true)
	_steps = [_apply_delta]


## Runs the next load step. Returns true when the region is fully loaded.
func load_step() -> bool:
	if not _steps.is_empty():
		var step: Callable = _steps.pop_front()
		step.call()
	if _steps.is_empty():
		state = State.ACTIVE
	return state == State.ACTIVE


## The change set to save for this region (empty while nothing changed).
func delta() -> Dictionary:
	return _delta.duplicate(true)


func _apply_delta() -> void:
	pass
