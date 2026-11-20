"""World file writer tests: ZSTD frames, height encoding, meta."""
import json
import os
import tempfile
import unittest

import numpy as np
import zstandard

from tools.worldgen import files
from tools.worldgen.tests.sample import sketch

# The frame the engine test (game/src/tests/test_world_files.gd) decodes.
ENGINE_FRAME = "KLUv/SAMYQAAAAABAAAB//8BEDkw"
ENGINE_VALUES = [0, 1, 256, 65535, 4097, 12345]


class FilesTest(unittest.TestCase):
    def test_frame_round_trip_with_content_size(self):
        data = os.urandom(1000) + bytes(5000)
        frame = files.compress(data)
        self.assertEqual(files.decompress(frame), data)
        self.assertEqual(zstandard.frame_content_size(frame), len(data))
        self.assertEqual(frame, files.compress(data), "deterministic")

    def test_engine_frame_is_what_the_writer_makes(self):
        import base64

        raw = np.array(ENGINE_VALUES, dtype="<u2").tobytes()
        self.assertEqual(base64.b64encode(files.compress(raw)).decode(), ENGINE_FRAME)

    def test_height_encoding(self):
        sk = sketch()
        y = np.array([-64.0, -63.98, 0.0, 0.009, 0.011, 118.0, 1246.7, 2000.0, -100.0])
        u = files.encode_height(y, sk)
        self.assertEqual(u.dtype, np.dtype("<u2"))
        self.assertEqual(u.tolist(), [0, 1, 3200, 3200, 3201, 9100, 65535, 65535, 0])
        inside = (y >= -64) & (y <= 1246.7)
        self.assertLessEqual(np.abs(files.decode_height(u, sk)[inside] - y[inside]).max(), 0.01 + 1e-9)

    def test_meta(self):
        sk = sketch()
        doc = files.meta(sk, {"b.bin": "2" * 64, "a.bin": "1" * 64})
        self.assertEqual(list(doc["sha256"]), ["a.bin", "b.bin"])
        self.assertEqual((doc["version"], doc["height_scale"], doc["height_offset_m"], doc["world_seed"]), (1, 0.02, 64.0, 11))
        self.assertEqual(json.loads(files.meta_text(doc)), doc)
        with tempfile.TemporaryDirectory() as d:
            import hashlib

            h = files.write(os.path.join(d, "x.bin"), b"abc")
            self.assertEqual(h, hashlib.sha256(b"abc").hexdigest())


if __name__ == "__main__":
    unittest.main()
