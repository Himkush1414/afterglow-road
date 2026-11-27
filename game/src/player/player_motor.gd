class_name PlayerMotor
extends CharacterBody3D
## The player's physics body (10 §4): a capsule that never rotates, moved
## by `move_and_slide` from intents its owner sets before each physics tick
## (it never reads Input). Ground movement with gaits and direction factors,
## acceleration, slopes (walkable, sliding, wall), step-up by `test_move`
## (10 §4.2) and crouching. Numbers come from the "movement" tuning group.
##
## A capsule meets a stair edge with its rounded bottom, so the step-up
## measures the tread with a ray beyond the capsule's front, lifts the body
## by the rise and carries it level until its axis is over the tread; going
## down, a walkable surface within the step height under the axis counts
## as ground (Q-120).

## Raised when a step-up moved the body up by `rise_m`.
signal stepped(rise_m: float)

## Shortest horizontal probe of the step-up test, metres (10 §4.2).
const STEP_PROBE_MIN_M := 0.05
## A step must rise at least this much above the feet, metres.
const STEP_RISE_MIN_M := 0.02
## The step-up test looks this much below the step height, metres.
const STEP_DOWN_EXTRA_M := 0.05
## Pushes a sliding body into its slope so the contact holds, m/s.
const SLIDE_PRESS_MS := 0.5
## A step lifts the body this much over the measured rise, metres.
const STEP_LIFT_M := 0.005
const KEYS: Array[String] = [
	"capsule_radius_m",
	"stand_height_m",
	"crouch_height_m",
	"walk_ms",
	"jog_ms",
	"sprint_ms",
	"crouch_ms",
	"back_mult",
	"strafe_mult",
	"accel_ms2",
	"decel_ms2",
	"air_accel_ms2",
	"gravity_ms2",
	"step_m",
	"walk_slope_deg",
	"wall_slope_deg",
	"slide_ms2",
	"sprint_cone_deg",
	"step_return_ms",
]

var errors: PackedStringArray = []
## Intents for the next tick, set by the owner: move as from
## InputRouter.move_vector() (x right, y back; length up to 1), look yaw in
## radians (0 faces −Z), and the gait and stance wishes.
var move := Vector2.ZERO
var yaw := 0.0
var sprint := false
var walk := false
var crouch := false
## State, read by camera, body and tests.
var crouched := false
var sliding := false
## Height the recent steps added that the view has not caught up with yet:
## camera and rig subtract it; it returns to 0 at step_return_ms (10 §4.2).
var step_offset_m := 0.0

var _cfg := {}
var _shape := CapsuleShape3D.new()
var _collider := CollisionShape3D.new()
var _slope_normal := Vector3.ZERO
## Horizontal distance still to carry the body level after a step-up.
var _carry_m := 0.0
var _carry_dir := Vector3.ZERO


func _init() -> void:
	_collider.shape = _shape
	add_child(_collider)


## Takes the "movement" tuning group; false with `errors` when a key is
## missing.
func setup(cfg: Dictionary) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("movement: missing %s" % key)
	if not errors.is_empty():
		return false
	_cfg = cfg
	motion_mode = MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(float(cfg.walk_slope_deg))
	floor_snap_length = float(cfg.step_m)
	floor_constant_speed = true
	floor_stop_on_slope = true
	_shape.radius = float(cfg.capsule_radius_m)
	crouched = false
	_set_height(float(cfg.stand_height_m))
	return true


## Grounded in the sense of the movement states (10 §4.3): on the floor,
## being carried onto a step, or with a walkable surface within the step
## height under the body's axis.
func is_grounded() -> bool:
	return is_on_floor() or _carry_m > 0.0 or _ground_below() >= 0.0


## Capsule height now in use, metres.
func height_m() -> float:
	return _shape.height


func _physics_process(delta: float) -> void:
	if not _cfg.is_empty():
		tick(delta)


## One physics tick of `delta` seconds.
func tick(delta: float) -> void:
	_update_stance()
	var target := target_velocity()
	var h := Vector3(velocity.x, 0.0, velocity.z)
	var on_floor := is_on_floor()
	var rate := float(_cfg.air_accel_ms2)
	if is_grounded():
		rate = float(_cfg.accel_ms2 if target != Vector3.ZERO else _cfg.decel_ms2)
	h = h.move_toward(target, rate * delta)
	sliding = not on_floor and _carry_m <= 0.0 and _slope_normal != Vector3.ZERO
	if sliding:
		velocity = _slide_velocity(target, delta)
	else:
		velocity = Vector3(h.x, velocity.y, h.z)
		if not on_floor and _carry_m <= 0.0:
			velocity.y -= float(_cfg.gravity_ms2) * delta
	if on_floor or _carry_m > 0.0:
		_step(h * delta)
	if _carry_m > 0.0:
		_carry_level(delta)
	else:
		var before := velocity
		var at := global_position
		move_and_slide()
		# A riser met during the slide: step from there with the speed it had
		# and carry on for the rest of the tick's motion.
		var flat := Vector3(before.x, 0.0, before.z)
		if is_on_floor() and is_on_wall() and _step(flat * delta):
			velocity = flat
			var moved := Vector2(global_position.x - at.x, global_position.z - at.z).length()
			var left := flat.length() * delta - moved
			if left > 0.0:
				_carry_level(left / flat.length())
	_slope_normal = _sliding_normal()
	step_offset_m = move_toward(step_offset_m, 0.0, float(_cfg.step_return_ms) * delta)


