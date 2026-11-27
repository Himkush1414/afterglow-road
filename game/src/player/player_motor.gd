class_name PlayerMotor
extends CharacterBody3D
## The player's physics body (10 §4): a capsule that never rotates, moved
## by `move_and_slide` from intents its owner sets before each physics tick
## (it never reads Input). Ground movement with gaits and direction factors,
## acceleration, slopes (walkable, sliding, wall), step-up by `test_move`
## (10 §4.2), crouching, jumping with coyote time and an input buffer, the
## fall-damage hook and mantling. Numbers come from the "movement" tuning
## group.
##
## A capsule meets a stair edge with its rounded bottom, so the step-up
## measures the tread with a ray beyond the capsule's front, lifts the body
## by the rise and carries it level until its axis is over the tread; going
## down, a walkable surface within the step height under the axis counts
## as ground (Q-120).

## Raised when a step-up moved the body up by `rise_m`.
signal stepped(rise_m: float)
## Raised when the body leaves the ground by a jump.
signal jumped
## Raised on touching the floor after being airborne: the downward speed and
## the fall damage it causes (10 §4.1; Vitals applies it).
signal landed(impact_ms: float, damage_hp: float)
## Raised when a mantle starts, with the height climbed.
signal mantle_started(rise_m: float)

enum State { GROUNDED, AIRBORNE, MANTLING }

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
	"jump_ms",
	"coyote_s",
	"jump_buffer_s",
	"fall_safe_ms",
	"fall_hp_per_ms",
	"mantle_min_m",
	"mantle_max_m",
	"mantle_depth_m",
	"mantle_room_m",
	"mantle_reach_m",
	"mantle_s",
]
## Share of a mantle's time spent rising; the rest moves onto the top.
const MANTLE_RISE_SHARE := 0.6

var errors: PackedStringArray = []
## Intents for the next tick, set by the owner: move as from
## InputRouter.move_vector() (x right, y back; length up to 1), look yaw in
## radians (0 faces −Z), and the gait and stance wishes.
var move := Vector2.ZERO
var yaw := 0.0
var sprint := false
var walk := false
var crouch := false
## Jump held (press_jump() marks the press): holding it while airborne
## mantles onto an obstacle in reach (10 §4.2).
var jump_held := false
## Cleared by stamina and encumbrance rules (P6-10) to refuse jumps.
var jump_allowed := true
var state := State.GROUNDED
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
var _jump_buffer_s := 0.0
## True from a jump until the body stops rising: ground below does not count.
var _rising := false
## Highest feet height since the body last stood on the floor: the impact
## speed of a landing is the free-fall speed from there.
var _air_top_y := 0.0
var _coyote_s := 0.0
## The mantle under way: [elapsed s, start, raised, landing].
var _mantle: Array = []


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


