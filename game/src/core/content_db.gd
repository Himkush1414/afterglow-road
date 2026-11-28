extends Node
## Autoload "ContentDB". Reads every `*.json` in `<root>/data/` and checks it
## against `schema.json` (03 §9, Q-31): unknown files, parse errors, schema
## errors, duplicate ids and references to missing ids are all errors, each
## with file, key and reason. Data is read-only after loading.
## A file entry in the schema: {"required": bool, "spec": <type spec>,
## "collections": {<name>: <root key of a list of entries with "id">}}.

const SCHEMA_PATH := "res://src/defs/schema.json"
const CONTENT_ROOT := "res://content"
const SAMPLE_ROOT := "res://content_sample"
const UI_TABLE := "res://ui/i18n/ui.csv"
const UI_SCENES := "res://ui"
const KEY_PATTERN := "^[a-z0-9_]+(\\.[a-z0-9_]+)*$"
## Collections whose entries name text: collection -> also needs "<key>.desc".
const TEXT_KEYS := {"items": true, "pieces": true, "nodes": false, "trees": false, "animals": false}

var root := ""
var schema_path := SCHEMA_PATH
var errors: PackedStringArray = []
var _files := {}
var _collections := {}
## collection -> id -> typed def
var _defs := {}
## Translations of the loaded tree, registered with the TranslationServer.
var _text: Array[Translation] = []


func _ready() -> void:
	load_root(default_root())


## `res://content` when it has data, else the public sample.
func default_root() -> String:
	return CONTENT_ROOT if DirAccess.dir_exists_absolute(CONTENT_ROOT + "/data") else SAMPLE_ROOT


func is_ok() -> bool:
	return errors.is_empty()


## Replaces all data with the content under `path`. Returns true when it
## loaded without errors; otherwise `errors` lists every problem and no data
## is kept.
func load_root(path: String) -> bool:
	root = path
	errors.clear()
	_files.clear()
	_collections.clear()
	_defs.clear()
	_unload_text()
	var schema: Variant = _read_json(schema_path)
	if not schema is Dictionary:
		return false
	var file_specs: Dictionary = schema.get("files", {})
	var checker := Schema.new(schema.get("types", {}))
	var data_dir := path + "/data"
	var found := PackedStringArray()
	if DirAccess.dir_exists_absolute(data_dir):
		found = DirAccess.get_files_at(data_dir)
	for file: String in found:
		if not file.ends_with(".json"):
			continue
		if not file_specs.has(file):
			errors.append("%s: no schema for this file" % file)
			continue
		var value: Variant = _read_json(data_dir + "/" + file)
		if typeof(value) == TYPE_NIL:
			continue
		checker.check(value, file_specs[file].spec, file)
		_files[file] = value
		_index(file, value, file_specs[file].get("collections", {}))
	for file: String in file_specs:
		if file_specs[file].get("required", false) and not file in found:
			errors.append("%s: required file is missing in %s" % [file, data_dir])
	errors.append_array(checker.errors)
	for r: Array in checker.refs:
		var where: Array = r[0] if r[0] is Array else [r[0]]
		if not where.any(func(c: String) -> bool: return entry(c, r[1]) != {}):
			errors.append("%s: '%s' is not an id in %s" % [r[2], r[1], " or ".join(where)])
	if not errors.is_empty():
		for e in errors:
			Log.error("content", e)
		_files.clear()
		_collections.clear()
		return false
	for file: String in _files:
		_deep_read_only(_files[file])
	_build_defs()
	_load_text(path + "/text")
	Log.info("content", "loaded %d files from %s" % [_files.size(), path])
	return true


## Text table problems of the loaded tree (T-18-11 data part), read from
## the source CSV files, so it runs in checks, not in exported builds: key
## format, keys defined twice, name and description keys missing for
## content entries, and scene texts that are not interface keys.
func text_problems() -> PackedStringArray:
	var out: PackedStringArray = []
	var key_re := RegEx.create_from_string(KEY_PATTERN)
	var ui := _csv_keys(UI_TABLE, key_re, {}, out)
	var content := {}
	var text_dir := root.path_join("text")
	if DirAccess.dir_exists_absolute(text_dir):
		for f in DirAccess.get_files_at(text_dir):
			if f.ends_with(".csv"):
				content.merge(_csv_keys(text_dir.path_join(f), key_re, ui, out))
	for collection: String in TEXT_KEYS:
		for id: String in ids(collection):
			var key: String = entry(collection, id).name_key
			for k: String in [key, key + ".desc"] if TEXT_KEYS[collection] else [key]:
				if not content.has(k):
					out.append("%s %s: text key '%s' is missing" % [collection, id, k])
	var text_re := RegEx.create_from_string('(?m)^text = "([^"]*)"')
	for f in DirAccess.get_files_at(UI_SCENES):
		if f.ends_with(".tscn"):
			var scene := FileAccess.get_file_as_string(UI_SCENES.path_join(f))
			for m in text_re.search_all(scene):
				if not ui.has(m.get_string(1)):
					out.append("%s: text '%s' is not an interface key" % [f, m.get_string(1)])
	return out


