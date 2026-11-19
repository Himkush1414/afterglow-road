extends Node
## Autoload "InputRouter". Turns keyboard, mouse, gamepad and touch input
## into intents; gameplay code reads only intents. Each intent is an
## InputMap action of the same name, filled from `defaults`. Bindings are
## written as ids ("key:<physical keycode>", "mouse:<button>", "pad:<button>",
## "axis:<axis>:+|-") which also serve as glyph ids for the UI.

signal intent(name: StringName, kind: StringName)
signal device_changed(device: Device)

enum Device { KEYBOARD_MOUSE, GAMEPAD, TOUCH }

const HOLD_SECONDS := 0.3
const STICK_DEAD_ZONE := 0.15
const STICK_CURVE := 2.0
const AXIS_PRESS := 0.5
const AXIS_DEVICE_SWITCH := 0.2
## Intents reported as "tap" or "hold" instead of "press"/"release".
const TAP_HOLD: Array[StringName] = [&"interact", &"drop", &"journal"]
## Mouse wheel ids that turn into rotate while placing.
const WHEEL_ROTATE := {"mouse:4": &"rotate_cw", "mouse:5": &"rotate_ccw"}  # wheel up / down

## Default bindings per intent: [keyboard/mouse ids, gamepad ids] (18 §3.2, §3.3).
var defaults := _make_defaults()

## Set by the placement code: the mouse wheel rotates instead of changing slot.
var placing := false
var device := Device.KEYBOARD_MOUSE
var _held := {}  # tap/hold intent -> seconds held, or -1 once reported as hold
var _look_delta := Vector2.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	register_actions()


func _input(event: InputEvent) -> void:
	handle_event(event)


func _process(delta: float) -> void:
	advance(delta)


## Creates or resets every intent action with its default bindings.
func register_actions() -> void:
	for name: StringName in defaults:
		if not InputMap.has_action(name):
			InputMap.add_action(name, AXIS_PRESS)
		InputMap.action_erase_events(name)
		for family: Array in defaults[name]:
			for id: String in family:
				InputMap.action_add_event(name, event_from_id(id))


## Device detection, tap/hold timing, wheel-to-rotate and look deltas.
func handle_event(event: InputEvent) -> void:
	_detect_device(event)
	if event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION:
		_look_delta += (event as InputEventMouseMotion).relative * _look_scale()
	var id := id_from_event(event)
	if placing and WHEEL_ROTATE.has(id) and event.is_pressed():
		intent.emit(WHEEL_ROTATE[id], &"press")
		if is_inside_tree():
			get_viewport().set_input_as_handled()
		return
	for name: StringName in TAP_HOLD:
		if event.is_action_pressed(name) and not _held.has(name):
			_held[name] = 0.0
		elif event.is_action_released(name) and _held.has(name):
			var held_time: float = _held[name]
			_held.erase(name)
			if held_time >= 0.0:
				intent.emit(name, &"tap")
			else:
				intent.emit(name, &"release")
	for name: StringName in defaults:
		if name in TAP_HOLD:
			continue
		if event.is_action_pressed(name):
			intent.emit(name, &"press")
		elif event.is_action_released(name):
			intent.emit(name, &"release")


## Reports holds once they last HOLD_SECONDS. A gamepad journal hold is map.
func advance(delta: float) -> void:
	for name: StringName in _held.keys():
		var held_time: float = _held[name]
		if held_time < 0.0:
			continue
		held_time += delta
		if held_time >= HOLD_SECONDS:
			_held[name] = -1.0
			if name == &"journal" and device == Device.GAMEPAD:
				intent.emit(&"map", &"press")
			else:
				intent.emit(name, &"hold")
		else:
			_held[name] = held_time


func move_vector() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")


## Mouse look since the last call: pixels times the sensitivity settings,
## y negated when invert_y is on.
func consume_look_delta() -> Vector2:
	var d := _look_delta
	_look_delta = Vector2.ZERO
	return d


## Right-stick look rate, -1…1 per axis after dead zone and curve, times
## the sensitivity settings (y negated when invert_y is on).
func look_rate() -> Vector2:
	var v := Input.get_vector(
		&"look_left", &"look_right", &"look_up", &"look_down", STICK_DEAD_ZONE
	)
	return v.normalized() * pow(v.length(), STICK_CURVE) * _look_scale()


## Glyph id of the first binding of the intent for the current device;
## "touch:<intent>" on touch; "" when the device has no binding.
func glyph(name: StringName) -> String:
	if device == Device.TOUCH:
		return "touch:%s" % name
	for e in InputMap.action_get_events(name):
		var id := id_from_event(e)
		if (device == Device.GAMEPAD) == (id.begins_with("pad:") or id.begins_with("axis:")):
			return id
	return ""


func id_from_event(event: InputEvent) -> String:
	if event is InputEventKey:
		var k := event as InputEventKey
		return "key:%d" % (k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode)
	if event is InputEventMouseButton:
		return "mouse:%d" % (event as InputEventMouseButton).button_index
	if event is InputEventJoypadButton:
		return "pad:%d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		return "axis:%d:%s" % [m.axis, "-" if m.axis_value < 0.0 else "+"]
	return ""


