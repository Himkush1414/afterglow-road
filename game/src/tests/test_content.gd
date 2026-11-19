extends TestCase
## ContentDB: the sample tree loads cleanly; every kind of bad data is
## reported with file, key and reason, and then no data is kept.

const DIR := "user://tests/content"
const SCHEMA := {
	"types":
	{
		"thing":
		{
			"type": "object",
			"fields":
			{
				"id": {"type": "id"},
				"next": {"type": "id", "ref": "things", "nullable": true},
				"alt": {"type": "id", "ref": ["spare", "things"], "optional": true}
			}
		}
	},
	"files":
	{
		"base.json":
		{"required": true, "spec": {"type": "object", "fields": {"n": {"type": "int"}}}},
		"things.json":
		{
			"spec":
			{"type": "object", "fields": {"things": {"type": "list", "of": {"type": "thing"}}}},
			"collections": {"things": "things"},
		},
	},
}


func before_each() -> void:
	_clear()
	DirAccess.make_dir_recursive_absolute(DIR + "/data")
	_write("schema.json", JSON.stringify(SCHEMA))
	_write("data/base.json", '{"n": 1}')


func after_each() -> void:
	_clear()
	ContentDB.schema_path = ContentDB.SCHEMA_PATH
	ContentDB.load_root(ContentDB.default_root())


func test_the_sample_content_loads_without_errors() -> void:
	check(ContentDB.load_root(ContentDB.SAMPLE_ROOT), "sample loads: %s" % [ContentDB.errors])
	check(ContentDB.tuning("clock").has("gmin_real_s"), "clock tuning present")
	check(ContentDB.tuning("clock").is_read_only(), "read-only")


func test_the_active_content_loads_without_errors() -> void:
	# The private tree when present, else the sample (the same check as boot).
	check(ContentDB.load_root(ContentDB.default_root()), "%s" % [ContentDB.errors])


func test_entries_are_indexed_by_id() -> void:
	_write(
		"data/things.json",
		'{"things": [{"id": "a", "next": "b", "alt": "a"}, {"id": "b", "next": null}]}'
	)
	check(_load(), "loads: %s" % [ContentDB.errors])
	check_eq(ContentDB.ids("things"), ["a", "b"])
	check_eq(ContentDB.entry("things", "a").next, "b")
	check_eq(ContentDB.entry("things", "zz"), {})


func test_bad_data_is_reported_and_nothing_is_kept() -> void:
	var cases := [
		[
			"data/things.json",
			'{"things": [{"id": "a", "next": "b"}]}',
			"things.json.things[0].next: 'b' is not an id in things"
		],
		[
			"data/things.json",
			'{"things": [{"id": "a", "next": null}, {"id": "a", "next": null}]}',
			"things.json.things[1]: duplicate id 'a'"
		],
		[
			"data/things.json",
			'{"things": [{"id": "A", "next": null}]}',
			"things.json.things[0].id: 'A' is not lower_snake_case"
		],
		["data/things.json", '{"things": [', "things.json:"],
		["data/extra.json", "{}", "extra.json: no schema for this file"],
		[
			"data/things.json",
			'{"things": [{"id": "a", "next": null, "alt": "zz"}]}',
			"things.json.things[0].alt: 'zz' is not an id in spare or things",
		],
	]
	for c: Array in cases:
		before_each()
		_write(c[0], c[1])
		check(not _load(), "refused: %s" % c[0])
		var e := ContentDB.errors
		check(e.size() == 1 and e[0].begins_with(c[2]), "%s: got %s" % [c[2], e])
		check_eq(ContentDB.ids("things"), [], "no data kept")
		DirAccess.remove_absolute(DIR + "/" + c[0])
	DirAccess.remove_absolute(DIR + "/data/base.json")
	check(not _load(), "required file missing")
	check_eq(
		ContentDB.errors,
		PackedStringArray(["base.json: required file is missing in %s/data" % DIR])
	)


func _load() -> bool:
	ContentDB.schema_path = DIR + "/schema.json"
	return ContentDB.load_root(DIR)


func _write(rel: String, text: String) -> void:
	var f := FileAccess.open(DIR + "/" + rel, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clear() -> void:
	for sub: String in ["/data", ""]:
		if DirAccess.dir_exists_absolute(DIR + sub):
			for f in DirAccess.get_files_at(DIR + sub):
				DirAccess.remove_absolute(DIR + sub + "/" + f)


func test_typed_defs_match_the_data() -> void:
	check(ContentDB.load_root(ContentDB.SAMPLE_ROOT), "%s" % [ContentDB.errors])
	for id: String in ContentDB.ids("items"):
		var d := ContentDB.entry("items", id)
		var it := ContentDB.item(StringName(id))
		check(it != null, "def for %s" % id)
		check_eq(it.stack, int(d.stack), id)
		check_eq(it.material, StringName(d.material), id)
		check_eq(it.tool != null, d.tool != null, "%s tool" % id)
		if it.tool != null:
			check_eq(it.tool.tool_class, StringName(d.tool["class"]), id)
		check(ContentDB.material(it.material) != null, "%s material resolves" % id)
	check(ContentDB.item(&"no_such_item") == null, "unknown id")
	for id: String in ContentDB.ids("pieces"):
		var p := ContentDB.piece(StringName(id))
		check_eq(p.size_m.x, float(ContentDB.entry("pieces", id).size_m[0]), id)
		for slot: Array in p.cost:
			for opt: Dictionary in slot:
				check(ContentDB.item(StringName(opt.item)) != null, "%s cost %s" % [id, opt.item])
