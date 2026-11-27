extends TestCase
## PlayerMotor (10 §4) on the loaded content's "movement" group: gait speeds
## (T-10-1), slopes (T-10-3) and step-up (T-10-11). Ticks are run directly
## at 60 Hz; every test geometry is derived from the tuning values.

const DT := 1.0 / 60.0

var _cfg := {}
var _level: Node3D
var _motor: PlayerMotor


func before_each() -> void:
	_cfg = ContentDB.tuning("movement")
	_level = Node3D.new()
	tree.root.add_child(_level)
	_motor = PlayerMotor.new()
	_level.add_child(_motor)


func after_each() -> void:
	_level.free()


func _ready_motor() -> bool:
	if not check(not _cfg.is_empty(), "content has a movement group"):
		return false
	return check(_motor.setup(_cfg), ", ".join(_motor.errors))


## A static box of `size` centred at `at`, rotated `tilt_deg` about X.
func _box(size: Vector3, at: Vector3, tilt_deg: float = 0.0) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	body.rotation_degrees.x = tilt_deg
	_level.add_child(body)


func _floor() -> void:
	_box(Vector3(400.0, 1.0, 400.0), Vector3(0.0, -0.5, 0.0))


func _run(seconds: float) -> void:
	for i in roundi(seconds / DT):
		_motor.tick(DT)


## Places the motor at `at` and settles it for half a second without intents.
func _place(at: Vector3) -> void:
	await tree.physics_frame
	_motor.global_position = at
	_motor.velocity = Vector3.ZERO
	_motor.move = Vector2.ZERO
	_run(0.5)


