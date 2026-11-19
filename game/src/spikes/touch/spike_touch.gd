extends SceneTree
## Spike P1-08 (assumption A-14): the built-in VirtualJoystick gives analogue
## movement with a dead zone and re-centres where the thumb lands; a look
## area beside it turns a camera by drag distance (no acceleration), and both
## work at the same time with two fingers. Touch is emulated with screen
## events. Needs a display and a window of 1920 x 1080 (headless, GUI
## controls receive no touch events). Prints RESULT PASS / FAIL.

const MOVE := [&"spike_left", &"spike_right", &"spike_up", &"spike_down"]
const RADIUS := 130.0
const LOOK_SENSITIVITY := 0.005  # radians per pixel of drag


## Turns a camera by the drag of the one finger that started inside it.
class LookArea:
	extends Control
	var yaw := 0.0
	var pitch := 0.0
	var _finger := -1

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			var t := event as InputEventScreenTouch
			if t.pressed and _finger < 0:
				_finger = t.index
			elif not t.pressed and t.index == _finger:
				_finger = -1
			accept_event()
		elif event is InputEventScreenDrag:
			var d := event as InputEventScreenDrag
			if d.index == _finger:
				yaw -= d.relative.x * LOOK_SENSITIVITY
				pitch = clampf(pitch - d.relative.y * LOOK_SENSITIVITY, -1.4, 1.4)
				accept_event()


var _last := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for a: StringName in MOVE:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.0)
	var screen := root.get_visible_rect().size
	var ui := Control.new()
	ui.size = screen
	root.add_child(ui)
	var stick := VirtualJoystick.new()
	stick.joystick_mode = VirtualJoystick.JOYSTICK_DYNAMIC
	stick.deadzone_ratio = 0.15
	stick.joystick_size = RADIUS * 2.0
	stick.action_left = MOVE[0]
	stick.action_right = MOVE[1]
	stick.action_up = MOVE[2]
	stick.action_down = MOVE[3]
	stick.position = Vector2(0, screen.y * 0.35)
	stick.size = Vector2(screen.x * 0.4, screen.y * 0.65)
	ui.add_child(stick)
	var look := LookArea.new()
	look.position = Vector2(screen.x * 0.4, 0)
	look.size = Vector2(screen.x * 0.6, screen.y)
	ui.add_child(look)
	await process_frame
	var ok := true

	# 1. Re-centre and analogue output: two landing points, same relative drags.
	for start: Vector2 in [Vector2(200, 800), Vector2(500, 950)]:
		_touch(0, start, true)
		await process_frame
		var v0 := _move()
		var xs: Array[float] = []
		for frac: float in [0.1, 0.3, 0.6, 1.0, 1.5]:
			_drag(0, start + Vector2(RADIUS * frac, 0))
			await process_frame
			xs.append(snappedf(_move().x, 0.01))
		_touch(0, start + Vector2(RADIUS * 1.5, 0), false)
		await process_frame
		var after := _move()
		print(
			(
				"stick from %s: touch-down %s; drags 10/30/60/100/150 %% of radius -> x %s; released %s"
				% [start, v0, xs, after]
			)
		)
		ok = (
			ok
			and v0.length() < 0.01
			and xs[0] == 0.0
			and xs[1] > 0.05
			and xs[1] < xs[2]
			and xs[2] < xs[3]
			and xs[3] >= 0.99
			and xs[4] >= 0.99
			and after.length() < 0.01
		)

	# 2. Look drag: angle follows distance, not speed (same 300 px in 3 or 30 steps).
	var angles: Array[float] = []
	for steps: int in [3, 30]:
		look.yaw = 0.0
		var p := Vector2(1400, 500)
		_touch(1, p, true)
		await process_frame
		for i in steps:
			p += Vector2(300.0 / steps, 0)
			_drag(1, p)
			await process_frame
		_touch(1, p, false)
		await process_frame
		angles.append(look.yaw)
	var expected := -300.0 * LOOK_SENSITIVITY
	print(
		(
			"look yaw after 300 px in 3 steps %.4f, in 30 steps %.4f (expected %.4f)"
			% [angles[0], angles[1], expected]
		)
	)
	ok = ok and absf(angles[0] - expected) < 1e-4 and absf(angles[1] - expected) < 1e-4

	# 3. Two fingers at once: stick held at 60 %, look finger drags.
	look.yaw = 0.0
	var s := Vector2(300, 850)
	_touch(0, s, true)
	await process_frame
	_drag(0, s + Vector2(0, -RADIUS * 0.6))
	await process_frame
	var held := _move()
	var lp := Vector2(1500, 400)
	_touch(1, lp, true)
	await process_frame
	for i in 10:
		lp += Vector2(-20, 0)
		_drag(1, lp)
		await process_frame
	var held_after := _move()
	_touch(1, lp, false)
	_touch(0, s + Vector2(0, -RADIUS * 0.6), false)
	await process_frame
	print(
		(
			"two fingers: stick %s before, %s after the look drag; look yaw %.4f (expected %.4f)"
			% [held, held_after, look.yaw, 200.0 * LOOK_SENSITIVITY]
		)
	)
	ok = (
		ok
		and held.y < -0.3
		and held.distance_to(held_after) < 0.01
		and absf(look.yaw - 200.0 * LOOK_SENSITIVITY) < 1e-4
		and _move().length() < 0.01
	)
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _move() -> Vector2:
	return Input.get_vector(MOVE[0], MOVE[1], MOVE[2], MOVE[3])


func _touch(finger: int, at: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = finger
	e.position = at
	e.pressed = down
	_last[finger] = at
	Input.parse_input_event(e)


func _drag(finger: int, at: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = finger
	e.position = at
	e.relative = at - _last.get(finger, at)
	_last[finger] = at
	Input.parse_input_event(e)
