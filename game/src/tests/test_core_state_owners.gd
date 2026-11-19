extends TestCase
## 03 §4: state has one writer. A class lists the members it owns in
## `const STATE`; no other script under src/ (tests and spikes aside) may
## assign to them.

const SKIP := ["res://src/tests/", "res://src/spikes/"]
const STATE_DECL := "const STATE[^=]*=\\s*\\[([^\\]]*)\\]"


func test_no_script_writes_state_it_does_not_own() -> void:
	var files := {}
	_collect("res://src", files)
	check(files.size() > 5, "scanned %d scripts" % files.size())
	var owners := owned_state(files)
	check(owners.size() >= 1, "at least one owner declares STATE")
	check_eq(violations(owners, files), [] as Array[String])


func test_the_scan_finds_outside_writes() -> void:
	var files := {
		"a.gd": 'const STATE: Array[StringName] = [&"level", &"mode"]\nfunc f():\n\tlevel = 3\n',
		"b.gd": "func g(a):\n\ta.level = 2\n\ta.mode += 1\n\tif a.level == 2: pass\n",
		"c.gd": "func h(a):\n\tif a.level <= 2 or a.level != 1: pass\n\t# a.level = 9\n",
	}
	var owners := owned_state(files)
	check_eq(owners, {"a.gd": [&"level", &"mode"]})
	check_eq(violations(owners, files), ["b.gd:2 level", "b.gd:3 mode"] as Array[String])


## path -> owned member names, for every script that declares STATE.
func owned_state(files: Dictionary) -> Dictionary:
	var decl := RegEx.create_from_string(STATE_DECL)
	var names := RegEx.create_from_string('&"(\\w+)"')
	var out := {}
	for path: String in files:
		var m := decl.search(files[path])
		if m == null:
			continue
		var list: Array[StringName] = []
		for n in names.search_all(m.get_string(1)):
			list.append(StringName(n.get_string(1)))
		out[path] = list
	return out


## "path:line member" for each assignment to an owned member outside its owner.
func violations(owners: Dictionary, files: Dictionary) -> Array[String]:
	var members: Array[String] = []
	for path: String in owners:
		for n: StringName in owners[path]:
			members.append(String(n))
	var out: Array[String] = []
	if members.is_empty():
		return out
	var write := RegEx.create_from_string("\\.(%s)\\s*[-+*/%%]?=(?!=)" % "|".join(members))
	for path: String in files:
		var lines: PackedStringArray = (files[path] as String).split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("#"):
				continue
			for m in write.search_all(line):
				if not _owns(owners, path, m.get_string(1)):
					out.append("%s:%d %s" % [path, i + 1, m.get_string(1)])
	return out


func _owns(owners: Dictionary, path: String, member: String) -> bool:
	return owners.has(path) and StringName(member) in owners[path]


func _collect(dir: String, files: Dictionary) -> void:
	for skip: String in SKIP:
		if (dir + "/").begins_with(skip):
			return
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			files[dir + "/" + f] = FileAccess.get_file_as_string(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_collect(dir + "/" + d, files)
