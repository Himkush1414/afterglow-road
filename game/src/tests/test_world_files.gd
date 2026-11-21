extends TestCase
## World files: the generator's ZSTD frames decode in the engine.

## Written by the generator's ZSTD writer from six little-endian u16 values
## (pinned by tools/worldgen/tests/test_files.py).
const FRAME_BASE64 := "KLUv/SAMYQAAAAABAAAB//8BEDkw"
const VALUES: Array[int] = [0, 1, 256, 65535, 4097, 12345]


func test_generator_frame_decodes() -> void:
	var frame := Marshalls.base64_to_raw(FRAME_BASE64)
	var raw := frame.decompress(VALUES.size() * 2, FileAccess.COMPRESSION_ZSTD)
	if not check_eq(raw.size(), VALUES.size() * 2, "decoded size"):
		return
	for i in VALUES.size():
		check_eq(raw.decode_u16(i * 2), VALUES[i], "value %d" % i)


func test_tree_chunk_files_decode() -> void:
	# the sample world's trees/ written by the generator (7-byte records)
	var world := WorldData.new()
	if not check(world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), ", ".join(world.errors)):
		world.free()
		return
	var index: Variant = JSON.parse_string(world.read_text("trees/index.json"))
	check(index is Dictionary, "index hash-checked and parsed: %s" % ", ".join(world.errors))
	if index is Dictionary:
		var total := 0
		var first := PackedByteArray()
		for name: String in index.files:
			var e: Dictionary = index.files[name]
			var data := FileAccess.get_file_as_bytes(world.folder() + "/trees/" + name)
			var ctx := HashingContext.new()
			ctx.start(HashingContext.HASH_SHA256)
			ctx.update(data)
			check_eq(ctx.finish().hex_encode(), e.sha256, name)
			var raw := data.decompress(
				int(e.count) * int(index.record_bytes), FileAccess.COMPRESSION_ZSTD
			)
			check_eq(raw.size(), int(e.count) * 7, name)
			total += int(e.count)
			if name == "0_0.bin":
				first = raw
		check_eq(total, 3, "three sample trees")
		check_eq(first.decode_u16(1), 20 * 512, "x of the first tree in 1/512 m")
		check_eq(first.decode_u16(3), 30 * 512, "z of the first tree")
	world.free()
