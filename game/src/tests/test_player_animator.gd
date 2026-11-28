extends TestCase
## PlayerAnimator on a synthetic rig: every clip turns the Hips bone by its
## own angle, so the pose shows which clip plays. Blend positions follow the
## motor's velocity in the view's frame; crouch, jump start, air, land and
## mantle states follow the motor.

const DT := 1.0 / 60.0

var _rig: Node3D
var _skel: Skeleton3D
var _motor: PlayerMotor
var _anim: PlayerAnimator
var _angles := {}


func before_each() -> void:
	_rig = Node3D.new()
	tree.root.add_child(_rig)
	_skel = Skeleton3D.new()
	_skel.name = "GeneralSkeleton"
	_rig.add_child(_skel)
	_skel.owner = _rig
	_skel.unique_name_in_owner = true
	_skel.add_bone("Hips")
	_motor = PlayerMotor.new()
	_rig.add_child(_motor)
	_anim = PlayerAnimator.new()
	_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_rig.add_child(_anim)


func after_each() -> void:
	_rig.free()


func _library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	var names := PlayerAnimator.clip_names()
	for i in names.size():
		var a := Animation.new()
		var one_shot := names[i] in ["jump_start", "jump_land", "mantle"]
		a.length = 0.2 if one_shot else 1.0
		a.loop_mode = Animation.LOOP_NONE if one_shot else Animation.LOOP_LINEAR
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%GeneralSkeleton:Hips"))
		_angles[names[i]] = 5.0 * (i + 1)
		var q := Quaternion(Vector3.UP, deg_to_rad(_angles[names[i]]))
		a.rotation_track_insert_key(t, 0.0, q)
		a.rotation_track_insert_key(t, a.length, q)
		lib.add_animation(names[i], a)
	return lib


func _ready_rig() -> bool:
	var cfg := ContentDB.tuning("movement")
	if not check(_motor.setup(cfg), ", ".join(_motor.errors)):
		return false
	return check(_anim.setup(_motor, _library(), _rig, cfg), ", ".join(_anim.errors))


func _run(seconds: float) -> void:
	for i in roundi(seconds / DT):
		_anim.update_state()
		_anim.advance(DT)


func _hips_deg() -> float:
	return rad_to_deg(_skel.get_bone_pose_rotation(0).get_angle())


func test_setup_names_missing_clips() -> void:
	var cfg := ContentDB.tuning("movement")
	check(not _anim.setup(_motor, AnimationLibrary.new(), _rig, cfg), "empty library refused")
	check(_anim.errors.size() >= 18, "one error per clip: %d" % _anim.errors.size())


func test_blend_follows_velocity_in_the_view_frame() -> void:
	if not _ready_rig():
		return
	var walk := float(ContentDB.tuning("movement").walk_ms)
	_run(0.5)
	check_near(_hips_deg(), _angles.idle, 0.1, "idle at rest")
	_motor.velocity = Vector3(0, 0, -walk)  # yaw 0 faces -Z: forward
	_run(0.5)
	check_near(_hips_deg(), _angles.walk_f, 0.1, "walk forward")
	_motor.yaw = PI * 0.5  # facing -X
	_motor.velocity = Vector3(-walk, 0, 0)
	_run(0.5)
	check_near(_hips_deg(), _angles.walk_f, 0.1, "still forward after turning")
	_motor.velocity = Vector3(0, 0, walk * float(ContentDB.tuning("movement").strafe_mult))
	_run(0.5)
	check_near(_hips_deg(), _angles.walk_l, 0.1, "+Z is the left when facing -X")


func test_crouch_and_jump_states() -> void:
	if not _ready_rig():
		return
	_run(0.3)
	_motor.crouched = true
	_run(0.5)
	check_eq(_anim.current_state(), PlayerAnimator.CROUCH, "crouch state")
	check_near(_hips_deg(), _angles.crouch_idle, 0.1, "crouch idle")
	_motor.crouched = false
	_run(0.5)
	check_eq(_anim.current_state(), PlayerAnimator.STAND, "back to stand")
	_motor.state = PlayerMotor.State.AIRBORNE
	_motor.jumped.emit()
	_run(0.05)
	check_eq(_anim.current_state(), PlayerAnimator.JUMP_START, "jump start")
	_run(0.5)
	check_eq(_anim.current_state(), PlayerAnimator.AIR, "air after the start clip")
	check_near(_hips_deg(), _angles.jump_air, 0.1, "air pose")
	_motor.state = PlayerMotor.State.GROUNDED
	_motor.landed.emit(5.0, 0.0)
	_run(0.05)
	check_eq(_anim.current_state(), PlayerAnimator.JUMP_LAND, "land")
	_run(0.6)
	check_eq(_anim.current_state(), PlayerAnimator.STAND, "stand after landing")


func test_setup_twice_connects_once() -> void:
	if not _ready_rig():
		return
	check(_anim.setup(_motor, _library(), _rig, ContentDB.tuning("movement")), "second setup")
	check_eq(_motor.jumped.get_connections().size(), 1, "one jumped connection")
	check_eq(_motor.landed.get_connections().size(), 1, "one landed connection")


func test_mantle_plays_for_the_mantle_time() -> void:
	if not _ready_rig():
		return
	var mantle_s := float(ContentDB.tuning("movement").mantle_s)
	_run(0.3)
	_motor.state = PlayerMotor.State.MANTLING
	_motor.mantle_started.emit(1.0)
	_run(0.05)
	check_eq(_anim.current_state(), PlayerAnimator.MANTLE, "mantle state")
	# The test clip lasts 0.2 s; stretched to the mantle time it is still
	# playing half way through the mantle.
	_run(mantle_s * 0.5)
	check_eq(_anim.current_state(), PlayerAnimator.MANTLE, "still mantling half way")
	check_near(_hips_deg(), _angles.mantle, 0.1, "mantle pose")
	_motor.state = PlayerMotor.State.GROUNDED
	_run(mantle_s * 0.5 + 0.3)
	check_eq(_anim.current_state(), PlayerAnimator.STAND, "stand after the mantle")