## Horizontal velocity the intents ask for (world space): gait speed, the
## backward and strafe factors, turned by yaw.
func target_velocity() -> Vector3:
	var m := move.limit_length(1.0)
	if m == Vector2.ZERO:
		return Vector3.ZERO
	var speed := float(_cfg.jog_ms)
	if crouched:
		speed = float(_cfg.crouch_ms)
	elif sprint and _sprint_allowed(m):
		speed = float(_cfg.sprint_ms)
	elif walk:
		speed = float(_cfg.walk_ms)
	var back := float(_cfg.back_mult) if m.y > 0.0 else 1.0
	var local := Vector3(m.x * float(_cfg.strafe_mult), 0.0, m.y * back) * speed
	return local.rotated(Vector3.UP, yaw)


## Whether the capsule has room to stand up from crouching.
func can_stand() -> bool:
	var rise := float(_cfg.stand_height_m) - _shape.height
	return rise <= 0.0 or not test_move(global_transform, Vector3.UP * rise)


func _sprint_allowed(m: Vector2) -> bool:
	var ahead := Vector2(0.0, -1.0).angle_to(m.normalized())
	return absf(ahead) <= deg_to_rad(float(_cfg.sprint_cone_deg))


func _update_stance() -> void:
	if crouch and not crouched:
		crouched = true
		_set_height(float(_cfg.crouch_height_m))
	elif not crouch and crouched and can_stand():
		crouched = false
		_set_height(float(_cfg.stand_height_m))


func _set_height(h: float) -> void:
	_shape.height = h
	_collider.position = Vector3(0.0, h * 0.5, 0.0)


## Tries a step-up for motion `m`; true (offset and signal done) when it
## stepped.
func _step(m: Vector3) -> bool:
	var rise := _try_step(m)
	if rise <= 0.0:
		return false
	step_offset_m += rise + STEP_LIFT_M
	stepped.emit(rise)
	return true


## Step-up (10 §4.2) for the horizontal motion `m` of this tick: returns the
## rise when the body was moved onto a step, else 0.
func _try_step(m: Vector3) -> float:
	if m.length() < 1e-5:
		return 0.0
	var probe := m.normalized() * maxf(m.length(), STEP_PROBE_MIN_M)
	var t := global_transform
	if not test_move(t, probe):
		return 0.0
	var step := float(_cfg.step_m)
	var up := Vector3.UP * step
	if test_move(t, up):
		return 0.0
	if test_move(t.translated(up), probe):
		return 0.0
	var dir := probe.normalized()
	var ahead := _shape.radius + STEP_PROBE_MIN_M
	var hit := _ray_down(t.origin + up + dir * ahead, step + STEP_DOWN_EXTRA_M)
	var rise := -1.0
	if not hit.is_empty() and (hit.normal as Vector3).angle_to(Vector3.UP) <= floor_max_angle:
		rise = (hit.position as Vector3).y - t.origin.y
	if rise < STEP_RISE_MIN_M or rise > step:
		return 0.0
	global_position = t.origin + Vector3.UP * (rise + STEP_LIFT_M)
	velocity.y = 0.0
	_carry_m = ahead
	_carry_dir = dir
	return rise


## Moves the body level (no gravity, no floor snap) after a step-up until
## its axis is over the tread; ends early when the motion turns away.
func _carry_level(delta: float) -> void:
	var along := Vector3(velocity.x, 0.0, velocity.z).dot(_carry_dir)
	if along <= 0.0:
		_carry_m = 0.0
		move_and_slide()
		return
	velocity.y = 0.0
	var snap := floor_snap_length
	floor_snap_length = 0.0
	move_and_slide()
	floor_snap_length = snap
	_carry_m = maxf(0.0, _carry_m - along * delta)


## The hit of a ray from `from` straight down over `length` metres (not this
## body): {position, normal, ...}, or empty.
func _ray_down(from: Vector3, length: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * length)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)


## Depth (metres, 0 or more) of the nearest walkable surface within the
## step height under the capsule's footprint (its axis and four rim
## points), or -1.
func _ground_below() -> float:
	if _cfg.is_empty() or not is_inside_tree():
		return -1.0
	var best := -1.0
	var rim := _shape.radius * 0.9
	for off: Vector3 in [
		Vector3.ZERO,
		Vector3(rim, 0, 0),
		Vector3(-rim, 0, 0),
		Vector3(0, 0, rim),
		Vector3(0, 0, -rim)
	]:
		var from := global_position + off + Vector3.UP * STEP_RISE_MIN_M
		var hit := _ray_down(from, float(_cfg.step_m) + STEP_DOWN_EXTRA_M)
		if hit.is_empty() or (hit.normal as Vector3).angle_to(Vector3.UP) > floor_max_angle:
			continue
		var depth := maxf(0.0, global_position.y - (hit.position as Vector3).y)
		best = depth if best < 0.0 else minf(best, depth)
	return best


## Velocity on a slope steeper than walkable but not a wall: down the slope,
## gaining slide_ms2; the intents only steer along the contour.
func _slide_velocity(target: Vector3, delta: float) -> Vector3:
	var n := _slope_normal
	var down := (Vector3.DOWN - n * n.dot(Vector3.DOWN)).normalized()
	var along := maxf(velocity.dot(down), 0.0) + float(_cfg.slide_ms2) * delta
	var contour := n.cross(down).normalized()
	return down * along + contour * target.dot(contour) - n * SLIDE_PRESS_MS


## The normal of the last slide's contact with a slope between walkable and
## wall, or zero.
func _sliding_normal() -> Vector3:
	if is_on_floor():
		return Vector3.ZERO
	var wall := deg_to_rad(float(_cfg.wall_slope_deg))
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		var a := n.angle_to(Vector3.UP)
		if a > floor_max_angle and a <= wall:
			return n
	return Vector3.ZERO
