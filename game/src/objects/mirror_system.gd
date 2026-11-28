class_name MirrorSystem
extends Node
## Keeps one mirror live (10 §3.1): each frame, after the player's camera
## and body, the nearest mirror within live_range_m whose front faces the
## eye and whose quad is at least partly inside the view frustum becomes
## live and follows the eye; every other mirror shows its dull surface.
## Mirror cameras use a cheap copy of the world environment (no SSAO, SSIL,
## volumetric fog, glow). Mirrors join by `add_mirror`.

## After PlayerBody (-20): the body is placed before the mirror renders.
const PROCESS_PRIORITY := -10

var errors: PackedStringArray = []
var view: Camera3D
var live: Mirror
var mirrors: Array[Mirror] = []

var _range_m := 0.0
var _env: Environment


## Follows `camera` (the player's view) with the "mirror" tuning group;
## `world_env`: the world's environment to copy for mirror cameras, or null.
func setup(camera: Camera3D, cfg: Dictionary, world_env: Environment) -> bool:
	errors.clear()
	if not cfg.has("live_range_m"):
		errors.append("mirror: missing live_range_m")
	if camera == null:
		errors.append("mirror system: no camera")
	if not errors.is_empty():
		return false
	view = camera
	_range_m = float(cfg.live_range_m)
	_env = cheap_environment(world_env) if world_env else null
	process_priority = PROCESS_PRIORITY
	return true


## A copy of `env` without the expensive effects (10 §3.2).
static func cheap_environment(env: Environment) -> Environment:
	var e := env.duplicate() as Environment
	e.ssao_enabled = false
	e.ssil_enabled = false
	e.volumetric_fog_enabled = false
	e.glow_enabled = false
	return e


func add_mirror(m: Mirror) -> void:
	if m in mirrors:
		return
	mirrors.append(m)
	if _env != null and m.camera != null:
		m.camera.environment = _env


func remove_mirror(m: Mirror) -> void:
	mirrors.erase(m)
	if live == m:
		live = null


func _process(delta: float) -> void:
	if view != null:
		update(delta)


## Picks the live mirror for this frame and updates its view.
func update(delta: float) -> void:
	var eye := view.global_position
	var best: Mirror = null
	var best_d := INF
	for m in mirrors:
		if not is_candidate(m, eye):
			continue
		var d := eye.distance_to(m.global_position)
		if d < best_d:
			best_d = d
			best = m
	if best != live:
		if live != null and is_instance_valid(live):
			live.set_live(false)
		live = best
		if live != null:
			live.set_live(true)
	if live != null:
		live.update_view(eye, delta)


## In range, intact or cracked, front toward `eye` and partly in view.
func is_candidate(m: Mirror, eye: Vector3) -> bool:
	if m.state == Mirror.State.SHATTERED or m.camera == null:
		return false
	if eye.distance_to(m.global_position) > _range_m or m.distance_to_eye(eye) <= 0.0:
		return false
	return quad_in_view(m)


## False only when all four quad corners lie outside one frustum plane.
func quad_in_view(m: Mirror) -> bool:
	var a := m.axes()
	var c := m.global_position
	var hr := a[1] * m.width_m * 0.5
	var hu := a[2] * m.height_m * 0.5
	var corners: Array[Vector3] = [c + hr + hu, c - hr + hu, c + hr - hu, c - hr - hu]
	for plane: Plane in view.get_frustum():
		var outside := true
		for p in corners:
			if not plane.is_point_over(p):
				outside = false
				break
		if outside:
			return false
	return true
