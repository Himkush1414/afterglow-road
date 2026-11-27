extends TestCase
## PlayerCamera (10 §2 rules 2, 3, 11) on the content's "camera" and
## "movement" groups: look limits, stable eye and crouch blend, step
## smoothing, yaw handed to the motor, and the camera part of T-10-12
## (real frames: physics at 60 Hz, rendering capped at 144 Hz).

const FRAME_CAP := 144

var _level: Node3D
var _motor: PlayerMotor
var _camera: PlayerCamera
var _old_fps := 0


func before_each() -> void:
	_level = Node3D.new()
	tree.root.add_child(_level)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0.0, -0.5, 0.0)
	_level.add_child(body)
	_motor = PlayerMotor.new()
	_level.add_child(_motor)
	_camera = PlayerCamera.new()
	_camera.reads_input = false
	_level.add_child(_camera)
	_camera.set_process(false)  # the tests call update_view themselves
	_old_fps = Engine.max_fps


func after_each() -> void:
	Engine.max_fps = _old_fps
	_level.free()


func _ready_rig() -> bool:
	var move := ContentDB.tuning("movement")
	var cam := ContentDB.tuning("camera")
	if not check(not move.is_empty() and not cam.is_empty(), "content has movement and camera"):
		return false
	if not check(_motor.setup(move), ", ".join(_motor.errors)):
		return false
	return check(_camera.setup(_motor, cam), ", ".join(_camera.errors))


func _cfg(key: String) -> float:
	return float(ContentDB.tuning("camera")[key])


func _settle() -> void:
	_motor.global_position = Vector3(0.0, 0.02, 0.0)
	_motor.reset_physics_interpolation()
	for i in 20:
		await tree.physics_frame


func test_setup_names_missing_keys() -> void:
	check(not _camera.setup(_motor, {}), "empty tuning refused")
	check_eq(_camera.errors.size(), PlayerCamera.KEYS.size(), "one error per key")


func test_look_limits_and_low_pitch_shift() -> void:
	if not _ready_rig():
		return
	_camera.look(Vector2(0.0, -10.0))
	check_near(rad_to_deg(_camera.pitch), _cfg("pitch_min_deg"), 1e-3, "pitch down limit")
	# 10 §2 rule 3: shift × (−pitch − |threshold|) / |threshold|, in degrees.
	var low := -_cfg("low_pitch_deg")
	var want := _cfg("low_pitch_shift_m") * (-_cfg("pitch_min_deg") - low) / low
	check_near(_camera.low_pitch_shift_m(), want, 1e-5, "shift at the down limit")
	_camera.look(Vector2(0.0, 20.0))
	check_near(rad_to_deg(_camera.pitch), _cfg("pitch_max_deg"), 1e-3, "pitch up limit")
	check_eq(_camera.low_pitch_shift_m(), 0.0, "no shift looking up")
	_camera.pitch = deg_to_rad(_cfg("low_pitch_deg"))
	check_near(_camera.low_pitch_shift_m(), 0.0, 1e-6, "no shift at the threshold")
	_camera.pitch = 0.0
	_camera.yaw = 0.0
	_camera.look(Vector2(-PI * 1.5, 0.0))
	check_near(_camera.yaw, -PI * 0.5, 1e-5, "yaw wraps")


func test_stable_eye_crouch_blend_and_step_offset() -> void:
	if not _ready_rig():
		return
	await _settle()
	_camera.update_view(0.0)
	var base := _motor.get_global_transform_interpolated().origin.y
	check_near(_camera.global_position.y - base, _cfg("stand_eye_m"), 1e-3, "standing eye")
	_motor.crouch = true
	await tree.physics_frame
	await tree.physics_frame
	check(_motor.crouched, "crouched")
	var blend := _cfg("eye_blend_s")
	_camera.update_view(blend * 0.5)
	var mid := (_cfg("stand_eye_m") + _cfg("crouch_eye_m")) * 0.5
	check_near(_camera.eye_height_m(), mid, 1e-3, "half way after half the blend")
	_camera.update_view(blend * 0.5)
	check_near(_camera.eye_height_m(), _cfg("crouch_eye_m"), 1e-3, "crouch eye")
	_motor.step_offset_m = 0.2
	_motor.step_offset_prev_m = 0.2
	_camera.update_view(0.0)
	base = _motor.get_global_transform_interpolated().origin.y
	check_near(_camera.global_position.y - base, _cfg("crouch_eye_m") - 0.2, 1e-3, "step offset")


func test_the_motor_moves_along_the_view() -> void:
	if not _ready_rig():
		return
	await _settle()
	_camera.look(Vector2(PI * 0.5, 0.0))  # a quarter turn right: facing +X
	_camera.update_view(0.0)
	check_near(_motor.yaw, _camera.yaw, 1e-6, "motor yaw from the camera")
	var from := _motor.global_position
	_motor.move = Vector2(0.0, -1.0)
	for i in 30:
		await tree.physics_frame
	var d := _motor.global_position - from
	check(d.x > 0.5 and absf(d.z) < 0.05, "moved toward +X: %s" % d)
	var fwd := -_camera.global_basis.z
	check(fwd.x > 0.99, "camera faces +X: %s" % fwd)


## Real frames for `seconds`: each frame turns the view by `turn_deg_s`
## and records [frame delta, camera yaw, camera position].
func _frames(seconds: float, turn_deg_s: float) -> Array:
	Engine.max_fps = FRAME_CAP
	var out: Array = []
	var t := 0.0
	while t < seconds:
		await tree.process_frame
		var dt := tree.root.get_process_delta_time()
		_camera.look(Vector2(-deg_to_rad(turn_deg_s) * dt, 0.0))
		_camera.update_view(dt)
		out.append([dt, _camera.yaw, _camera.global_position])
		t += dt
	return out


func test_turning_changes_the_view_every_frame() -> void:
	# T-10-12, camera part: a steady 180°/s turn.
	if not _ready_rig():
		return
	await _settle()
	var frames: Array = await _frames(1.0, 180.0)
	var still := 0
	for i in range(1, frames.size()):
		still += int(is_equal_approx(float(frames[i][1]), float(frames[i - 1][1])))
	check(frames.size() > 60, "more frames than physics ticks: %d" % frames.size())
	check_eq(still, 0, "frames without a yaw change")


func test_jogging_straight_moves_the_view_evenly() -> void:
	# T-10-12, camera part: per-frame camera speed within 5% of the mean.
	if not _ready_rig():
		return
	await _settle()
	_motor.move = Vector2(0.0, -1.0)
	for i in 30:
		await tree.physics_frame  # up to jog speed
	var frames: Array = await _frames(1.5, 0.0)
	var speeds: Array[float] = []
	for i in range(1, frames.size()):
		var dt := float(frames[i][0])
		var a: Vector3 = frames[i - 1][2]
		var b: Vector3 = frames[i][2]
		if dt > 0.0:
			speeds.append(Vector2(b.x - a.x, b.z - a.z).length() / dt)
	var mean := 0.0
	for v in speeds:
		mean += v
	mean /= maxf(1.0, speeds.size())
	var worst := 0.0
	for v in speeds:
		worst = maxf(worst, absf(v - mean) / mean)
	check(frames.size() > 90, "frames: %d" % frames.size())
	check(worst <= 0.05, "worst frame %.1f%% off the mean %.3f m/s" % [worst * 100.0, mean])
