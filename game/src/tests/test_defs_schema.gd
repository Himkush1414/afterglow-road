extends TestCase
## Schema: each spec rule accepts what it should and reports the rest with
## its path.

const TYPES := {
	"part":
	{
		"type": "object",
		"fields":
		{
			"id": {"type": "id"},
			"count": {"type": "int", "min": 1, "max": 9},
			"weight": {"type": "number", "min": 0},
			"kind": {"type": "string", "enum": ["a", "b"]},
			"spare": {"type": "bool", "optional": true},
			"link": {"type": "id", "ref": "parts", "nullable": true},
			"tags": {"type": "list", "of": {"type": "string"}, "min_len": 1},
			"levels": {"type": "map", "values": {"type": "number"}},
		},
	},
}

var _good := {
	"id": "small_part",
	"count": 3.0,
	"weight": 0.5,
	"kind": "a",
	"link": "other_part",
	"tags": ["x"],
	"levels": {"low": 1.0, "high": 2.0},
}


func _run(value: Variant) -> Schema:
	var s := Schema.new(TYPES)
	s.check(value, {"type": "list", "of": {"type": "part"}}, "parts")
	return s


func test_a_valid_value_has_no_errors_and_collects_refs() -> void:
	var s := _run([_good])
	check_eq(s.errors, PackedStringArray())
	check_eq(s.refs, [["parts", "other_part", "parts[0].link"]] as Array[Array])


func test_each_rule_reports_its_path() -> void:
	var cases := [
		["id", "Big Part", "parts[0].id: 'Big Part' is not lower_snake_case"],
		["count", 2.5, "parts[0].count: expected int, got 2.5"],
		["count", 0, "parts[0].count: 0.0 is below 1"],
		["count", 10, "parts[0].count: 10.0 is above 9"],
		["weight", "1", "parts[0].weight: expected number"],
		["kind", "c", 'parts[0].kind: \'c\' is not one of ["a", "b"]'],
		["spare", 1, "parts[0].spare: expected bool"],
		["tags", [], "parts[0].tags: needs at least 1 entries"],
		["tags", [1], "parts[0].tags[0]: expected string"],
		["levels", {"low": "x"}, "parts[0].levels.low: expected number"],
		["levels", [], "parts[0].levels: expected map"],
		["kind", null, "parts[0].kind: must not be null"],
	]
	for c: Array in cases:
		var v := _good.duplicate(true)
		v[c[0]] = c[1]
		check_eq(_run([v]).errors, PackedStringArray([c[2]]), "%s = %s" % [c[0], c[1]])


func test_missing_unknown_optional_and_nullable_keys() -> void:
	var v := _good.duplicate(true)
	v.erase("weight")
	v["colour"] = "red"
	v["link"] = null
	var s := _run([v])
	check_eq(
		s.errors,
		PackedStringArray(["parts[0]: unknown key 'colour'", "parts[0]: missing key 'weight'"])
	)
	check_eq(s.refs, [] as Array[Array], "null ref not collected")


func test_bad_schemas_are_reported() -> void:
	var s := Schema.new()
	s.check(1, {"type": "nope"}, "x")
	s.check(1, {"type": "int", "mni": 0}, "y")
	check_eq(
		s.errors,
		PackedStringArray(["x: schema has unknown type 'nope'", "y: schema has unknown key 'mni'"])
	)


func test_literals_and_tagged_refs() -> void:
	var s := Schema.new()
	var spec := {
		"type": "list",
		"of":
		{
			"type": "string",
			"tagged_ref": {"item": ["a", "b"], "station": "c"},
			"literals": ["start"]
		},
	}
	s.check(["start", "item:x", "station:y", "item", "tool:z"], spec, "u")
	check_eq(s.refs, [[["a", "b"], "x", "u[1]"], ["c", "y", "u[2]"]] as Array[Array])
	check_eq(
		s.errors,
		PackedStringArray(
			["u[3]: 'item' is not <item|station>:<id>", "u[4]: 'tool:z' is not <item|station>:<id>"]
		)
	)
	var r := Schema.new()
	r.check(
		["hand", "box"],
		{"type": "list", "of": {"type": "id", "ref": "p", "literals": ["hand"]}},
		"v"
	)
	check_eq(r.refs, [["p", "box", "v[1]"]] as Array[Array], "literal not collected")
