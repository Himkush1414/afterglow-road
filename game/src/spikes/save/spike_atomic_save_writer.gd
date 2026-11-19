extends SceneTree
## Spike P1-11 writer (decision D-11): rewrites a save file for ever, each
## time with a new generation number, through "write temp, then rename".
## spike_atomic_save.sh kills this process at random moments. With
## `-- --direct` it writes the target in place (control: must break).

const DIR := "user://spike_save"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var target := DIR.path_join("state.bin")
	var direct := "--direct" in OS.get_cmdline_user_args()
	var tmp := target if direct else target + ".tmp"
	var gen := 0
	if FileAccess.file_exists(target):
		var f := FileAccess.open_compressed(target, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if f:
			var d: Variant = f.get_var()
			if d is Dictionary:
				gen = int(d.get("gen", 0))
	var payload := PackedByteArray()
	payload.resize(400_000)
	while true:
		gen += 1
		for i in range(0, payload.size(), 997):
			payload[i] = gen % 251
		var data := {"gen": gen, "payload": payload, "sum": _sum(payload, gen)}
		var f := FileAccess.open_compressed(tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		f.store_var(data)
		f.flush()
		f.close()
		if not direct:
			DirAccess.rename_absolute(tmp, target)


static func _sum(bytes: PackedByteArray, gen: int) -> int:
	var s := gen
	for i in range(0, bytes.size(), 997):
		s = (s * 31 + bytes[i]) % 1_000_000_007
	return s
