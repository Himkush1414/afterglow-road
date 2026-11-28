class_name PlayerCamera
extends Camera3D
## The first-person view (10 §2 rules 2, 3, 11). Look yaw and pitch are
## owned here and change at render rate from the look intents; every
## rendered frame the camera (top_level, no physics interpolation of its
## own) is put at the motor's interpolated position plus the eye offset:
## the stable eye (standing or crouching height, blended), less the step
## smoothing offset, mixed toward the head bone's eye by the head-bob
## setting, moved forward when looking far down. The motor's move yaw is
## the yaw sampled at each physics tick. Numbers: the "camera" tuning group.

## Runs before the body rig, the mirror camera and everything that reads
## the camera's position in _process (10 §2 rule 11).
const PROCESS_PRIORITY := -30
const KEYS: Array[String] = [
	"stand_eye_m",
	"crouch_eye_m",
	"eye_blend_s",
	"head_eye_up_m",
	"head_eye_fwd_m",
	"pitch_min_deg",
	"pitch_max_deg",
	"low_pitch_deg",
	"low_pitch_shift_m",
	"near_m",
	"far_m",
	"fov_desktop_min_deg",
	"fov_desktop_max_deg",
	"fov_phone_min_deg",
	"fov_phone_max_deg",
	"mouse_rad_per_px",
	"stick_deg_s",
]

var errors: PackedStringArray = []
var motor: PlayerMotor
## Look angles in radians: yaw 0 faces −Z (turning left is positive),
## pitch positive looks up.
var yaw := 0.0
var pitch := 0.0
## Returns the head bone origin as an offset from the motor's interpolated
## position (built from local transforms) once the body rig exists; until
## then the head eye is the stable eye.
var head_offset := Callable()
## The eye this frame as an offset from the motor's interpolated position:
## no world-sized number, so camera-space drawing can use it (10 §2 rule 5).
var eye_offset := Vector3.ZERO
## Read the look intents from InputRouter in _process (off in tests).
var reads_input := true

var _cfg := {}
var _eye_m := 0.0
var _head_bob := 0.0


## Follows `motor` with the "camera" tuning group; false with `errors`.
func setup(body: PlayerMotor, cfg: Dictionary) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("camera: missing %s" % key)
	if body == null:
		errors.append("camera: no motor")
	if not errors.is_empty():
		return false
	motor = body
	_cfg = cfg
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = PROCESS_PRIORITY
	near = float(cfg.near_m)
	far = float(cfg.far_m)
	_eye_m = _eye_target()
	apply_settings()
	return true


## Field of view and head bob from the settings, within the platform range.
func apply_settings() -> void:
	var phone := OS.has_feature("mobile")
	var lo := float(_cfg.fov_phone_min_deg if phone else _cfg.fov_desktop_min_deg)
	var hi := float(_cfg.fov_phone_max_deg if phone else _cfg.fov_desktop_max_deg)
	fov = clampf(float(Settings.get_value("video", "fov")), lo, hi)
	_head_bob = clampf(float(Settings.get_value("gameplay", "head_bob")), 0.0, 0.5)


## Turns the view by `d` radians (x: yaw to the right, y: pitch up).
func look(d: Vector2) -> void:
	yaw = wrapf(yaw - d.x, -PI, PI)
	var lo := deg_to_rad(float(_cfg.pitch_min_deg))
	var hi := deg_to_rad(float(_cfg.pitch_max_deg))
	pitch = clampf(pitch + d.y, lo, hi)


func _process(delta: float) -> void:
	if motor == null:
		return
	if reads_input:
		var px := InputRouter.consume_look_delta() * float(_cfg.mouse_rad_per_px)
		var stick := InputRouter.look_rate() * deg_to_rad(float(_cfg.stick_deg_s)) * delta
		look(Vector2(px.x, -px.y) + Vector2(stick.x, -stick.y))
	update_view(delta)


## Places the camera for this rendered frame, `delta` seconds after the last.
func update_view(delta: float) -> void:
	var target := _eye_target()
	var rate := absf(float(_cfg.stand_eye_m) - float(_cfg.crouch_eye_m)) / float(_cfg.eye_blend_s)
	_eye_m = move_toward(_eye_m, target, rate * delta)
	var base := motor.get_global_transform_interpolated().origin
	var f := Engine.get_physics_interpolation_fraction()
	var step := lerpf(motor.step_offset_prev_m, motor.step_offset_m, f)
	var flat := Basis(Vector3.UP, yaw)
	var stable := Vector3.UP * (_eye_m - step)
	var eye := stable
	if head_offset.is_valid():
		var head: Vector3 = head_offset.call()
		var head_eye := (
			head + flat * Vector3(0.0, float(_cfg.head_eye_up_m), -float(_cfg.head_eye_fwd_m))
		)
		eye = stable.lerp(head_eye, _head_bob)
	eye_offset = eye + flat * Vector3(0.0, 0.0, -low_pitch_shift_m())
	global_transform = Transform3D(flat * Basis(Vector3.RIGHT, pitch), base + eye_offset)
	motor.yaw = yaw


## Forward shift when looking down past low_pitch_deg, so the chest is seen
## and not entered (10 §2 rule 3).
func low_pitch_shift_m() -> float:
	var below := deg_to_rad(float(_cfg.low_pitch_deg)) - pitch
	if below <= 0.0:
		return 0.0
	var span := -deg_to_rad(float(_cfg.low_pitch_deg))
	return float(_cfg.low_pitch_shift_m) * below / span


## Eye height now in use above the capsule base, metres.
func eye_height_m() -> float:
	return _eye_m


func _eye_target() -> float:
	return float(_cfg.crouch_eye_m if motor.crouched else _cfg.stand_eye_m)
