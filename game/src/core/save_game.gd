extends Node
## Autoload "SaveGame". Save and load orchestration (04 §3). Owners register
## a section of state.bin; region deltas come from one region source. Files
## are Dictionaries (`var_to_bytes`), ZSTD-compressed and framed with a
## hash (Q-37), written to a temporary file and renamed over the target; state.bin keeps two backups and loading
## falls back to them.

signal loaded(slot: String, source: String)

const SAVES_DIR := "user://saves"
const SAVE_VERSION := 1
const STATE := "state.bin"
const BACKUPS: Array[String] = ["state.bin.bak1", "state.bin.bak2"]
const META := "meta.json"
const REGIONS := "regions"
const TMP := ".tmp"
## File frame (Q-37): raw size (8 bytes), SHA-256 of the compressed bytes (32).
const HEADER_BYTES := 40
const MAX_RAW_BYTES := 1 << 30

## Folder that holds the slot folders; tests point it elsewhere.
var saves_dir := SAVES_DIR
## File state.bin was read from by the last successful load ("" before).
var last_source := ""
## Extra meta.json fields (day, clock, play_seconds, ...); returns a Dictionary.
var meta_source := func() -> Dictionary: return {}
## Region deltas to write: Dictionary[Vector2i, Dictionary].
var region_source := func() -> Dictionary: return {}
## name -> [save: Callable() -> Variant, load: Callable(Variant) -> bool]
var _sections := {}


## Registers section `name` of state.bin. `save_fn()` returns its data;
## `load_fn(data)` restores it and returns false when the data is invalid.
func register_section(name: String, save_fn: Callable, load_fn: Callable) -> bool:
	if _sections.has(name):
		Log.error("save", "section %s already registered" % name)
		return false
	_sections[name] = [save_fn, load_fn]
	return true


func unregister_section(name: String) -> void:
	_sections.erase(name)


func slot_dir(slot: String) -> String:
	return saves_dir.path_join(slot)


func has_save(slot: String) -> bool:
	return FileAccess.file_exists(slot_dir(slot).path_join(META))


## Writes the slot (04 §3.4 order): region temporaries, state temporary,
## backup rotation, renames, meta.json last.
func save_slot(slot: String) -> Error:
	var dir := slot_dir(slot)
	var err := DirAccess.make_dir_recursive_absolute(dir.path_join(REGIONS))
	if err != OK:
		return _fail("cannot create %s" % dir, err)
	var state := {}
	for name: String in _sections:
		state[name] = (_sections[name][0] as Callable).call()
	# shortcut: positions are stored as they are; the map-coordinate conversion of 04 §3.4 comes with WorldData.
	var regions: Dictionary = region_source.call()
	var renames: Array[String] = []
	for r: Vector2i in regions:
		var path := dir.path_join(REGIONS).path_join("%d_%d.bin" % [r.x, r.y])
		err = _write_var(path + TMP, regions[r])
		if err != OK:
			return _fail("cannot write %s" % path, err)
		renames.append(path)
	err = _write_var(dir.path_join(STATE) + TMP, state)
	if err != OK:
		return _fail("cannot write state", err)
	_rotate_backups(dir)
	renames.append(dir.path_join(STATE))
	for path in renames:
		err = DirAccess.rename_absolute(path + TMP, path)
		if err != OK:
			return _fail("cannot rename %s" % path, err)
	err = _write_meta(dir, slot)
	if err != OK:
		return _fail("cannot write meta", err)
	Log.info("save", "saved %s (%d sections, %d regions)" % [slot, state.size(), regions.size()])
	return OK


## Reads the slot and hands each section to its owner. state.bin falls back
## to .bak1, then .bak2; `last_source` says which file was used.
func load_slot(slot: String) -> Error:
	var dir := slot_dir(slot)
	var meta: Variant = read_meta(slot)
	if not meta is Dictionary:
		return _fail("no readable meta in %s" % dir, ERR_FILE_CORRUPT)
	var state: Variant = null
	var source := ""
	for file: String in [STATE] + BACKUPS:
		state = read_var(dir.path_join(file))
		if state is Dictionary:
			source = file
			break
		Log.warn("save", "%s/%s unreadable" % [slot, file])
	if not state is Dictionary:
		return _fail("no readable state in %s" % dir, ERR_FILE_CORRUPT)
	for name: String in _sections:
		if not (state as Dictionary).has(name):
			continue
		if not (_sections[name][1] as Callable).call(state[name]):
			return _fail("section %s refused its data" % name, ERR_INVALID_DATA)
	last_source = source
	Log.info("save", "loaded %s from %s" % [slot, source])
	loaded.emit(slot, source)
	return OK


## Region delta of `region` in the slot, or {} when none was saved.
func load_region(slot: String, region: Vector2i) -> Dictionary:
	var path := slot_dir(slot).path_join(REGIONS).path_join("%d_%d.bin" % [region.x, region.y])
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = read_var(path)
	if not data is Dictionary:
		Log.error("save", "region file %s unreadable; region starts fresh" % path)
		return {}
	return data


## meta.json of the slot, or null when missing or unreadable.
func read_meta(slot: String) -> Variant:
	var path := slot_dir(slot).path_join(META)
	if not FileAccess.file_exists(path):
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else null


func _rotate_backups(dir: String) -> void:
	var files: Array[String] = [STATE]
	files.append_array(BACKUPS)
	for i in range(files.size() - 1, 0, -1):
		var from := dir.path_join(files[i - 1])
		if FileAccess.file_exists(from):
			DirAccess.rename_absolute(from, dir.path_join(files[i]))


func _write_meta(dir: String, slot: String) -> Error:
	var now := Time.get_datetime_string_from_system(true)
	var old: Variant = read_meta(slot)
	var meta: Dictionary = meta_source.call()
	(
		meta
		. merge(
			{
				"save_version": SAVE_VERSION,
				"game_version": App.version(),
				"slot": slot,
				"created_utc": old.get("created_utc", now) if old is Dictionary else now,
				"saved_utc": now,
			},
			true
		)
	)
	var path := dir.path_join(META)
	var f := FileAccess.open(path + TMP, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(meta, "\t"))
	f.close()
	return DirAccess.rename_absolute(path + TMP, path)


func _write_var(path: String, value: Variant) -> Error:
	var raw := var_to_bytes(value)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_64(raw.size())
	f.store_buffer(_sha256(packed))
	f.store_buffer(packed)
	var err := f.get_error()
	f.close()
	return err


## Value stored by `_write_var` at `path`, or null when the file is missing,
## cut short or damaged (checked by hash before anything is decoded).
func read_var(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < HEADER_BYTES:
		return null
	var raw_size := bytes.decode_u64(0)
	var packed := bytes.slice(HEADER_BYTES)
	if bytes.slice(8, HEADER_BYTES) != _sha256(packed) or raw_size > MAX_RAW_BYTES:
		return null
	return bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))


func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


func _fail(message: String, err: Error) -> Error:
	Log.error("save", "%s (%s)" % [message, error_string(err)])
	return err
