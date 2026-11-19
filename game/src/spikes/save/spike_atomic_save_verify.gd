extends SceneTree
## Spike P1-11 verifier: the save file must always load and be internally
## consistent. Prints "VALID <gen>" or "BROKEN <reason>".


func _initialize() -> void:
	var target := "user://spike_save/state.bin"
	if not FileAccess.file_exists(target):
		print("VALID 0 (no file yet)")
		quit(0)
		return
	var f := FileAccess.open_compressed(target, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		print("BROKEN cannot open")
		quit(1)
		return
	var d: Variant = f.get_var()
	if not d is Dictionary or not d.has("sum") or not d.has("payload"):
		print("BROKEN bad data")
		quit(1)
		return
	var ok: bool = _sum(d["payload"], int(d["gen"])) == int(d["sum"])
	print(("VALID %d" if ok else "BROKEN checksum %d") % int(d["gen"]))
	quit(0 if ok else 1)


static func _sum(bytes: PackedByteArray, gen: int) -> int:
	var s := gen
	for i in range(0, bytes.size(), 997):
		s = (s * 31 + bytes[i]) % 1_000_000_007
	return s
