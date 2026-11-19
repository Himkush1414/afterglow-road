extends Node
## Autoload "Settings". Per-device user options in a ConfigFile. Reads fall
## back to the default when a key is missing or holds a value of the wrong
## type; writes are checked against the default's type.
## Conventions: video.preset "" = platform default; video.render_scale 0 and
## video.max_fps -1 = the preset's value; video.max_fps 0 = unlimited.

signal changed(section: String, key: String)

const PATH := "user://settings.cfg"
const SMALL_PHONE_INCHES := 5.5

var path := PATH
var _cfg := ConfigFile.new()
var _defaults := _make_defaults()


func _ready() -> void:
	load_file()


## Value of section/key, or its default.
func get_value(section: String, key: String) -> Variant:
	var fallback: Variant = default_value(section, key)
	var value: Variant = _cfg.get_value(section, key, fallback)
	if not _same_type(value, fallback):
		return fallback
	return value.duplicate(true) if value is Dictionary else value


## Sets section/key when the key exists and the value has the default's type
## (an int is accepted for a float). Returns false and logs otherwise.
func set_value(section: String, key: String, value: Variant) -> bool:
	if not has_key(section, key):
		Log.warn("settings", "unknown setting %s/%s" % [section, key])
		return false
	var fallback: Variant = default_value(section, key)
	if typeof(fallback) == TYPE_FLOAT and typeof(value) == TYPE_INT:
		value = float(value)
	if not _same_type(value, fallback):
		Log.warn(
			"settings", "wrong type for %s/%s: %s" % [section, key, type_string(typeof(value))]
		)
		return false
	if get_value(section, key) == value:
		return true
	_cfg.set_value(section, key, value)
	changed.emit(section, key)
	return true


func has_key(section: String, key: String) -> bool:
	return _defaults.has(section) and (_defaults[section] as Dictionary).has(key)


func default_value(section: String, key: String) -> Variant:
	if not has_key(section, key):
		return null
	var value: Variant = _defaults[section][key]
	# Containers are copied so callers cannot change the defaults.
	return value.duplicate(true) if value is Dictionary else value


## Section names and their keys, in a fixed order.
func keys() -> Dictionary:
	var out := {}
	for section: String in _defaults:
		out[section] = (_defaults[section] as Dictionary).keys()
	return out


## Loads the file; a missing file means all defaults. An unreadable file is
## logged and ignored (defaults stay) until the next save replaces it.
func load_file() -> Error:
	_cfg.clear()
	if not FileAccess.file_exists(path):
		return OK
	var err := _cfg.load(path)
	if err != OK:
		_cfg.clear()
		Log.warn("settings", "cannot read %s (%s); using defaults" % [path, error_string(err)])
	return err


## Writes to a temporary file and renames it, so a crash keeps the old file.
func save_file() -> Error:
	var tmp := path + ".tmp"
	var err := _cfg.save(tmp)
	if err == OK:
		err = DirAccess.rename_absolute(tmp, path)
	if err != OK:
		Log.error("settings", "cannot save %s (%s)" % [path, error_string(err)])
	return err


func _same_type(value: Variant, fallback: Variant) -> bool:
	return typeof(value) == typeof(fallback)


func _make_defaults() -> Dictionary:
	var phone := OS.has_feature("mobile")
	return {
		"video":
		{
			"preset": "",
			"render_scale": 0.0,
			"fov": 70.0 if phone else 75.0,
			"vsync": true,
			"max_fps": -1,
			"brightness": 1.0,
		},
		"audio":
		{
			"master": 1.0,
			"music": 1.0,
			"ambience": 1.0,
			"sfx": 1.0,
			"ui": 1.0,
			"mute_on_focus_loss": true,
		},
		"controls":
		{
			"sensitivity_x": 1.0,
			"sensitivity_y": 1.0,
			"invert_y": false,
			"toggle_crouch": false,
			"toggle_sprint": false,
			"gyro": false,
			"aim_assist": 0.0,
			"bindings": {},
			"touch_layout": {},
			"left_handed": false,
			"haptics": true,
			"labels_seen": false,
		},
		"gameplay":
		{
			"hud_scale": 1.15 if phone and _is_small_screen() else 1.0,
			"hints": true,
			"head_bob": 0.25,
			"camera_shake": 1.0,
			"show_map_marker": true,
			"minimal_hud": false,
			"bar_numbers": false,
		},
		"access":
		{
			"text_scale": 1.0,
			"high_contrast": false,
			"colour_blind_mode": "off",
			"hold_to_toggle": false,
			"subtitles": false,
			"reduce_flashing": false,
			"reduce_motion": false,
			"screen_reader": false,
		},
	}


## Diagonal under SMALL_PHONE_INCHES; false when the platform reports no DPI.
func _is_small_screen() -> bool:
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		return false
	return Vector2(DisplayServer.screen_get_size()).length() / dpi < SMALL_PHONE_INCHES
