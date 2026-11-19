extends Node
## Autoload "SaveGame". Save and load orchestration (04 §3). Owners register
## a section of state.bin; region deltas come from one region source. Files
## are Dictionaries (`var_to_bytes`), ZSTD-compressed and framed with a
## hash (Q-37), written to a temporary file and renamed over the target;
## state.bin keeps two backups and loading falls back to them.

signal loaded(slot: String, source: String)
signal saved(slot: String, err: Error)

const SAVES_DIR := "user://saves"
const SAVE_VERSION := 1
const STATE := "state.bin"
const BACKUPS: Array[String] = ["state.bin.bak1", "state.bin.bak2"]
const META := "meta.json"
const REGIONS := "regions"
const TMP := ".tmp"
## File frame (Q-37): save version (4 bytes), raw size (8), SHA-256 of the
## compressed bytes (32).
const HEADER_BYTES := 44
const MAX_RAW_BYTES := 1 << 30

## Version this game writes; files of older versions are migrated on read.
var version := SAVE_VERSION
## Migration steps, from_version -> Callable(Dictionary) -> Dictionary, for
## state.bin and for region files. A missing step refuses the file.
var migrations := {}
var region_migrations := {}
## Folder that holds the slot folders; tests point it elsewhere.
var saves_dir := SAVES_DIR
## File state.bin was read from by the last successful load ("" before).
var last_source := ""
## Extra meta.json fields (day, clock, play_seconds, ...); returns a Dictionary.
var meta_source := func() -> Dictionary: return {}
## Region deltas to write: Dictionary[Vector2i, Dictionary].
var region_source := func() -> Dictionary: return {}
## Slot of the running game ("" on the title screen); autosaved and saved
## when the OS pauses the app or the window closes.
var active_slot := ""
## Real seconds between autosaves (tuning save.autosave_s; 0 = off).
var autosave_s := 0.0
## name -> [save: Callable() -> Variant, load: Callable(Variant) -> bool]
var _sections := {}
var _task := -1
var _since_save := 0.0


func _ready() -> void:
	autosave_s = float(ContentDB.tuning("save").get("autosave_s", 0.0))


