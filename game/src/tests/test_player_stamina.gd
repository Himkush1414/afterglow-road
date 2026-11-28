extends TestCase
## Stamina costs and limits and encumbrance (10 §4.1, 13 §3, T-10-9) on a
## flat floor; ticks run directly at 60 Hz, motor first.

const DT := 1.0 / 60.0

var _mv := {}
var _st := {}
var _level: Node3D
var _motor: PlayerMotor
var _stamina: PlayerStamina


func before_each() -> void:
	_mv = ContentDB.tuning("movement")
	_st = ContentDB.tuning("stamina")
	_level = Node3D.new()
	tree.root.add_child(_level)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 1, 600)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0, -0.5, 0)
	_level.add_child(body)
	_motor = PlayerMotor.new()
	_level.add_child(_motor)
	_stamina = PlayerStamina.new()
	_level.add_child(_stamina)


func after_each() -> void:
	_level.free()


func _ready_all() -> bool:
	if not check(_motor.setup(_mv), ", ".join(_motor.errors)):
		return false
	var ok := check(_stamina.setup(_motor, _st), ", ".join(_stamina.errors))
	_stamina.set_physics_process(false)  # ticked by the tests, in step with the motor
	await tree.physics_frame
	_motor.global_position = Vector3.ZERO
	_run(0.5)
	return ok


func _run(seconds: float) -> void:
	for i in roundi(seconds / DT):
		_motor.tick(DT)
		_stamina.tick(DT)


func _flat_speed() -> float:
	return Vector2(_motor.velocity.x, _motor.velocity.z).length()


func test_load_ratio_slows_and_refuses_jump() -> void:
	if not await _ready_all():
		return
	var jog := float(_mv.jog_ms)
	_motor.load_ratio = 1.25
	_motor.move = Vector2(0, -1)
	_run(1.5)
	check_near(_flat_speed() / jog, 0.6, 0.01, "r = 1.25: 60 % speed (T-10-9)")
	var jumps := [0]
	_motor.jumped.connect(func() -> void: jumps[0] += 1)
	_motor.press_jump()
	_run(0.3)
	check_eq(jumps[0], 0, "r = 1.25: jump refused")
	_motor.load_ratio = 1.1
	_motor.sprint = true
	_run(1.5)
	check_near(_flat_speed(), jog * (1.0 - float(_mv.load_slope) * 0.1), 0.02, "r > 1: no sprint")
	_motor.press_jump()
	_run(0.3)
	check_eq(jumps[0], 1, "r = 1.1: jump allowed")
	_motor.load_ratio = float(_mv.load_max_ratio) - 0.01
	check(_motor.can_pick_up(), "below the top ratio: may pick up")
	_motor.load_ratio = float(_mv.load_max_ratio)
	check(not _motor.can_pick_up(), "at the top ratio: nothing more")


func test_sprint_drains_and_jump_costs() -> void:
	if not await _ready_all():
		return
	_motor.move = Vector2(0, -1)
	_motor.sprint = true
	_run(2.0)
	check(_motor.sprinting, "sprinting")
	check_near(_stamina.value, float(_st.max) - 2.0 * float(_st.sprint_ps), 0.3, "sprint drain")
	_motor.move = Vector2.ZERO
	_motor.sprint = false
	_run(0.5)
	var before := _stamina.value
	_motor.press_jump()
	_run(0.1)
	check_near(_stamina.value, before - float(_st.jump_cost), 0.01, "jump cost")


func test_exhausted_until_recovered() -> void:
	if not await _ready_all():
		return
	_stamina.value = 4.0
	_motor.move = Vector2(0, -1)
	_motor.sprint = true
	for i in 120:  # 8/s empties 4 within half a second
		_motor.tick(DT)
		_stamina.tick(DT)
		if _stamina.exhausted:
			break
	check(_stamina.exhausted, "exhausted at 0")
	_run(DT)  # one more tick: the motor reads the refusal
	check(not _motor.sprinting, "no sprint while exhausted")
	check(not _motor.can_jump(), "no jump while exhausted")
	_motor.move = Vector2.ZERO
	var recover := float(_st.recover_at)
	var t := float(_st.regen_delay_s) + recover / float(_st.regen_ps)
	_run(t - 0.3)
	check(
		_stamina.exhausted and _stamina.value < recover, "still exhausted below the recovery level"
	)
	_run(0.6)
	check(not _stamina.exhausted and _motor.can_jump(), "recovered at %.0f" % recover)


func test_vitals_multipliers_and_tired_maximum() -> void:
	if not await _ready_all():
		return
	_stamina.apply_vitals(50, 50, 50, 50)
	check_near(_stamina.regen_mult, 1.0, 1e-6, "all fine: x1")
	check_near(_stamina.max_value, float(_st.max), 1e-6, "full maximum")
	_stamina.apply_vitals(10, 50, 50, 50)
	check_near(_stamina.regen_mult, float(_st.low_mult), 1e-6, "low hunger halves")
	_stamina.apply_vitals(10, 10, 10, 10)
	check_near(_stamina.regen_mult, float(_st.min_mult), 1e-6, "four lows: floor")
	check_near(_stamina.max_value, float(_st.tired_max), 1e-6, "low rest: tired maximum")
	check(_stamina.value <= _stamina.max_value, "value capped")
