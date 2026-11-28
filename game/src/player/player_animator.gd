class_name PlayerAnimator
extends AnimationTree
## Whole-body locomotion of the player rig (10 §5, layer 1): a state machine
## of stand and crouch blend spaces (sideways speed x, forward speed y, in
## m/s, with the clips placed at the motor's own gait speeds from the
## "movement" tuning group) and the jump one-shots (start, air, land). Each
## frame it reads the motor's velocity in the view's frame, its stance and
## its state; the motor's jumped and landed signals start the jump clips.
## Clip names: the player clip library's (idle, walk_f, walk_b, walk_l, ...).

const STAND := &"stand"
const CROUCH := &"crouch"
const JUMP_START := &"jump_start"
const AIR := &"air"
const JUMP_LAND := &"jump_land"
const KEYS: Array[String] = [
	"walk_ms", "jog_ms", "sprint_ms", "crouch_ms", "back_mult", "strafe_mult", "anim_blend_s"
]

var errors: PackedStringArray = []
var motor: PlayerMotor

var _playback: AnimationNodeStateMachinePlayback
var _jumping := false
var _landing := false


## Animates the rig under `rig_root` (holding %GeneralSkeleton) with the
## clips of `library`, following `body`; false with `errors`.
func setup(body: PlayerMotor, library: AnimationLibrary, rig_root: Node, cfg: Dictionary) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("movement: missing %s" % key)
	for clip: String in clip_names():
		if library == null or not library.has_animation(clip):
			errors.append("clip library: missing %s" % clip)
	if not errors.is_empty():
		return false
	if motor != null and motor != body:
		motor.jumped.disconnect(_on_jumped)
		motor.landed.disconnect(_on_landed)
	motor = body
	if has_animation_library(""):
		remove_animation_library("")
	add_animation_library("", library)
	root_node = get_path_to(rig_root)
	tree_root = _build(cfg)
	active = true
	_playback = get("parameters/playback")
	_playback.start(STAND)
	if not motor.jumped.is_connected(_on_jumped):
		motor.jumped.connect(_on_jumped)
	if not motor.landed.is_connected(_on_landed):
		motor.landed.connect(_on_landed)
	return true


func _on_jumped() -> void:
	_jumping = true


func _on_landed(_impact_ms: float, _damage_hp: float) -> void:
	_landing = true


func _process(_delta: float) -> void:
	if motor != null and callback_mode_process != ANIMATION_CALLBACK_MODE_PROCESS_MANUAL:
		update_state()


## Sets the blend positions and travels the state machine from the motor.
func update_state() -> void:
	var v := motor.velocity.rotated(Vector3.UP, -motor.yaw)
	var blend := Vector2(v.x, -v.z)  # x: right of the view, y: forward
	set("parameters/%s/blend_position" % STAND, blend)
	set("parameters/%s/blend_position" % CROUCH, blend)
	var ground := CROUCH if motor.crouched else STAND
	var current := _playback.get_current_node()
	if _jumping:
		_jumping = false
		_playback.travel(JUMP_START)
	elif _landing:
		_landing = false
		if current == AIR or current == JUMP_START:
			_playback.travel(JUMP_LAND)
	elif motor.state == PlayerMotor.State.AIRBORNE and current != JUMP_START:
		if current != AIR:
			_playback.travel(AIR)
	elif motor.state != PlayerMotor.State.AIRBORNE and current != JUMP_LAND and current != ground:
		_playback.travel(ground)


## The state now played (for checks and the debug overlay).
func current_state() -> StringName:
	return _playback.get_current_node() if _playback else &""


## Every clip the animator plays.
static func clip_names() -> Array[String]:
	var out: Array[String] = [
		"idle", "sprint", "crouch_idle", "jump_start", "jump_air", "jump_land"
	]
	for d: String in ["f", "b", "l", "r"]:
		out.append_array(["walk_" + d, "jog_" + d, "crouch_walk_" + d])
	return out


func _build(cfg: Dictionary) -> AnimationNodeStateMachine:
	var walk := float(cfg.walk_ms)
	var jog := float(cfg.jog_ms)
	var back := float(cfg.back_mult)
	var side := float(cfg.strafe_mult)
	var crouch := float(cfg.crouch_ms)
	var stand := _space(
		{
			"idle": Vector2.ZERO,
			"walk_f": Vector2(0, walk),
			"jog_f": Vector2(0, jog),
			"sprint": Vector2(0, float(cfg.sprint_ms)),
			"walk_b": Vector2(0, -walk * back),
			"jog_b": Vector2(0, -jog * back),
			"walk_l": Vector2(-walk * side, 0),
			"jog_l": Vector2(-jog * side, 0),
			"walk_r": Vector2(walk * side, 0),
			"jog_r": Vector2(jog * side, 0),
		}
	)
	var low := _space(
		{
			"crouch_idle": Vector2.ZERO,
			"crouch_walk_f": Vector2(0, crouch),
			"crouch_walk_b": Vector2(0, -crouch * back),
			"crouch_walk_l": Vector2(-crouch * side, 0),
			"crouch_walk_r": Vector2(crouch * side, 0),
		}
	)
	var sm := AnimationNodeStateMachine.new()
	sm.add_node(STAND, stand)
	sm.add_node(CROUCH, low)
	sm.add_node(JUMP_START, _clip("jump_start"))
	sm.add_node(AIR, _clip("jump_air"))
	sm.add_node(JUMP_LAND, _clip("jump_land"))
	var blend := float(cfg.anim_blend_s)
	for pair: Array in [
		[STAND, CROUCH],
		[CROUCH, STAND],
		[STAND, JUMP_START],
		[CROUCH, JUMP_START],
		[STAND, AIR],
		[CROUCH, AIR],
		[JUMP_START, JUMP_LAND],
		[AIR, JUMP_LAND],
		[JUMP_LAND, CROUCH],
	]:
		sm.add_transition(pair[0], pair[1], _transition(blend, false))
	sm.add_transition(JUMP_START, AIR, _transition(blend, true))
	sm.add_transition(JUMP_LAND, STAND, _transition(blend, true))
	return sm


func _space(points: Dictionary) -> AnimationNodeBlendSpace2D:
	var space := AnimationNodeBlendSpace2D.new()
	var reach := 0.0
	for p: Vector2 in points.values():
		reach = maxf(reach, maxf(absf(p.x), absf(p.y)))
	space.min_space = Vector2(-reach, -reach)
	space.max_space = Vector2(reach, reach)
	for clip: String in points:
		space.add_blend_point(_clip(clip), points[clip])
	return space


func _clip(name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = name
	return node


## A transition with cross-fade `blend`; `at_end`: taken by itself when the
## clip ends.
func _transition(blend: float, at_end: bool) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.xfade_time = blend
	if at_end:
		t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
		t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	return t
