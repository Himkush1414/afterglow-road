"""Tree model checks of the asset validator on hand-built binary glTF files."""
import json
import os
import struct
import tempfile
import unittest

from tools.assetgen import glb, validate

BUDGETS = [100, 50, 20]


def _write_glb(path, meshes):
    """meshes: [(name, [(material, triangles, has_colour)])]."""
    doc = {"asset": {"version": "2.0"}, "materials": [{"name": "bark"}, {"name": "leaves"}], "meshes": [], "accessors": []}
    for name, prims in meshes:
        out = []
        for material, tris, colour in prims:
            acc = doc["accessors"]
            attrs = {"POSITION": len(acc)}
            acc.append({"count": 3, "type": "VEC3", "componentType": 5126, "min": [0, 0, 0], "max": [1, 1, 1]})
            if colour:
                attrs["COLOR_0"] = len(acc)
                acc.append({"count": 3, "type": "VEC4", "componentType": 5126})
            acc.append({"count": tris * 3, "type": "SCALAR", "componentType": 5125})
            out.append({"attributes": attrs, "indices": len(acc) - 1, "material": ["bark", "leaves"].index(material)})
        doc["meshes"].append({"name": name, "primitives": out})
    text = json.dumps(doc).encode()
    text += b" " * (-len(text) % 4)
    body = struct.pack("<II", len(text), 0x4E4F534A) + text
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


def _good(stem):
    return [(f"{stem}_t{k}", [("bark", b // 4, True), ("leaves", b // 2, True)]) for k, b in enumerate(BUDGETS)]


class ValidateTreesTest(unittest.TestCase):
    def _content(self, d, variants=2):
        os.makedirs(os.path.join(d, "assetgen"))
        os.makedirs(os.path.join(d, "data"))
        os.makedirs(os.path.join(d, validate.MODEL_DIR))
        with open(os.path.join(d, "assetgen", "trees.json"), "w") as f:
            json.dump({"category": "tree", "budgets": {"mature": BUDGETS}, "models": [{"id": "a_mature", "seed": 1}]}, f)
        with open(os.path.join(d, "data", "trees.json"), "w") as f:
            json.dump({"trees": [{"id": "a_mature", "size": "mature", "variants": variants}]}, f)
        return os.path.join(d, validate.MODEL_DIR)

    def test_complete_models_pass(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d)
            for n in (1, 2):
                _write_glb(os.path.join(models, f"tree_a_mature_{n}.glb"), _good(f"tree_a_mature_{n}"))
            self.assertEqual(validate.check_trees(d), [])
            m = glb.meshes(os.path.join(models, "tree_a_mature_1.glb"))
            self.assertEqual(m["tree_a_mature_1_t0"]["triangles"], 75)

    def test_each_fault_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d, variants=3)
            bad = _good("tree_a_mature_1")
            bad[0] = ("tree_a_mature_1_t0", [("bark", 60, True), ("leaves", 60, True)])  # over budget
            bad[1] = ("tree_a_mature_1_t1", [("bark", 5, True), ("leaves", 5, False)])  # no colours
            del bad[2]  # no _t2
            _write_glb(os.path.join(models, "tree_a_mature_1.glb"), bad)
            one = [("tree_a_mature_2_t0", [("bark", 5, True)])] + _good("tree_a_mature_2")[1:]  # one surface
            _write_glb(os.path.join(models, "tree_a_mature_2.glb"), one)
            errors = validate.check_trees(d)
            for fragment in ("120 triangles (budget 100)", "_t1 leaves: no RGBA", "no _t2 mesh", "tree_a_mature_3.glb: missing", "surfaces ['bark']"):
                self.assertTrue(any(fragment in e for e in errors), (fragment, errors))
            self.assertEqual(len(errors), 5, errors)


if __name__ == "__main__":
    unittest.main()