## The event a binding id stands for (pressed / full deflection), or null.
func event_from_id(id: String) -> InputEvent:
	var parts := id.split(":")
	if parts.size() < 2 or not parts[1].is_valid_int():
		return null
	var n := parts[1].to_int()
	var out: InputEvent = null
	match parts[0]:
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = n as Key
			k.pressed = true
			out = k
		"mouse":
			var b := InputEventMouseButton.new()
			b.button_index = n as MouseButton
			b.pressed = true
			out = b
		"pad":
			var p := InputEventJoypadButton.new()
			p.button_index = n as JoyButton
			p.pressed = true
			out = p
		"axis":
			if parts.size() == 3 and parts[2] in ["+", "-"]:
				var a := InputEventJoypadMotion.new()
				a.axis = n as JoyAxis
				a.axis_value = 1.0 if parts[2] == "+" else -1.0
				out = a
	return out


func _detect_device(event: InputEvent) -> void:
	var now := device
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		now = Device.TOUCH
	elif event is InputEventJoypadButton:
		now = Device.GAMEPAD
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > AXIS_DEVICE_SWITCH:
			now = Device.GAMEPAD
	elif event is InputEventKey or event is InputEventMouse:
		if event.device != InputEvent.DEVICE_ID_EMULATION:
			now = Device.KEYBOARD_MOUSE
	if now != device:
		device = now
		_release_holds()
		device_changed.emit(device)


## Held actions are released on a device switch (18 §13).
func _release_holds() -> void:
	for name: StringName in _held.keys():
		intent.emit(name, &"release")
	_held.clear()


func _look_scale() -> Vector2:
	var y := float(Settings.get_value("controls", "sensitivity_y"))
	if Settings.get_value("controls", "invert_y"):
		y = -y
	return Vector2(float(Settings.get_value("controls", "sensitivity_x")), y)


func _make_defaults() -> Dictionary:
	var table := {
		&"move_forward": [[_key(KEY_W)], [_axis(JOY_AXIS_LEFT_Y, -1)]],
		&"move_back": [[_key(KEY_S)], [_axis(JOY_AXIS_LEFT_Y, 1)]],
		&"move_left": [[_key(KEY_A)], [_axis(JOY_AXIS_LEFT_X, -1)]],
		&"move_right": [[_key(KEY_D)], [_axis(JOY_AXIS_LEFT_X, 1)]],
		&"look_up": [[], [_axis(JOY_AXIS_RIGHT_Y, -1)]],
		&"look_down": [[], [_axis(JOY_AXIS_RIGHT_Y, 1)]],
		&"look_left": [[], [_axis(JOY_AXIS_RIGHT_X, -1)]],
		&"look_right": [[], [_axis(JOY_AXIS_RIGHT_X, 1)]],
		&"jump": [[_key(KEY_SPACE)], [_pad(JOY_BUTTON_A)]],
		&"sprint": [[_key(KEY_SHIFT)], [_pad(JOY_BUTTON_LEFT_STICK)]],
		&"crouch": [[_key(KEY_C)], [_pad(JOY_BUTTON_B)]],
		&"crouch_hold": [[_key(KEY_CTRL)], []],
		&"walk": [[_key(KEY_ALT)], []],
		&"interact": [[_key(KEY_E)], [_pad(JOY_BUTTON_X)]],
		&"primary": [[_mouse(MOUSE_BUTTON_LEFT)], [_axis(JOY_AXIS_TRIGGER_RIGHT, 1)]],
		&"secondary": [[_mouse(MOUSE_BUTTON_RIGHT)], [_axis(JOY_AXIS_TRIGGER_LEFT, 1)]],
		&"drop": [[_key(KEY_Q)], [_pad(JOY_BUTTON_DPAD_DOWN)]],
		&"rotate_cw": [[_key(KEY_R)], [_pad(JOY_BUTTON_DPAD_RIGHT)]],
		&"rotate_ccw": [[], [_pad(JOY_BUTTON_DPAD_LEFT)]],
		&"belt_next": [[_mouse(MOUSE_BUTTON_WHEEL_DOWN)], [_pad(JOY_BUTTON_RIGHT_SHOULDER)]],
		&"belt_prev": [[_mouse(MOUSE_BUTTON_WHEEL_UP)], [_pad(JOY_BUTTON_LEFT_SHOULDER)]],
		&"offhand": [[_key(KEY_F)], [_pad(JOY_BUTTON_DPAD_UP)]],
		&"inventory": [[_key(KEY_TAB), _key(KEY_I)], [_pad(JOY_BUTTON_BACK)]],
		&"build": [[_key(KEY_B)], [_pad(JOY_BUTTON_Y)]],
		&"journal": [[_key(KEY_J)], [_pad(JOY_BUTTON_RIGHT_STICK)]],
		&"map": [[_key(KEY_M)], []],
		&"pause": [[_key(KEY_ESCAPE)], [_pad(JOY_BUTTON_START)]],
		&"back": [[_key(KEY_ESCAPE)], [_pad(JOY_BUTTON_B)]],
	}
	for slot in 6:
		table[StringName("belt_%d" % (slot + 1))] = [[_key(KEY_1 + slot)], []]
	if OS.has_feature("dev") or OS.has_feature("editor"):
		table[&"console"] = [[_key(KEY_QUOTELEFT)], []]
	return table


func _key(code: Key) -> String:
	return "key:%d" % code


func _mouse(button: MouseButton) -> String:
	return "mouse:%d" % button


func _pad(button: JoyButton) -> String:
	return "pad:%d" % button


func _axis(axis: JoyAxis, sign: int) -> String:
	return "axis:%d:%s" % [axis, "+" if sign > 0 else "-"]
