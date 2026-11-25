"""Tree model checks of the asset validator on hand-built binary glTF files."""
import json
import os
import struct
import tempfile
import unittest

import numpy as np
from PIL import Image

from tools.assetgen import glb, validate

BUDGETS = [100, 50, 20]
MATERIALS = ["bark", "leaves", "billboard", "cut"]


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
    def entry(k, c):
        return {"cell": c, "side_m": 1.0, "bottom_m": 0.0, "bark_set": "a", "leaf_set": None if "snag" in k else "a"}

    with open(os.path.join(models_dir, "tree_models.json"), "w") as f:
        json.dump({"grid": 2, "fill": 0.9, "models": {k: entry(k, c) for k, c in cells.items()}}, f)
    hi = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(models_dir))), validate.TEXTURE_DIR, "hi")
    os.makedirs(hi, exist_ok=True)
    for name in ("tree_a_bark_ah.png", "tree_a_bark_nra.png", "tree_a_leaves_ca.png", "tree_a_leaves_nra.png"):
        open(os.path.join(hi, name), "wb").close()


def _atlas(content, filled, normal_differs=False, size=16, grid=2):
    """Billboard atlas files with a covered pixel in each cell of `filled`."""
    img = np.zeros((size, size, 4), np.uint8)
    n = size // grid
    for c in filled:
        img[(c // grid) * n + 2, (c % grid) * n + 2] = (40, 80, 30, 255)
    normal = img.copy()
    if normal_differs:
        normal[0, 0, 3] = 255
    for d, k in (("hi", 1), ("lo", 2)):
        os.makedirs(os.path.join(content, validate.TEXTURE_DIR, d), exist_ok=True)
        for kind, a in (("ca", img), ("n", normal)):
            Image.fromarray(a[::k, ::k].copy(), "RGBA").save(os.path.join(content, validate.TEXTURE_DIR, d, f"tree_billboards_{kind}.png"))


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
            _atlas(d, [0, 1, 2])
            self.assertEqual(validate.check_trees(d), [])
            _atlas(d, [0, 2])
            self.assertEqual(validate.check_trees(d), ["tree_a_mature_2: billboard cell 1 is empty"])
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
            _atlas(d, [0], normal_differs=True)
            errors = validate.check_trees(d)
            for fragment in ("differ in coverage", "cell 0 also used by tree_a_mature_1", "cell 9 outside the 2 x 2", "_t3: 4 triangles", "120 triangles (budget 100)", "_t1 leaves: no RGBA", "no _t2 mesh", "tree_a_mature_3.glb: missing", "surfaces ['bark'], expected ['bark', 'leaves']", "snag_1_t0: surfaces ['bark', 'leaves'], expected ['bark']"):
                self.assertTrue(any(fragment in e for e in errors), (fragment, errors))
            self.assertEqual(len(errors), 12, errors)

    def test_texture_sets_are_checked(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d, variants=1)
            _write_glb(os.path.join(models, "tree_a_mature_1.glb"), _good("tree_a_mature_1"))
            _write_glb(os.path.join(models, "tree_snag_1.glb"), _good("tree_snag_1", leaves=False))
            _manifest(models, {"tree_a_mature_1": 0, "tree_snag_1": 1})
            _atlas(d, [0, 1])
            os.remove(os.path.join(d, validate.TEXTURE_DIR, "hi", "tree_a_leaves_nra.png"))
            self.assertEqual(validate.check_trees(d), ["tree_a_mature_1: texture tree_a_leaves_nra.png missing"])

    def test_missing_atlas_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d, variants=1)
            _write_glb(os.path.join(models, "tree_a_mature_1.glb"), _good("tree_a_mature_1"))
            _write_glb(os.path.join(models, "tree_snag_1.glb"), _good("tree_snag_1", leaves=False))
            _manifest(models, {"tree_a_mature_1": 0, "tree_snag_1": 1})
            errors = validate.check_trees(d)
            self.assertEqual(len(errors), 4, errors)
            self.assertTrue(all("missing" in e for e in errors), errors)



class StumpTest(unittest.TestCase):
    def _content(self, d):
        os.makedirs(os.path.join(d, "assetgen"))
        os.makedirs(os.path.join(d, validate.STUMP_DIR))
        with open(os.path.join(d, "assetgen", "stumps.json"), "w") as f:
            json.dump({"category": "stump", "meshes": [
                {"name": "stump", "variants": 2, "max_tris": 300},
                {"name": "cap", "variants": 1, "max_tris": 300},
            ]}, f)
        return os.path.join(d, validate.STUMP_DIR)

    def test_no_preset_no_check(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(validate.check_stumps(d), [])

    def test_complete_stumps_pass_and_faults_are_reported(self):
        with tempfile.TemporaryDirectory() as d:
            models = self._content(d)
            for name in ("stump_stump_1", "stump_stump_2", "stump_cap_1"):
                _write_glb(os.path.join(models, name + ".glb"), [(name, [("bark", 60, False), ("cut", 16, False)])])
            self.assertEqual(validate.check_stumps(d), [])
            _write_glb(os.path.join(models, "stump_stump_1.glb"), [("stump_stump_1", [("bark", 290, False), ("cut", 16, False)])])
            _write_glb(os.path.join(models, "stump_cap_1.glb"), [("stump_cap_1", [("bark", 40, False)])])
            os.remove(os.path.join(models, "stump_stump_2.glb"))
            errors = validate.check_stumps(d)
            for fragment in ("306 triangles (budget 300)", "stump_stump_2.glb: missing", "stump_cap_1 stump_cap_1: surfaces ['bark'], expected ['bark', 'cut']"):
                self.assertTrue(any(fragment in e for e in errors), (fragment, errors))
            self.assertEqual(len(errors), 3, errors)

if __name__ == "__main__":
    unittest.main()
