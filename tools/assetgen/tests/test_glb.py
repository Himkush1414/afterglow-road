"""glb budget reader on a hand-built binary glTF."""
import json
import os
import struct
import tempfile
import unittest

from tools.assetgen import glb


def _write_glb(path, tris):
    doc = {
        "asset": {"version": "2.0"},
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
        "accessors": [
            {"count": 3, "type": "VEC3", "componentType": 5126, "min": [-4, 0, -0.5], "max": [4, 6, 0.6]},
            {"count": tris * 3, "type": "SCALAR", "componentType": 5125},
        ],
    }
    text = json.dumps(doc).encode()
    text += b" " * (-len(text) % 4)
    body = struct.pack("<II", len(text), 0x4E4F534A) + text
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


class GlbTest(unittest.TestCase):
    def test_stats_and_budget(self):
        with tempfile.TemporaryDirectory() as d:
            _write_glb(os.path.join(d, "rock_face_1.glb"), 1200)
            _write_glb(os.path.join(d, "rock_face_2.glb"), 3000)
            s = glb.stats(os.path.join(d, "rock_face_1.glb"))
            self.assertEqual(s["triangles"], 1200)
            self.assertEqual(s["max"], [4, 6, 0.6])
            preset = {"category": "rock", "meshes": [{"name": "face", "variants": 3, "max_tris": 2500}]}
            errors = glb.check(preset, d)
            self.assertEqual(len(errors), 2, errors)  # _2 over budget, _3 missing
            self.assertTrue(any("3000 triangles" in e for e in errors))

    def test_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.glb")
            with open(p, "wb") as f:
                f.write(b"not a glb file at all")
            with self.assertRaises(ValueError):
                glb.stats(p)


if __name__ == "__main__":
    unittest.main()
