extends TestCase
## Settings: round trip through the file, type checks, bad files.

const DIR := "user://tests"
const SettingsScript := preload("res://src/core/settings.gd")

var _a: Node
var _b: Node


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_a = _fresh()
	_b = _fresh()


func after_each() -> void:
	_a.free()
	_b.free()
	DirAccess.remove_absolute(DIR.path_join("settings.cfg"))
	DirAccess.remove_absolute(DIR.path_join("settings.cfg.tmp"))


func _fresh() -> Node:
	var s: Node = SettingsScript.new()
	s.path = DIR.path_join("settings.cfg")
	return s


func test_every_key_round_trips_through_the_file() -> void:
	# A changed value of the default's type for every key.
	var written := {}
	var keys: Dictionary = _a.keys()
	for section: String in keys:
		for key: String in keys[section]:
			var value: Variant = _changed(_a.default_value(section, key))
			check(_a.set_value(section, key, value), "set %s/%s" % [section, key])
			written["%s/%s" % [section, key]] = value
	check_eq(_a.save_file(), OK, "save")
	check_eq(_b.load_file(), OK, "load")
	for id: String in written:
		var parts := id.split("/")
		check_eq(_b.get_value(parts[0], parts[1]), written[id], id)
	check(not FileAccess.file_exists(DIR.path_join("settings.cfg.tmp")), "no temp file left")


func test_missing_file_gives_defaults() -> void:
	check_eq(_a.load_file(), OK)
	check_eq(_a.get_value("gameplay", "head_bob"), 0.25)
	check_eq(_a.get_value("video", "preset"), "")


func test_wrong_types_and_unknown_keys_are_refused() -> void:
	check(not _a.set_value("video", "vsync", "yes"), "string for a bool")
	check(not _a.set_value("video", "no_such_key", 1), "unknown key")
	check(not _a.set_value("no_such_section", "fov", 1.0), "unknown section")
	check(_a.set_value("video", "fov", 80), "int accepted for a float")
	check_eq(typeof(_a.get_value("video", "fov")), TYPE_FLOAT)


func test_wrong_type_in_the_file_reads_as_the_default() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "vsync", "not a bool")
	cfg.set_value("audio", "music", 0.5)
	cfg.save(DIR.path_join("settings.cfg"))
	_a.load_file()
	check_eq(_a.get_value("video", "vsync"), true)
	check_eq(_a.get_value("audio", "music"), 0.5)


func test_unreadable_file_gives_defaults() -> void:
	var f := FileAccess.open(DIR.path_join("settings.cfg"), FileAccess.WRITE)
	f.store_string("[video\nfov = = =\n")
	f.close()
	expect_engine_error("ConfigFile parse error")
	check(_a.load_file() != OK, "error reported")
	check_eq(_a.get_value("video", "fov"), _a.default_value("video", "fov"))


func test_changed_is_emitted_once_per_real_change() -> void:
	var seen: Array[String] = []
	_a.changed.connect(func(section: String, key: String) -> void: seen.append(section + "/" + key))
	_a.set_value("audio", "music", 0.4)
	_a.set_value("audio", "music", 0.4)
	_a.set_value("audio", "music", "loud")
	check_eq(seen, ["audio/music"] as Array[String])


func test_returned_dictionaries_are_copies() -> void:
	_a.set_value("controls", "bindings", {"jump": ["space"]})
	var got: Dictionary = _a.get_value("controls", "bindings")
	got["jump"] = ["x"]
	check_eq(_a.get_value("controls", "bindings"), {"jump": ["space"]})
	var d: Dictionary = _a.default_value("controls", "touch_layout")
	d["moved"] = true
	check_eq(_a.default_value("controls", "touch_layout"), {})


func _changed(value: Variant) -> Variant:
	match typeof(value):
		TYPE_BOOL:
			return not value
		TYPE_INT:
			return value + 7
		TYPE_FLOAT:
			return value + 0.5
		TYPE_STRING:
			return value + "x"
		TYPE_DICTIONARY:
			return {"k": [1, 2], "n": 0.5}
	return value
