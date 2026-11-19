extends TestCase
## InputRouter rebinding: T-18-5 and the conflict rules.

const RouterScript := preload("res://src/core/input_router.gd")
const KB := 0
const PAD := 1

var key_f := "key:%d" % KEY_F
var key_e := "key:%d" % KEY_E
var key_esc := "key:%d" % KEY_ESCAPE
var _r: Node
var _path := ""


func before_each() -> void:
	_path = Settings.path
	Settings.set_value("controls", "bindings", {})
	_r = RouterScript.new()
	_r.register_actions()


func after_each() -> void:
	_r.free()
	DirAccess.remove_absolute("user://tests/settings.cfg")
	Settings.path = _path
	Settings.set_value("controls", "bindings", {})
	InputRouter.register_actions()


func test_rebinding_interact_to_f_survives_a_reload() -> void:
	var conflicts: Variant = _r.rebind(&"interact", KB, key_f)
	check_eq(conflicts, [&"offhand"] as Array[StringName], "conflict reported")
	check(InputMap.event_is_action(_r.event_from_id(key_f), &"interact"), "F triggers interact")
	check(not InputMap.event_is_action(_r.event_from_id(key_e), &"interact"), "E no longer does")
	DirAccess.make_dir_recursive_absolute("user://tests")
	Settings.path = "user://tests/settings.cfg"
	check_eq(Settings.save_file(), OK)
	Settings.set_value("controls", "bindings", {})
	check_eq(Settings.load_file(), OK)
	var again: Node = RouterScript.new()
	again.register_actions()
	check_eq(again.bindings(&"interact", KB), [key_f])
	check_eq(again.bindings(&"offhand", KB), [])
	check_eq(again.bindings(&"interact", PAD), [_r.defaults[&"interact"][PAD][0]], "pad untouched")
	again.free()


func test_taking_a_required_input_is_reported() -> void:
	check_eq(_r.missing_required(KB), [] as Array[StringName])
	var conflicts: Variant = _r.rebind(&"offhand", KB, key_e)
	check_eq(conflicts, [&"interact"] as Array[StringName])
	check_eq(_r.missing_required(KB), [&"interact"] as Array[StringName])
	check_eq(_r.missing_required(PAD), [] as Array[StringName])


func test_the_ui_only_intent_keeps_its_shared_input() -> void:
	var conflicts: Variant = _r.rebind(&"crouch_hold", KB, key_esc)
	check_eq(conflicts, [&"pause"] as Array[StringName])
	check_eq(_r.bindings(&"back", KB), [key_esc])


func test_invalid_rebinds_are_refused() -> void:
	check(_r.rebind(&"jump", KB, "pad:0") == null, "gamepad id in the keyboard family")
	check(_r.rebind(&"no_such_intent", KB, key_f) == null, "unknown intent")
	check(_r.rebind(&"jump", PAD, "pad:x") == null, "malformed id")
	check_eq(_r.bindings(&"jump", KB), _r.defaults[&"jump"][KB], "jump unchanged")


func test_bad_saved_bindings_are_ignored() -> void:
	Settings.set_value(
		"controls", "bindings", {"jump": [["pad:0"], []], "nope": [[], []], "walk": "x"}
	)
	_r.register_actions()
	check_eq(_r.bindings(&"jump", KB), _r.defaults[&"jump"][KB])
	check_eq(_r.bindings(&"walk", KB), _r.defaults[&"walk"][KB])


func test_reset_restores_the_defaults() -> void:
	_r.rebind(&"interact", KB, key_f)
	_r.reset_bindings()
	check_eq(_r.bindings(&"interact", KB), [key_e])
	check_eq(_r.bindings(&"offhand", KB), [key_f])
	check_eq(Settings.get_value("controls", "bindings"), {})
