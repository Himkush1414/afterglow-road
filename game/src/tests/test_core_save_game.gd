extends TestCase
## SaveGame: round-trip equality (the T-12-9 pattern), write order and
## backups, fallback on corruption, section rules.

const DIR := "user://tests/saves"
const SLOT := "slot_1"

var _data := {}
var _loaded: Variant = null
var _regions := {}


func before_each() -> void:
	_wipe(DIR)
	SaveGame.saves_dir = DIR
	_data = _sample(1)
	_loaded = null
	_regions = {}
	SaveGame.register_section("probe", func() -> Variant: return _data.duplicate(true), _accept)
	SaveGame.region_source = func() -> Dictionary: return _regions
	SaveGame.meta_source = func() -> Dictionary: return {"day": 3}


func after_each() -> void:
	SaveGame.version = SaveGame.SAVE_VERSION
	SaveGame.migrations = {}
	SaveGame.region_migrations = {}
	SaveGame.unregister_section("probe")
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	SaveGame.region_source = func() -> Dictionary: return {}
	SaveGame.meta_source = func() -> Dictionary: return {}
	_wipe(DIR)


func test_round_trip_keeps_every_value_and_type() -> void:
	_regions = {Vector2i(2, 5): {"removed": PackedInt64Array([7, 1 << 41]), "visited_gmin": 12.5}}
	check_eq(SaveGame.save_slot(SLOT), OK)
	check_eq(SaveGame.load_slot(SLOT), OK)
	check_eq(_loaded, _data, "state round trip")
	check_eq(typeof(_loaded.ids), TYPE_PACKED_INT64_ARRAY, "packed array type kept")
	check_eq(typeof(_loaded.name), TYPE_STRING_NAME, "StringName kept")
	check_eq(
		SaveGame.load_region(SLOT, Vector2i(2, 5)), _regions[Vector2i(2, 5)], "region round trip"
	)
	check_eq(SaveGame.load_region(SLOT, Vector2i(0, 0)), {}, "unsaved region is empty")
	check_eq(SaveGame.last_source, SaveGame.STATE)
	var meta: Dictionary = SaveGame.read_meta(SLOT)
	check_eq([int(meta.day), meta.slot, int(meta.save_version)], [3, SLOT, SaveGame.SAVE_VERSION])
	check(meta.created_utc != "" and meta.saved_utc != "", "timestamps")


func test_backups_rotate_and_creation_time_stays() -> void:
	for i: int in [1, 2, 3]:
		_data = _sample(i)
		check_eq(SaveGame.save_slot(SLOT), OK)
	var first: Dictionary = SaveGame.read_meta(SLOT)
	check_eq(_state_value(SaveGame.STATE), 3)
	check_eq(_state_value(SaveGame.BACKUPS[0]), 2)
	check_eq(_state_value(SaveGame.BACKUPS[1]), 1)
	check(not FileAccess.file_exists(_path(SaveGame.STATE + SaveGame.TMP)), "no temporary left")
	check_eq(SaveGame.read_meta(SLOT).created_utc, first.created_utc)


func test_a_corrupt_state_falls_back_to_the_backups() -> void:
	for i: int in [1, 2, 3]:
		_data = _sample(i)
		SaveGame.save_slot(SLOT)
	_truncate(SaveGame.STATE)
	check_eq(SaveGame.load_slot(SLOT), OK)
	check_eq([SaveGame.last_source, _loaded.n], [SaveGame.BACKUPS[0], 2], "cut in half")
	_garble(SaveGame.STATE)
	check_eq(SaveGame.load_slot(SLOT), OK)
	check_eq([SaveGame.last_source, _loaded.n], [SaveGame.BACKUPS[0], 2], "garbled")
	_flip_a_byte(SaveGame.BACKUPS[0])
	check_eq(SaveGame.load_slot(SLOT), OK)
	check_eq([SaveGame.last_source, _loaded.n], [SaveGame.BACKUPS[1], 1], "one byte changed")
	_garble(SaveGame.BACKUPS[1])
	check_eq(SaveGame.load_slot(SLOT), ERR_FILE_CORRUPT, "nothing readable")