## Asks for a jump: done within jump_buffer_s once the body may jump; a
## mantle in reach is taken instead.
func press_jump() -> void:
	_jump_buffer_s = float(_cfg.get("jump_buffer_s", 0.0))


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
	if state == State.MANTLING:
		_mantle_tick(delta)
		return
	_update_stance()
	_jump_buffer_s = maxf(0.0, _jump_buffer_s - delta)
	var grounded := is_grounded()
	_coyote_s = float(_cfg.coyote_s) if grounded else maxf(0.0, _coyote_s - delta)
	if (_jump_buffer_s > 0.0 or (jump_held and not grounded)) and _start_mantle():
		return
	var jump := (
		_jump_buffer_s > 0.0 and (grounded or _coyote_s > 0.0) and not crouched and jump_allowed
	)
	if jump:
		_jump_buffer_s = 0.0
		_coyote_s = 0.0
		_carry_m = 0.0
		_rising = true
	var target := target_velocity()
	var h := Vector3(velocity.x, 0.0, velocity.z)
	var on_floor := is_on_floor()
	var rate := float(_cfg.air_accel_ms2)
	if grounded and not jump:
		rate = float(_cfg.accel_ms2 if target != Vector3.ZERO else _cfg.decel_ms2)
	h = h.move_toward(target, rate * delta)
	sliding = not on_floor and not jump and _carry_m <= 0.0 and _slope_normal != Vector3.ZERO
	# Gravity in two half steps around the move: the parabola is exact.
	var falls := (not on_floor or jump) and not sliding and _carry_m <= 0.0
	if sliding:
		velocity = _slide_velocity(target, delta)
	else:
		velocity = Vector3(h.x, float(_cfg.jump_ms) if jump else velocity.y, h.z)
		if falls:
			velocity.y -= float(_cfg.gravity_ms2) * delta * 0.5
	if (on_floor or _carry_m > 0.0) and not jump:
		_step(h * delta)
	_air_top_y = global_position.y if on_floor else maxf(_air_top_y, global_position.y)
	if _carry_m > 0.0:
		_carry_level(delta)
	else:
		_slide(delta)
	if falls and not is_on_floor():
		velocity.y -= float(_cfg.gravity_ms2) * delta * 0.5
	if is_on_floor() and not on_floor:
		var drop := maxf(0.0, _air_top_y - global_position.y)
		var impact := sqrt(2.0 * float(_cfg.gravity_ms2) * drop)
		var safe := float(_cfg.fall_safe_ms)
		landed.emit(impact, maxf(0.0, impact - safe) * float(_cfg.fall_hp_per_ms))
	_slope_normal = _sliding_normal()
	step_offset_m = move_toward(step_offset_m, 0.0, float(_cfg.step_return_ms) * delta)
	_rising = _rising and velocity.y > 0.0 and not is_on_floor()
	state = State.GROUNDED if is_grounded() else State.AIRBORNE
	if jump:
		jumped.emit()


## move_and_slide; a riser met during the slide is stepped from there with
## the speed it had, carrying on for the rest of the tick's motion.
func _slide(delta: float) -> void:
	var before := velocity
	var at := global_position
	move_and_slide()
	var flat := Vector3(before.x, 0.0, before.z)
	if is_grounded() and is_on_wall() and _step(flat * delta):
		velocity = flat
		var moved := Vector2(global_position.x - at.x, global_position.z - at.z).length()
		var left := flat.length() * delta - moved
		if left > 0.0:
			_carry_level(left / flat.length())


## Starts a mantle when MantleProbe finds one ahead; true when it did.
func _start_mantle() -> bool:
	var forward := Vector3.FORWARD.rotated(Vector3.UP, yaw)
	var found := MantleProbe.find(self, _cfg, _shape.radius, forward)
	if found.is_empty():
		return false
	_jump_buffer_s = 0.0
	_carry_m = 0.0
	if bool(found.crouch) and not crouched:
		crouched = true
		_set_height(float(_cfg.crouch_height_m))
	_mantle = [0.0, global_position, found.raised, found.landing]
	velocity = Vector3.ZERO
	state = State.MANTLING
	mantle_started.emit(float(found.rise))
	return true


## Moves the body along the mantle path (up, then onto the top) over
## mantle_s; no input, no gravity.
func _mantle_tick(delta: float) -> void:
	var total := float(_cfg.mantle_s)
	_mantle[0] = float(_mantle[0]) + delta
	var u := clampf(float(_mantle[0]) / total, 0.0, 1.0)
	var a: Vector3 = _mantle[1]
	var b: Vector3 = _mantle[2]
	var c: Vector3 = _mantle[3]
	if u < MANTLE_RISE_SHARE:
		global_position = a.lerp(b, u / MANTLE_RISE_SHARE)
	else:
		global_position = b.lerp(c, (u - MANTLE_RISE_SHARE) / (1.0 - MANTLE_RISE_SHARE))
	velocity = Vector3.ZERO
	if u >= 1.0:
		_mantle = []
		_air_top_y = global_position.y
		state = State.GROUNDED
		apply_floor_snap()


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
	if _carry_m <= 0.0:
		apply_floor_snap()


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
	if _cfg.is_empty() or not is_inside_tree() or _rising:
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
