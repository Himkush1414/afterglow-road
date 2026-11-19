extends TestCase
## InputRouter: T-18-1 (keyboard and gamepad part) and the routing rules.

const RouterScript := preload("res://src/core/input_router.gd")

var _r: Node
var _seen: Array[String] = []


func before_each() -> void:
	_r = RouterScript.new()
	_r.register_actions()
	_seen.clear()
	_r.intent.connect(
		func(name: StringName, kind: StringName) -> void: _seen.append("%s:%s" % [name, kind])
	)


func after_each() -> void:
	_r.free()


func test_every_intent_fires_from_keyboard_and_gamepad() -> void:
	var families := ["keyboard/mouse", "gamepad"]
	var defaults: Dictionary = _r.defaults
	for name: StringName in defaults:
		for f in 2:
			for id: String in defaults[name][f]:
				_seen.clear()
				_press_and_release(id)
				var fired := _seen.any(func(s: String) -> bool: return s.begins_with(name + ":"))
				check(fired, "%s from %s (%s): got %s" % [name, families[f], id, _seen])


func test_each_device_family_reaches_the_intents_it_should() -> void:
	# Every gameplay intent of 18 §3.2 has a keyboard/mouse binding; every one
	# of 18 §3.3 has a gamepad binding.
	var defaults: Dictionary = _r.defaults
	var pad_less := [&"crouch_hold", &"walk", &"map", &"console"]
	pad_less.append_array([&"belt_1", &"belt_2", &"belt_3", &"belt_4", &"belt_5", &"belt_6"])
	for name: StringName in defaults:
		if not name.begins_with("look_") and name != &"rotate_ccw":
			check(not defaults[name][0].is_empty(), "%s has a keyboard/mouse binding" % name)
		if not name in pad_less:
			check(not defaults[name][1].is_empty(), "%s has a gamepad binding" % name)


func test_glyphs_follow_the_device_on_the_same_event() -> void:
	var changes: Array[int] = []
	_r.device_changed.connect(func(d: int) -> void: changes.append(d))
	_r.handle_event(_r.event_from_id("key:%d" % KEY_W))
	check_eq(_r.glyph(&"jump"), "key:%d" % KEY_SPACE)
	_r.handle_event(_r.event_from_id("pad:%d" % JOY_BUTTON_Y))
	check_eq(_r.glyph(&"jump"), "pad:%d" % JOY_BUTTON_A)
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	_r.handle_event(touch)
	check_eq(_r.glyph(&"jump"), "touch:jump")
	check_eq(changes, [RouterScript.Device.GAMEPAD, RouterScript.Device.TOUCH] as Array[int])


func test_emulated_mouse_does_not_leave_touch() -> void:
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	_r.handle_event(touch)
	var mouse := InputEventMouseButton.new()
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	_r.handle_event(mouse)
	check_eq(_r.device, RouterScript.Device.TOUCH)


func test_tap_and_hold() -> void:
	var e: InputEvent = _r.event_from_id("key:%d" % KEY_E)
	_r.handle_event(e)
	_r.advance(0.1)
	_r.handle_event(_released(e))
	check_eq(_seen, ["interact:tap"] as Array[String])
	_seen.clear()
	_r.handle_event(e)
	_r.advance(0.2)
	_r.advance(0.15)
	check_eq(_seen, ["interact:hold"] as Array[String], "hold reported at 0.3 s")
	_r.advance(1.0)
	_r.handle_event(_released(e))
	check_eq(_seen, ["interact:hold", "interact:release"] as Array[String], "hold reported once")


func test_gamepad_journal_hold_is_map() -> void:
	var e: InputEvent = _r.event_from_id("pad:%d" % JOY_BUTTON_RIGHT_STICK)
	_r.handle_event(e)
	_r.advance(0.31)
	_r.handle_event(_released(e))
	check_eq(_seen, ["map:press", "journal:release"] as Array[String])


func test_mouse_wheel_rotates_while_placing() -> void:
	_r.placing = true
	_r.handle_event(_r.event_from_id("mouse:%d" % MOUSE_BUTTON_WHEEL_UP))
	check_eq(_seen, ["rotate_cw:press"] as Array[String])
	_r.placing = false
	_seen.clear()
	_r.handle_event(_r.event_from_id("mouse:%d" % MOUSE_BUTTON_WHEEL_UP))
	check_eq(_seen, ["belt_prev:press"] as Array[String])


func test_device_switch_releases_holds() -> void:
	_r.handle_event(_r.event_from_id("key:%d" % KEY_Q))
	_r.handle_event(_r.event_from_id("pad:%d" % JOY_BUTTON_A))
	check(_seen.has("drop:release"), "drop released: %s" % [_seen])


func test_mouse_look_uses_sensitivity_and_invert() -> void:
	var sx: float = Settings.get_value("controls", "sensitivity_x")
	var sy: float = Settings.get_value("controls", "sensitivity_y")
	var inv: bool = Settings.get_value("controls", "invert_y")
	Settings.set_value("controls", "sensitivity_x", 2.0)
	Settings.set_value("controls", "sensitivity_y", 0.5)
	Settings.set_value("controls", "invert_y", true)
	var m := InputEventMouseMotion.new()
	m.relative = Vector2(10, 4)
	_r.handle_event(m)
	_r.handle_event(m)
	check_eq(_r.consume_look_delta(), Vector2(40, -4))
	check_eq(_r.consume_look_delta(), Vector2.ZERO, "consumed")
	Settings.set_value("controls", "sensitivity_x", sx)
	Settings.set_value("controls", "sensitivity_y", sy)
	Settings.set_value("controls", "invert_y", inv)


func test_binding_ids_round_trip() -> void:
	var defaults: Dictionary = _r.defaults
	for name: StringName in defaults:
		for family: Array in defaults[name]:
			for id: String in family:
				check_eq(_r.id_from_event(_r.event_from_id(id)), id)
	check(_r.event_from_id("axis:1:x") == null, "bad sign")
	check(_r.event_from_id("nope:1") == null, "bad kind")
	check(_r.event_from_id("key:") == null, "no number")


func _press_and_release(id: String) -> void:
	var e: InputEvent = _r.event_from_id(id)
	_r.handle_event(e)
	_r.handle_event(_released(e))
	_r.advance(0.0)


func _released(e: InputEvent) -> InputEvent:
	var r: InputEvent = e.duplicate()
	if r is InputEventJoypadMotion:
		(r as InputEventJoypadMotion).axis_value = 0.0
	elif r is InputEventKey or r is InputEventMouseButton or r is InputEventJoypadButton:
		r.set("pressed", false)
	return r


func test_live_router_moves_from_engine_input() -> void:
	var w: InputEvent = InputRouter.event_from_id("key:%d" % KEY_W)
	Input.parse_input_event(w)
	Input.flush_buffered_events()  # the headless display server does not flush
	await tree.process_frame
	check_eq(InputRouter.move_vector(), Vector2(0, -1), "W held")
	Input.parse_input_event(_released(w))
	Input.flush_buffered_events()
	await tree.process_frame
	check_eq(InputRouter.move_vector(), Vector2.ZERO, "W released")