func _horizontal(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()


func test_setup_names_missing_keys() -> void:
	check(not _motor.setup({}), "empty tuning refused")
	check_eq(_motor.errors.size(), PlayerMotor.KEYS.size(), "one error per key")


func test_gait_speeds_on_flat_ground() -> void:
	# T-10-1: walk, jog, sprint, crouch within 2% over 5 s.
	if not _ready_motor():
		return
	_floor()
	var gaits := {
		"walk_ms": [false, true, false],
		"jog_ms": [false, false, false],
		"sprint_ms": [true, false, false],
		"crouch_ms": [false, false, true],
	}
	for key: String in gaits:
		var g: Array = gaits[key]
		await _place(Vector3(0.0, 0.05, 0.0))
		_motor.sprint = g[0]
		_motor.walk = g[1]
		_motor.crouch = g[2]
		_motor.move = Vector2(0.0, -1.0)
		_run(1.0)
		var from := _motor.global_position
		_run(5.0)
		var speed := _horizontal(from, _motor.global_position) / 5.0
		var want := float(_cfg[key])
		check_near(speed, want, want * 0.02, "%s: %.3f m/s" % [key, speed])
		_motor.sprint = false
		_motor.walk = false
		_motor.crouch = false
		_run(0.5)


func test_direction_factors_and_sprint_cone() -> void:
	if not _ready_motor():
		return
	var jog := float(_cfg.jog_ms)
	_motor.move = Vector2(0.0, 1.0)
	check_near(_motor.target_velocity().length(), jog * float(_cfg.back_mult), 1e-4, "backward")
	_motor.move = Vector2(1.0, 0.0)
	check_near(_motor.target_velocity().length(), jog * float(_cfg.strafe_mult), 1e-4, "strafe")
	_motor.sprint = true
	check_near(
		_motor.target_velocity().length(), jog * float(_cfg.strafe_mult), 1e-4, "no side sprint"
	)
	_motor.move = Vector2(0.0, -1.0)
	check_near(_motor.target_velocity().length(), float(_cfg.sprint_ms), 1e-4, "forward sprint")
	_motor.yaw = PI * 0.5
	var v := _motor.target_velocity()
	check(v.x < -1.0 and absf(v.z) < 1e-4, "yaw a quarter turn left moves toward −X: %s" % v)


func _slope_run(angle_deg: float) -> Array:
	var a := deg_to_rad(angle_deg)
	_box(Vector3(20.0, 1.0, 60.0), Vector3.ZERO, angle_deg)
	var top := Vector3(0.0, 0.5 * cos(a), 0.5 * sin(a))
	await _place(top + Vector3(0.0, 0.05, 0.0))
	var from := _motor.global_position
	_motor.move = Vector2(0.0, -1.0)  # uphill: the box rises toward −Z
	var slid := false
	for i in roundi(2.0 / DT):
		_motor.tick(DT)
		slid = slid or _motor.sliding
	return [_motor.global_position.y - from.y, slid]


func test_a_walkable_slope_can_be_climbed() -> void:
	# T-10-3, first half: a slope 2° under the walkable limit.
	if not _ready_motor():
		return
	var angle := float(_cfg.walk_slope_deg) - 2.0
	var r := await _slope_run(angle)
	var ideal := float(_cfg.jog_ms) * sin(deg_to_rad(angle)) * 2.0
	check(float(r[0]) > 0.7 * ideal, "climbed %.2f m of %.2f" % [r[0], ideal])
	check(not r[1], "never sliding")


func test_a_steeper_slope_slides() -> void:
	# T-10-3, second half: 3° over the walkable limit, under the wall limit.
	if not _ready_motor():
		return
	var r := await _slope_run(float(_cfg.walk_slope_deg) + 3.0)
	check(float(r[0]) < 0.0, "ends lower than it started: %.2f m" % r[0])
	check(r[1], "slides")


## Stairs up toward −Z from z = 0: `count` risers of `riser` m, treads of
## `tread` m, then a landing; the floor lies before them.
func _stairs(riser: float, tread: float, count: int) -> void:
	_floor()
	for i in count:
		var top := (i + 1) * riser
		_box(Vector3(4.0, top, tread), Vector3(0.0, top * 0.5, -(i + 0.5) * tread))
	var h := count * riser
	_box(Vector3(4.0, h, 40.0), Vector3(0.0, h * 0.5, -count * tread - 20.0))


func test_steps_up_a_flight_at_jog_speed() -> void:
	# T-10-11: risers 0.05 m under the step height keep ≥ 90% of jog speed;
	# the view rises from steps at no more than step_return_ms.
	if not _ready_motor():
		return
	var riser := float(_cfg.step_m) - 0.05
	var tread := 0.4
	var count := 10
	_stairs(riser, tread, count)
	await _place(Vector3(0.0, 0.05, 2.0))
	_motor.move = Vector2(0.0, -1.0)
	var steps := [0]
	_motor.stepped.connect(func(_r: float) -> void: steps[0] += 1)
	var view_y := _motor.global_position.y - _motor.step_offset_m
	var fastest := 0.0
	var start := Vector3.INF
	var t := 0.0
	var t_end := 0.0
	for i in roundi(4.0 / DT):
		_motor.tick(DT)
		var p := _motor.global_position
		var y := p.y - _motor.step_offset_m
		fastest = maxf(fastest, (y - view_y) / DT)
		view_y = y
		t += DT
		if not start.is_finite() and p.z < 0.0:
			start = p
			t = 0.0
		if start.is_finite() and t_end == 0.0 and p.z < -count * tread:
			t_end = t
			var speed := _horizontal(start, p) / t_end
			var jog := float(_cfg.jog_ms)
			check(speed >= 0.9 * jog, "speed on the flight %.2f m/s (jog %.2f)" % [speed, jog])
	check(t_end > 0.0, "reached the landing")
	check_eq(steps[0], count, "one step per riser")
	check_near(_motor.global_position.y, count * riser, 0.02, "on the landing")
	check(fastest <= float(_cfg.step_return_ms) * 1.01 + 0.05, "view rises at %.2f m/s" % fastest)


func test_a_riser_over_the_step_height_stops_the_body() -> void:
	if not _ready_motor():
		return
	_stairs(float(_cfg.step_m) + 0.05, 0.3, 1)
	await _place(Vector3(0.0, 0.05, 2.0))
	_motor.move = Vector2(0.0, -1.0)
	_run(3.0)
	check(_motor.global_position.z > 0.0, "held at the riser: z %.2f" % _motor.global_position.z)
	check(_motor.global_position.y < 0.05, "still on the floor")


func test_walking_down_a_flight_never_leaves_the_floor() -> void:
	# T-10-11, last part.
	if not _ready_motor():
		return
	var riser := float(_cfg.step_m) - 0.05
	var count := 10
	_stairs(riser, 0.4, count)
	await _place(Vector3(0.0, count * riser + 0.05, -count * 0.4 - 2.0))
	_motor.walk = true
	_motor.yaw = PI  # facing +Z: down the flight
	_motor.move = Vector2(0.0, -1.0)
	var airborne := 0
	for i in roundi(4.0 / DT):
		_motor.tick(DT)
		airborne += int(not _motor.is_grounded())
	check(
		_motor.global_position.z > 0.5, "walked off the flight: z %.2f" % _motor.global_position.z
	)
	check_near(_motor.global_position.y, 0.0, 0.02, "on the floor below")
	check_eq(airborne, 0, "ticks off the floor")


func test_crouch_needs_room_to_stand() -> void:
	if not _ready_motor():
		return
	_floor()
	var low := (float(_cfg.crouch_height_m) + float(_cfg.stand_height_m)) * 0.5
	_box(Vector3(4.0, 0.5, 4.0), Vector3(0.0, low + 0.25, 0.0))
	await _place(Vector3(10.0, 0.05, 0.0))
	_motor.crouch = true
	_run(0.1)
	check(_motor.crouched, "crouched")
	check_near(_motor.height_m(), float(_cfg.crouch_height_m), 1e-4, "crouch height")
	_motor.global_position = Vector3(0.0, 0.05, 0.0)
	_run(0.1)
	_motor.crouch = false
	_run(0.2)
	check(_motor.crouched, "stays crouched under the low ceiling")
	_motor.global_position = Vector3(10.0, 0.05, 0.0)
	_run(0.2)
	check(not _motor.crouched, "stands up in the open")
	check_near(_motor.height_m(), float(_cfg.stand_height_m), 1e-4, "stand height")