func _process(delta: float) -> void:
	advance_autosave(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if active_slot != "":
			save_slot(active_slot)


## Counts real time and starts a background save of `active_slot` when the
## interval has passed since its last save.
func advance_autosave(delta: float) -> void:
	if active_slot == "" or autosave_s <= 0.0:
		return
	_since_save += delta
	if _since_save >= autosave_s and save_slot_async(active_slot):
		_since_save = 0.0


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


## Writes the slot now and returns when it is on disk (04 §3.4 order:
## region temporaries, state temporary, backup rotation, renames, meta last).
func save_slot(slot: String) -> Error:
	_wait_for_writer()
	var job := _snapshot(slot)
	var err := _write_job(job)
	_report(job, err)
	return err


## Takes the snapshot now and writes it on a worker thread; `saved` is
## emitted when it is on disk. Returns false (and starts nothing) while
## another write is running.
func save_slot_async(slot: String) -> bool:
	if is_writing():
		return false
	var job := _snapshot(slot)
	_task = WorkerThreadPool.add_task(
		func() -> void: _finish_async.call_deferred(job, _write_job(job))
	)
	return true


func is_writing() -> bool:
	return _task >= 0


func _finish_async(job: Dictionary, err: Error) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_report(job, err)


## Blocks until a running write is on disk; its report still follows.
func _wait_for_writer() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Everything a write needs, copied on the main thread so the game can go on
## changing its state while a worker writes.
func _snapshot(slot: String) -> Dictionary:
	var state := {}
	for name: String in _sections:
		var data: Variant = (_sections[name][0] as Callable).call()
		state[name] = data.duplicate(true) if data is Dictionary or data is Array else data
	# shortcut: positions are stored as they are; the map-coordinate
	# conversion of 04 §3.4 comes with WorldData.
	var regions: Dictionary = (region_source.call() as Dictionary).duplicate(true)
	var now := Time.get_datetime_string_from_system(true)
	var old: Variant = read_meta(slot)
	var meta: Dictionary = (meta_source.call() as Dictionary).duplicate(true)
	(
		meta
		. merge(
			{
				"save_version": version,
				"game_version": App.version(),
				"slot": slot,
				"created_utc": old.get("created_utc", now) if old is Dictionary else now,
				"saved_utc": now,
			},
			true
		)
	)
	return {
		"slot": slot,
		"dir": slot_dir(slot),
		"version": version,
		"state": state,
		"regions": regions,
		"meta": meta,
		"error": "",
	}


## File work only (safe on a worker thread: no logging, no scene access).
func _write_job(job: Dictionary) -> Error:
	var dir: String = job.dir
	var err := DirAccess.make_dir_recursive_absolute(dir.path_join(REGIONS))
	if err != OK:
		job.error = "cannot create %s" % dir
		return err
	var renames: Array[String] = []
	for r: Vector2i in job.regions:
		var path := dir.path_join(REGIONS).path_join("%d_%d.bin" % [r.x, r.y])
		err = _write_var(path + TMP, job.regions[r], job.version)
		if err != OK:
			job.error = "cannot write %s" % path
			return err
		renames.append(path)
	err = _write_var(dir.path_join(STATE) + TMP, job.state, job.version)
	if err != OK:
		job.error = "cannot write state"
		return err
	_rotate_backups(dir)
	renames.append(dir.path_join(STATE))
	for path in renames:
		err = DirAccess.rename_absolute(path + TMP, path)
		if err != OK:
			job.error = "cannot rename %s" % path
			return err
	err = _write_meta(dir, job.meta)
	if err != OK:
		job.error = "cannot write meta"
	return err


func _report(job: Dictionary, err: Error) -> void:
	if err != OK:
		_fail("%s: %s" % [job.slot, job.error], err)
	else:
		Log.info(
			"save",
			"saved %s (%d sections, %d regions)" % [job.slot, job.state.size(), job.regions.size()]
		)
	if err == OK and job.slot == active_slot:
		_since_save = 0.0
	saved.emit(job.slot, err)


## Reads the slot and hands each section to its owner. state.bin falls back
## to .bak1, then .bak2; `last_source` says which file was used.
func load_slot(slot: String) -> Error:
	var dir := slot_dir(slot)
	var meta: Variant = read_meta(slot)
	if not meta is Dictionary:
		return _fail("no readable meta in %s" % dir, ERR_FILE_CORRUPT)
	if int(meta.get("save_version", 0)) > version:
		return _fail("%s was saved by a newer game version" % slot, ERR_FILE_UNRECOGNIZED)
	var state: Variant = null
	var source := ""
	for file: String in [STATE] + BACKUPS:
		var read := read_versioned(dir.path_join(file))
		if not read.is_empty():
			state = _migrate(migrations, read[1], read[0])
		if state is Dictionary:
			source = file
			break
		Log.warn("save", "%s/%s unreadable or cannot be migrated" % [slot, file])
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
	var read := read_versioned(path)
	var data: Variant = null if read.is_empty() else _migrate(region_migrations, read[1], read[0])
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


func _write_meta(dir: String, meta: Dictionary) -> Error:
	var path := dir.path_join(META)
	var f := FileAccess.open(path + TMP, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(meta, "\t"))
	f.close()
	return DirAccess.rename_absolute(path + TMP, path)


func _write_var(path: String, value: Variant, file_version: int) -> Error:
	var raw := var_to_bytes(value)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_32(file_version)
	f.store_64(raw.size())
	f.store_buffer(_sha256(packed))
	f.store_buffer(packed)
	var err := f.get_error()
	f.close()
	return err


## Value stored by `_write_var` at `path`, or null when the file is missing,
## cut short or damaged (checked by hash before anything is decoded).
func read_var(path: String) -> Variant:
	var read := read_versioned(path)
	return null if read.is_empty() else read[1]


## [save_version, value] of the file at `path`, or [] (see `read_var`).
func read_versioned(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < HEADER_BYTES:
		return []
	var file_version := bytes.decode_u32(0)
	var raw_size := bytes.decode_u64(4)
	var packed := bytes.slice(HEADER_BYTES)
	if bytes.slice(12, HEADER_BYTES) != _sha256(packed) or raw_size > MAX_RAW_BYTES:
		return []
	return [file_version, bytes_to_var(packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD))]


## `data` stepped from `from` to `version`, or null when a step is missing,
## the file is newer than this game or a step does not return a Dictionary.
func _migrate(steps: Dictionary, data: Variant, from: int) -> Variant:
	if from > version or from < 1:
		Log.error("save", "file version %d cannot be read by version %d" % [from, version])
		return null
	for v in range(from, version):
		if not steps.has(v):
			Log.error("save", "no migration from version %d" % v)
			return null
		data = (steps[v] as Callable).call(data)
		if not data is Dictionary:
			Log.error("save", "migration from version %d failed" % v)
			return null
	return data


func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish()


func _fail(message: String, err: Error) -> Error:
	Log.error("save", "%s (%s)" % [message, error_string(err)])
	return err
