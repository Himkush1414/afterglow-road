"""Terrain stage tests on the sample sketch."""
import json
import os
import tempfile
import unittest

import numpy as np

from tools.worldgen import sketch as sketch_io
from tools.worldgen import stages
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


def height(sk, grid, until):
    return run(sk, grid, sk["world_seed"], until=until).layers["height"]


class RampBumpTest(unittest.TestCase):
    def test_stage_order(self):
        self.assertEqual([n for n, _ in STAGES][:2], ["ramp", "bumps"])

    def test_ramp_values(self):
        r = sketch()["ramp"]
        v = stages.ramp(np.array([0.0, 1000.0]), np.array([2048.0, 48.0]), r)
        np.testing.assert_allclose(v, [10.0, 10.0 + 10.0 + 40.0])

    def test_bump_peak_edge_and_compact_support(self):
        b = sketch()["bumps"][0]
        self.assertAlmostEqual(float(stages.bump(b["x"], b["z"], b)), b["h"])
        half = float(stages.bump(b["x"] + b["r"] / 2, b["z"], b))
        self.assertAlmostEqual(half, b["h"] * 0.5625)
        # zero beyond the radius (at it, only float rounding remains)
        ang = np.linspace(0, 2 * np.pi, 64)
        on = stages.bump(b["x"] + b["r"] * np.cos(ang), b["z"] + b["r"] * np.sin(ang), b)
        self.assertLess(float(on.max()), 1e-20)
        for k in (1.001, 1.5, 3.0):
            v = stages.bump(b["x"] + k * b["r"] * np.cos(ang), b["z"] + k * b["r"] * np.sin(ang), b)
            self.assertTrue(np.all(v == 0.0), f"bump not zero at {k} R")
        # smooth at the edge: (1 - q)^2 has zero value and zero slope at q = 1
        inside = float(stages.bump(b["x"] + 0.999 * b["r"], b["z"], b))
        self.assertAlmostEqual(inside, b["h"] * (1 - 0.999**2) ** 2, places=12)

    def test_bump_tuned_alone_leaves_other_places(self):
        sk = sketch()
        g = Grid.crop(600, 1400, 512, 2)  # around the small bump, far from the big one
        before = height(sk, g, "bumps")
        sk["bumps"][0]["h"] = 999.0
        np.testing.assert_array_equal(before, height(sk, g, "bumps"))

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], sk["sample_m"])
        crop = Grid.crop(1300, 600, 512, sk["sample_m"])
        r, c = crop.offset_in(full)
        hf = height(sk, full, "bumps")
        hc = height(sk, crop, "bumps")
        np.testing.assert_array_equal(hc, hf[r : r + crop.nz, c : c + crop.nx])


class SketchIoTest(unittest.TestCase):
    def test_load_with_pois_and_version_check(self):
        with tempfile.TemporaryDirectory() as d:
            p, q = os.path.join(d, "s.json"), os.path.join(d, "p.csv")
            with open(p, "w", encoding="utf-8") as f:
                json.dump(sketch(), f)
            with open(q, "w", encoding="utf-8") as f:
                f.write("id,name,x,z,y\na,A,10,20,3.5\n")
            sk = sketch_io.load(p, q)
            self.assertEqual(sk["pois"], [{"id": "a", "name": "A", "x": 10.0, "z": 20.0, "y": 3.5}])
            bad = sketch()
            bad["version"] = 2
            with open(p, "w", encoding="utf-8") as f:
                json.dump(bad, f)
            with self.assertRaises(ValueError):
                sketch_io.load(p)


if __name__ == "__main__":
    unittest.main()
