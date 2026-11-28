extends TestCase
## Water movement (10 §4.1-4.3) and stamina (T-10-10) on a flat floor with a
## stand-in water query: deep water for x < 100, wading depth for
## 100 <= x < 120, dry beyond. Ticks run directly at 60 Hz.


## Stand-in for Water: depth_at / surface_y by zone; the floor is at y = 0.
class FakeWater:
	extends RefCounted
	var deep := 2.0
	var wade := 0.8

	func surface_y(pos: Vector3) -> float:
		if pos.x < 100.0:
			return deep
		if pos.x < 120.0:
			return wade
		return -INF

	func depth_at(pos: Vector3) -> float:
		var s := surface_y(pos)
		return s if s > -INF else 0.0


const DT := 1.0 / 60.0

var _cfg := {}
var _level: Node3D
var _motor: PlayerMotor
var _stamina: PlayerStamina
var _starts := 0
var _ends := 0


func before_each() -> void:
	_cfg = ContentDB.tuning("movement")
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
	_starts = 0
	_ends = 0


func after_each() -> void:
	_level.free()


func _ready_all() -> bool:
	if not check(_motor.setup(_cfg), ", ".join(_motor.errors)):
		return false
	_motor.water = FakeWater.new()
	_motor.swim_started.connect(func() -> void: _starts += 1)
	_motor.swim_ended.connect(func() -> void: _ends += 1)
	var ok := check(_stamina.setup(_motor, ContentDB.tuning("stamina")), ", ".join(_stamina.errors))
	_stamina.set_physics_process(false)  # ticked by the tests, in step with the motor
	return ok


func _run(seconds: float, stamina := false) -> void:
	for i in roundi(seconds / DT):
		_motor.tick(DT)
		if stamina:
			_stamina.tick(DT)


func _place(at: Vector3) -> void:
	await tree.physics_frame
	_motor.global_position = at
	_motor.velocity = Vector3.ZERO
	_motor.move = Vector2.ZERO
	_motor.yaw = -PI * 0.5  # forward is +X
	_run(0.5)


func _flat_speed() -> float:
	return Vector2(_motor.velocity.x, _motor.velocity.z).length()


func test_swimming_at_the_surface() -> void:
	if not _ready_all():
		return
	await _place(Vector3(0, 0, 0))
	check(_motor.is_swimming(), "deep water: swimming")
	check_eq(_starts, 1, "swim start signalled once")
	_run(3.0)
	var feet := 2.0 - float(_cfg.swim_feet_below_m)
	check_near(_motor.global_position.y, feet, 0.02, "feet held under the surface")
	_motor.move = Vector2(0, -1)
	_motor.sprint = true
	_run(2.0)
	check_near(_flat_speed(), float(_cfg.swim_ms), 0.02, "swim speed, sprint ignored")
	check_near(_motor.velocity.y, 0.0, 0.05, "no diving or rising while level")


func test_wading_is_slow_and_has_no_sprint() -> void:
	if not _ready_all():
		return
	await _place(Vector3(110, 0, 0))
	check(not _motor.is_swimming() and _motor.is_wading(), "wading depth")
	_motor.move = Vector2(0, -1)
	_run(1.5)
	var jog := float(_cfg.jog_ms) * float(_cfg.wade_mult)
	check_near(_flat_speed(), jog, 0.05, "jog x wade factor")
	_motor.sprint = true
	_run(1.5)
	check_near(_flat_speed(), jog, 0.05, "no sprint in water")


func test_leaving_the_water_with_hysteresis() -> void:
	if not _ready_all():
		return
	_motor.water.wade = float(_cfg.swim_exit_depth_m) + 0.1  # between exit and enter depth
	await _place(Vector3(97, 0, 0))
	check(_motor.is_swimming(), "starts swimming")
	_motor.move = Vector2(0, -1)
	_run(4.0)  # into water shallower than the swim depth but deeper than the exit depth
	check(_motor.global_position.x > 101.0 and _motor.is_swimming(), "still swimming (hysteresis)")
	_motor.water.wade = float(_cfg.swim_exit_depth_m) - 0.1
	_run(0.5)
	check(not _motor.is_swimming(), "below the exit depth: walking")
	check_eq(_ends, 1, "swim end signalled once")


func test_stamina_drains_while_swimming_and_drowning_starts_at_zero() -> void:
	if not _ready_all():
		return
	await _place(Vector3(-50, 0, 0))
	var hp := [0.0]
	var first_damage := [-1.0]
	var t := [0.0]
	_stamina.drown_damage.connect(
		func(d: float) -> void:
			if first_damage[0] < 0.0:
				first_damage[0] = t[0]
			hp[0] += d
	)
	check_near(_stamina.value, _stamina.max_value, 1e-6, "starts full")
	_motor.move = Vector2(0, -1)
	var empty_at := -1.0
	for i in roundi(40.0 / DT):
		_motor.tick(DT)
		_stamina.tick(DT)
		t[0] += DT
		if empty_at < 0.0 and _stamina.value <= 0.0:
			empty_at = t[0]
	var cfg := ContentDB.tuning("stamina")
	var want := float(cfg.max) / float(cfg.swim_move_ps)
	check(_motor.is_swimming(), "swam the whole 40 s")
	check(absf(empty_at - want) < 0.5, "empty after %.2f s (want %.2f)" % [empty_at, want])
	check(
		first_damage[0] >= empty_at - DT,
		"no drowning before empty (first at %.2f s)" % first_damage[0]
	)
	var want_hp := (40.0 - want) * float(cfg.drown_hp_ps)
	check(absf(hp[0] - want_hp) < 2.0, "drowning damage %.1f HP (want %.1f)" % [hp[0], want_hp])


func test_regeneration_waits_for_the_delay() -> void:
	if not _ready_all():
		return
	await _place(Vector3(200, 0, 0))  # dry land
	var cfg := ContentDB.tuning("stamina")
	_stamina.spend(50.0)
	var delay := float(cfg.regen_delay_s)
	_run(delay - 0.1, true)
	check_near(_stamina.value, _stamina.max_value - 50.0, 1e-6, "no regeneration before the delay")
	_run(1.1, true)
	check_near(
		_stamina.value,
		_stamina.max_value - 50.0 + float(cfg.regen_ps),
		0.5,
		"then regen_ps per second"
	)