## Keys of the table at `path`; reports bad keys and keys already in `seen`
## or earlier in the same table.
func _csv_keys(path: String, key_re: RegEx, seen: Dictionary, out: PackedStringArray) -> Dictionary:
	var keys := {}
	var csv := FileAccess.open(path, FileAccess.READ)
	if csv == null:
		out.append("%s: cannot be read" % path)
		return keys
	csv.get_csv_line()
	var line := 1
	while not csv.eof_reached():
		var row := csv.get_csv_line()
		line += 1
		if row.size() == 0 or row[0] == "":
			continue
		var key := row[0]
		if key_re.search(key) == null:
			out.append("%s:%d: key '%s' is not lower case with dots" % [path.get_file(), line, key])
		if keys.has(key) or seen.has(key):
			out.append("%s:%d: key '%s' is defined twice" % [path.get_file(), line, key])
		keys[key] = true
	return keys


## The tuning group `group` (read-only), or an empty Dictionary.
func tuning(group: String) -> Dictionary:
	return (_files.get("tuning.json", {}) as Dictionary).get(group, {})


## Entry `id` of `collection` (read-only), or an empty Dictionary.
## The whole (read-only) content of one data file, e.g. "customization.json";
## null when the file is not loaded.
func file_data(file: String) -> Variant:
	return _files.get(file, null)


func entry(collection: String, id: String) -> Dictionary:
	return (_collections.get(collection, {}) as Dictionary).get(id, {})


func item(id: StringName) -> ItemDef:
	return (_defs.get("items", {}) as Dictionary).get(id)


func material(id: StringName) -> MaterialDef:
	return (_defs.get("materials", {}) as Dictionary).get(id)


func piece(id: StringName) -> PieceDef:
	return (_defs.get("pieces", {}) as Dictionary).get(id)


func recipe(id: StringName) -> RecipeDef:
	return (_defs.get("recipes", {}) as Dictionary).get(id)


func tree(id: StringName) -> TreeDef:
	return (_defs.get("trees", {}) as Dictionary).get(id)


func node(id: StringName) -> NodeDef:
	return (_defs.get("nodes", {}) as Dictionary).get(id)


func animal(id: StringName) -> AnimalDef:
	return (_defs.get("animals", {}) as Dictionary).get(id)


func loot(id: StringName) -> LootTable:
	return (_defs.get("loot", {}) as Dictionary).get(id)


## Ids of `collection` in file order.
func ids(collection: String) -> Array:
	return (_collections.get(collection, {}) as Dictionary).keys()


## Registers every translation imported from `<root>/text/*.csv`.
func _load_text(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in ResourceLoader.list_directory(dir):
		if file.ends_with(".translation"):
			var t := load(dir.path_join(file)) as Translation
			TranslationServer.add_translation(t)
			_text.append(t)


func _unload_text() -> void:
	for t in _text:
		TranslationServer.remove_translation(t)
	_text.clear()


func _build_defs() -> void:
	var builders := {
		"items": ItemDef.from_dict,
		"materials": MaterialDef.from_dict,
		"pieces": PieceDef.from_dict,
		"recipes": RecipeDef.from_dict,
		"trees": TreeDef.from_dict,
		"nodes": NodeDef.from_dict,
		"animals": AnimalDef.from_dict,
		"loot": LootTable.from_dict,
	}
	for name: String in builders:
		var by_id := {}
		for id: String in ids(name):
			by_id[StringName(id)] = (builders[name] as Callable).call(entry(name, id))
		_defs[name] = by_id


func _index(file: String, value: Variant, collections: Dictionary) -> void:
	for name: String in collections:
		var list: Variant = value.get(collections[name]) if value is Dictionary else null
		if not list is Array:
			continue
		var by_id: Dictionary = _collections.get_or_add(name, {})
		for i in (list as Array).size():
			var e: Variant = list[i]
			if not (e is Dictionary and e.get("id") is String):
				continue
			if by_id.has(e.id):
				errors.append("%s.%s[%d]: duplicate id '%s'" % [file, collections[name], i, e.id])
			by_id[e.id] = e


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		errors.append("%s: file not found" % path)
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		errors.append(
			"%s:%d: %s" % [path.get_file(), json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


func _deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		for v: Variant in (value as Dictionary).values():
			_deep_read_only(v)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for v: Variant in value:
			_deep_read_only(v)
		(value as Array).make_read_only()
