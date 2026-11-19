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

var root := ""
var schema_path := SCHEMA_PATH
var errors: PackedStringArray = []
var _files := {}
var _collections := {}
## collection -> id -> typed def
var _defs := {}


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
		if not (_collections.get(r[0], {}) as Dictionary).has(r[1]):
			errors.append("%s: '%s' is not an id in %s" % [r[2], r[1], r[0]])
	if not errors.is_empty():
		for e in errors:
			Log.error("content", e)
		_files.clear()
		_collections.clear()
		return false
	for file: String in _files:
		_deep_read_only(_files[file])
	_build_defs()
	Log.info("content", "loaded %d files from %s" % [_files.size(), path])
	return true


## The tuning group `group` (read-only), or an empty Dictionary.
func tuning(group: String) -> Dictionary:
	return (_files.get("tuning.json", {}) as Dictionary).get(group, {})


## Entry `id` of `collection` (read-only), or an empty Dictionary.
func entry(collection: String, id: String) -> Dictionary:
	return (_collections.get(collection, {}) as Dictionary).get(id, {})


func item(id: StringName) -> ItemDef:
	return (_defs.get("items", {}) as Dictionary).get(id)


func material(id: StringName) -> MaterialDef:
	return (_defs.get("materials", {}) as Dictionary).get(id)


## Ids of `collection` in file order.
func ids(collection: String) -> Array:
	return (_collections.get(collection, {}) as Dictionary).keys()


func _build_defs() -> void:
	var builders := {"items": ItemDef.from_dict, "materials": MaterialDef.from_dict}
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
