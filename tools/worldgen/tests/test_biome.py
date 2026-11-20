"""Biome rule tests."""
import unittest

import numpy as np

from tools.worldgen import biome
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


def at(sk, x, z, h, rules=None):
    """Biome ids at points (x, z) with given heights; a flat 3x3 patch per
    point, read at its centre."""
    if rules is not None:
        sk["biomes"] = rules
    out = []
    for xi, zi, hi in zip(x, z, h):
        g = Grid(float(xi) - 2.0, float(zi) - 2.0, 2.0, 3, 3)
        out.append(int(biome.classify(sk, g, np.full((3, 3), float(hi)), sk["world_seed"], False)[1, 1]))
    return out


class RuleTest(unittest.TestCase):
    def test_first_match_wins_then_fallback(self):
        rules = [
            {"id": 1, "name": "a", "rule": {"rects": [[0, 0, 100, 100]]}},
            {"id": 2, "name": "b", "rule": {"rects": [[50, 0, 200, 100]]}},
            {"id": 3, "name": "c", "rule": {}},
        ]
        self.assertEqual(at(sketch(), [75, 150, 500], [50, 50, 50], [1, 1, 1], rules), [1, 2, 3])

    def test_and_within_a_rule_or_within_any(self):
        rules = [
            {"id": 1, "name": "both", "rule": {"height_above": 10, "rects": [[0, 0, 100, 100]]}},
            {"id": 2, "name": "either", "rule": {"any": [{"height_above": 100}, {"rects": [[0, 0, 100, 100]]}]}},
        ]
        got = at(sketch(), [50, 50, 500, 500], [50, 50, 500, 500], [20, 5, 200, 5], rules)
        self.assertEqual(got, [1, 2, 2, -1])

    def test_heights(self):
        # far from coast, lake, river, pois and bumps: only the height rules decide
        x, z = [700] * 4, [900] * 4
        self.assertEqual(at(sketch(), x, z, [-1, 1, 300, 100]), [0, 2, 7, 2])

    def test_beach_needs_the_sea_or_the_lake_edge(self):
        sk = sketch()
        self.assertEqual(at(sk, [230, 700], [900, 900], [1.0, 1.0]), [1, 2], "near the west coast only")
        self.assertEqual(at(sk, [1205, 1000], [1000, 1000], [60, 60]), [1, 4], "on the lake edge; lake inside is wet")

    def test_slope(self):
        sk = sketch()
        g = Grid(700.0, 900.0, 2.0, 5, 3)
        x, _ = g.coords()
        ids = biome.classify(sk, g, 100.0 + 0.7 * (x - 700.0), 0, False)  # 35 degrees
        self.assertTrue(np.all(ids == 6))
        ids = biome.classify(sk, g, 100.0 + 0.5 * (x - 700.0), 0, False)  # 26.6 degrees
        self.assertTrue(np.all(ids == 2))

    def test_water_point_pois_rects_bumps(self):
        sk = sketch()
        pts = [
            (1400, 1030, 4),  # 30 m from the brook, flat: wet
            (1400, 1060, 2),  # 60 m: forest
            (1800, 1700, 4),  # near the point
            (520, 520, 9),  # near the village
            (200, 1600, 3),  # in the field rectangle
            (1500, 400, 6),  # big bump adds 300 m here (height kept below the high rule)
        ]
        got = at(sk, [p[0] for p in pts], [p[1] for p in pts], [100] * len(pts))
        self.assertEqual(got, [p[2] for p in pts])

    def test_sea_excludes_water_beds(self):
        sk = sketch()
        self.assertEqual(at(sk, [1400, 700], [1001, 900], [-1, -1]), [4, 0])

    def test_unknown_key_fails(self):
        with self.assertRaises(ValueError):
            at(sketch(), [0], [0], [0], [{"id": 1, "name": "x", "rule": {"near_moon": 1}}])

    def test_crop_equals_full_window_inside_the_border(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1100, 1100, 512, 4)
        r, c = crop.offset_in(full)
        hf = run(sk, full, sk["world_seed"], until="coast").layers["height"]
        hc = run(sk, crop, sk["world_seed"], until="coast").layers["height"]
        bf = biome.classify(sk, full, hf, sk["world_seed"])[r : r + crop.nz, c : c + crop.nx]
        bc = biome.classify(sk, crop, hc, sk["world_seed"])
        # the slope at the outer ring is one-sided, so callers pad by one sample
        np.testing.assert_array_equal(bc[1:-1, 1:-1], bf[1:-1, 1:-1])
        self.assertGreaterEqual(len(np.unique(bc)), 3)
        self.assertNotIn(-1, np.unique(bf))

    def test_names(self):
        self.assertEqual(biome.names(sketch())[7], "high")


if __name__ == "__main__":
    unittest.main()
