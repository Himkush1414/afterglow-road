class_name Schema
extends RefCounted
## Checks parsed JSON against a type spec (a Dictionary). Spec keys:
## "type": int | number | string | bool | id | list | object | map | <name in types>;
## "min", "max" (numbers); "enum" (strings); "nullable"; "optional" (object
## fields; all others are required); "of" + "min_len" (list); "fields"
## (object; unknown keys are errors); "values" (map, string keys);
## "ref": <collection> (an id that must exist there; collected in `refs`).
## JSON numbers arrive as floats, so "int" accepts any integral number.

const ID_PATTERN := "^[a-z][a-z0-9_]*$"
const SPEC_KEYS: Array[String] = [
	"type", "min", "max", "enum", "nullable", "optional", "of", "min_len", "fields", "values", "ref"
]

## "path: reason" for every problem found.
var errors: PackedStringArray = []
## [collection, id, path] for every "ref" value seen.
var refs: Array[Array] = []
var _types: Dictionary
var _id_re := RegEx.create_from_string(ID_PATTERN)


func _init(types: Dictionary = {}) -> void:
	_types = types


## Checks `value` at `path`; appends to `errors` and `refs`.
func check(value: Variant, spec: Dictionary, path: String) -> void:
	for key: String in spec:
		if not key in SPEC_KEYS:
			errors.append("%s: schema has unknown key '%s'" % [path, key])
			return
	if typeof(value) == TYPE_NIL:
		if not spec.get("nullable", false):
			errors.append("%s: must not be null" % path)
		return
	var type: String = spec.get("type", "")
	match type:
		"int", "number":
			_check_number(value, spec, path, type == "int")
		"string", "id":
			_check_string(value, spec, path, type == "id")
		"bool":
			if not value is bool:
				errors.append("%s: expected bool" % path)
		"list":
			_check_list(value, spec, path)
		"object":
			_check_object(value, spec.get("fields", {}), path)
		"map":
			_check_map(value, spec, path)
		_:
			if not _types.has(type):
				errors.append("%s: schema has unknown type '%s'" % [path, type])
				return
			check(value, _types[type], path)
	if spec.has("ref") and (value is String):
		refs.append([spec.ref, value, path])


func _check_number(value: Variant, spec: Dictionary, path: String, integral: bool) -> void:
	if not (value is float or value is int):
		errors.append("%s: expected %s" % [path, "int" if integral else "number"])
		return
	var v := float(value)
	if integral and v != floorf(v):
		errors.append("%s: expected int, got %s" % [path, v])
	if spec.has("min") and v < float(spec.min):
		errors.append("%s: %s is below %s" % [path, v, spec.min])
	if spec.has("max") and v > float(spec.max):
		errors.append("%s: %s is above %s" % [path, v, spec.max])


func _check_string(value: Variant, spec: Dictionary, path: String, is_id: bool) -> void:
	if not value is String:
		errors.append("%s: expected %s" % [path, "id" if is_id else "string"])
		return
	if is_id and _id_re.search(value) == null:
		errors.append("%s: '%s' is not lower_snake_case" % [path, value])
	if spec.has("enum") and not value in spec.enum:
		errors.append("%s: '%s' is not one of %s" % [path, value, spec.enum])


func _check_list(value: Variant, spec: Dictionary, path: String) -> void:
	if not value is Array:
		errors.append("%s: expected list" % path)
		return
	var list: Array = value
	if list.size() < int(spec.get("min_len", 0)):
		errors.append("%s: needs at least %d entries" % [path, spec.min_len])
	for i in list.size():
		check(list[i], spec.get("of", {}), "%s[%d]" % [path, i])


func _check_object(value: Variant, fields: Dictionary, path: String) -> void:
	if not value is Dictionary:
		errors.append("%s: expected object" % path)
		return
	var obj: Dictionary = value
	for key: Variant in obj:
		if not fields.has(key):
			errors.append("%s: unknown key '%s'" % [path, key])
	for key: String in fields:
		var field: Dictionary = fields[key]
		if obj.has(key):
			check(obj[key], field, "%s.%s" % [path, key])
		elif not field.get("optional", false):
			errors.append("%s: missing key '%s'" % [path, key])


func _check_map(value: Variant, spec: Dictionary, path: String) -> void:
	if not value is Dictionary:
		errors.append("%s: expected map" % path)
		return
	var obj: Dictionary = value
	for key: Variant in obj:
		if not key is String:
			errors.append("%s: map key %s is not a string" % [path, key])
			continue
		check(obj[key], spec.get("values", {}), "%s.%s" % [path, key])