func test_section_rules() -> void:
	check(not SaveGame.register_section("probe", func() -> Variant: return 0, _accept), "dup")
	check_eq(SaveGame.load_slot("slot_2"), ERR_FILE_CORRUPT, "no save")
	SaveGame.save_slot(SLOT)
	SaveGame.unregister_section("probe")
	var refused := func(_d: Variant) -> bool: return false
	SaveGame.register_section("probe", func() -> Variant: return 0, refused)
	check_eq(SaveGame.load_slot(SLOT), ERR_INVALID_DATA, "a section can refuse its data")
	SaveGame.unregister_section("probe")
	SaveGame.register_section("probe", func() -> Variant: return 0, _accept)
	SaveGame.register_section("later", func() -> Variant: return 0, _accept)
	check_eq(SaveGame.load_slot(SLOT), OK, "a section missing from an older file is skipped")
	SaveGame.unregister_section("later")


func test_older_files_are_migrated_step_by_step() -> void:
	_regions = {Vector2i(1, 1): {"old": 5}}
	SaveGame.save_slot(SLOT)  # version 1
	SaveGame.version = 3
	SaveGame.migrations = {1: _rename.bind("n", "m"), 2: _rename.bind("m", "count")}
	SaveGame.region_migrations = {1: _rename.bind("old", "mid"), 2: _rename.bind("mid", "new")}
	check_eq(SaveGame.load_slot(SLOT), OK)
	check_eq([_loaded.get("count"), _loaded.has("n")], [1, false], "state stepped 1 -> 3")
	check_eq(SaveGame.load_region(SLOT, Vector2i(1, 1)), {"new": 5}, "region stepped 1 -> 3")
	SaveGame.save_slot(SLOT)  # now version 3 on disk
	SaveGame.migrations = {}
	check_eq(SaveGame.load_slot(SLOT), OK, "a current file needs no step")
	check_eq(int(SaveGame.read_meta(SLOT).save_version), 3)


func test_missing_steps_and_newer_files_are_refused() -> void:
	SaveGame.save_slot(SLOT)
	SaveGame.version = 2
	check_eq(SaveGame.load_slot(SLOT), ERR_FILE_CORRUPT, "no step from 1: nothing readable")
	SaveGame.migrations = {1: func(_d: Dictionary) -> Variant: return null}
	check_eq(SaveGame.load_slot(SLOT), ERR_FILE_CORRUPT, "a failing step refuses the file")
	SaveGame.migrations = {1: func(d: Dictionary) -> Dictionary: return d}
	SaveGame.save_slot(SLOT)  # version 2 on disk
	SaveGame.version = 1
	check_eq(SaveGame.load_slot(SLOT), ERR_FILE_UNRECOGNIZED, "newer save refused")
	check_eq(SaveGame.load_region(SLOT, Vector2i(9, 9)), {}, "no region file")


func _rename(d: Dictionary, from: String, to: String) -> Dictionary:
	var out := d.duplicate(true)
	if out.has("probe"):
		out.probe[to] = out.probe[from]
		out.probe.erase(from)
	else:
		out[to] = out[from]
		out.erase(from)
	return out


func _accept(d: Variant) -> bool:
	_loaded = d
	return true


func _sample(n: int) -> Dictionary:
	return {
		"n": n,
		"name": &"probe",
		"pos": Vector3(1.5, -2.25, 4096.125),
		"xform": Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0.3)), Vector3(9, 8, 7)),
		"ids": PackedInt64Array([1 << 40, (1 << 40) + n]),
		"flags": PackedStringArray(["a", "b"]),
		"nested": {"list": [1, 2.5, null, "x"], 3: true},
	}


func _path(file: String) -> String:
	return DIR.path_join(SLOT).path_join(file)


func _state_value(file: String) -> int:
	var v: Dictionary = SaveGame.read_var(_path(file))
	return v.probe.n


func _truncate(file: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(_path(file))
	var f := FileAccess.open(_path(file), FileAccess.WRITE)
	f.store_buffer(bytes.slice(0, bytes.size() / 2))
	f.close()


func _flip_a_byte(file: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(_path(file))
	bytes[bytes.size() - 3] ^= 0x10
	var f := FileAccess.open(_path(file), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _garble(file: String) -> void:
	var f := FileAccess.open(_path(file), FileAccess.WRITE)
	f.store_string("not a save file")
	f.close()


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
