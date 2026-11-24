"""Tree model checks of the asset validator on hand-built binary glTF files."""
import json
import os
import struct
import tempfile
import unittest

from tools.assetgen import glb, validate

BUDGETS = [100, 50, 20]
MATERIALS = ["bark", "leaves", "billboard"]


def _write_glb(path, meshes):
    """meshes: [(name, [(material, triangles, has_colour)])]."""
    doc = {"asset": {"version": "2.0"}, "materials": [{"name": n} for n in MATERIALS], "meshes": [], "accessors": []}
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
            out.append({"attributes": attrs, "indices": len(acc) - 1, "material": MATERIALS.index(material)})
        doc["meshes"].append({"name": name, "primitives": out})
    text = json.dumps(doc).encode()
    text += b" " * (-len(text) % 4)
    body = struct.pack("<II", len(text), 0x4E4F534A) + text
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


def _good(stem, leaves=True):
    tiers = [(f"{stem}_t{k}", [("bark", b // 4, True)] + ([("leaves", b // 2, True)] if leaves else [])) for k, b in enumerate(BUDGETS)]
    return tiers + [(f"{stem}_t3", [("billboard", 2, True)])]


def _manifest(models_dir, cells):
    with open(os.path.join(models_dir, "tree_models.json"), "w") as f:
        json.dump({"grid": 2, "fill": 0.9, "models": {k: {"cell": c, "side_m": 1.0, "bottom_m": 0.0} for k, c in cells.items()}}, f)


class ValidateTreesTest(unittest.TestCase):
    def _content(self, d, variants=2):
        os.makedirs(os.path.join(d, "assetgen"))
        os.makedirs(os.path.join(d, "data"))
        os.makedirs(os.path.join(d, validate.MODEL_DIR))
        with open(os.path.join(d, "assetgen", "trees.json"), "w") as f:
            json.dump({
                "category": "tree", "budgets": {"mature": BUDGETS, "dead": BUDGETS},
                "species": {"a": {"clumps": {}}, "bare": {}},
                "models": [{"id": "a_mature", "seed": 1}, {"id": "snag", "seed": 1}],
            }, f)
        with open(os.path.join(d, "data", "trees.json"), "w") as f:
            json.dump({"trees": [
                {"id": "a_mature", "species": "a", "size": "mature", "variants": variants},
                {"id": "snag", "species": "bare", "size": "dead", "variants": 1},
            ]}, f)
        return os.path.join(d, validate.MODEL_DIR)

    def test_complete_models_pass(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d)
            for n in (1, 2):
                _write_glb(os.path.join(models, f"tree_a_mature_{n}.glb"), _good(f"tree_a_mature_{n}"))
            _write_glb(os.path.join(models, "tree_snag_1.glb"), _good("tree_snag_1", leaves=False))
            _manifest(models, {"tree_a_mature_1": 0, "tree_a_mature_2": 1, "tree_snag_1": 2})
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
            bad[-1] = ("tree_a_mature_1_t3", [("billboard", 4, True)])  # not a quad
            _write_glb(os.path.join(models, "tree_a_mature_1.glb"), bad)
            one = [("tree_a_mature_2_t0", [("bark", 5, True)])] + _good("tree_a_mature_2")[1:]  # one surface
            _write_glb(os.path.join(models, "tree_a_mature_2.glb"), one)
            _write_glb(os.path.join(models, "tree_snag_1.glb"), _good("tree_snag_1"))  # leaves on a leafless species
            _manifest(models, {"tree_a_mature_1": 0, "tree_a_mature_2": 0, "tree_snag_1": 9})  # shared, outside
            errors = validate.check_trees(d)
            for fragment in ("cell 0 also used by tree_a_mature_1", "cell 9 outside the 2 x 2", "_t3: 4 triangles", "120 triangles (budget 100)", "_t1 leaves: no RGBA", "no _t2 mesh", "tree_a_mature_3.glb: missing", "surfaces ['bark'], expected ['bark', 'leaves']", "snag_1_t0: surfaces ['bark', 'leaves'], expected ['bark']"):
                self.assertTrue(any(fragment in e for e in errors), (fragment, errors))
            self.assertEqual(len(errors), 11, errors)


if __name__ == "__main__":
    unittest.main()
