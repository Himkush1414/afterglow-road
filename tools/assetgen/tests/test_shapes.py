"""Shape presets: size overrides and the shape a model uses."""
import unittest

from tools.assetgen.shapes import merged, shape_for

PRESET = {"species": {
    "a": {"trunk": {"top": 1.0, "taper": 0.2}, "levels": [{"count": 20, "seg_m": 0.5}, {"count": [3, 6]}],
          "tiers": [{"radial": 12}, {"radial": 7}, {"radial": 5}],
          "sizes": {"young": {"trunk": {"taper": 0.4}, "levels": [{"count": 8}, {"count": [1, 2]}], "tiers": [{"radial": 6}]}}},
    "a_lying": {"trunk": {"lie_length_m": 7.0}},
}}


class ShapesTest(unittest.TestCase):
    def test_size_overrides_merge(self):
        young = shape_for(PRESET, {"id": "a_young"}, {"species": "a", "size": "young"})
        self.assertEqual(young["trunk"], {"top": 1.0, "taper": 0.4})
        self.assertEqual(young["levels"], [{"count": 8, "seg_m": 0.5}, {"count": [1, 2]}])  # item by item; number lists replace
        self.assertEqual(young["tiers"], [{"radial": 6}])  # unequal length: replaced
        self.assertNotIn("sizes", young)
        mature = shape_for(PRESET, {"id": "a_mature"}, {"species": "a", "size": "mature"})
        self.assertEqual(mature["trunk"]["taper"], 0.2)
        self.assertEqual(len(mature["tiers"]), 3)

    def test_model_shape_overrides_species(self):
        s = shape_for(PRESET, {"id": "log", "shape": "a_lying"}, {"species": "a", "size": "dead"})
        self.assertEqual(s, {"trunk": {"lie_length_m": 7.0}})

    def test_merge_does_not_change_its_inputs(self):
        base = {"x": {"y": 1}}
        merged(base, {"x": {"y": 2}})
        self.assertEqual(base, {"x": {"y": 1}})


if __name__ == "__main__":
    unittest.main()
