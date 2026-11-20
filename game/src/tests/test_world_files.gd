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
