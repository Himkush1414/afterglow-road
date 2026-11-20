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


def height(sk, grid, until, noise=True):
    return run(sk, grid, sk["world_seed"], until=until, noise=noise).layers["height"]


class RampBumpTest(unittest.TestCase):
    def test_stage_order(self):
        self.assertEqual([n for n, _ in STAGES][:3], ["ramp", "bumps", "coast"])

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


class CoastTest(unittest.TestCase):
    def test_profile_without_noise(self):
        sk = sketch()
        c = sk["coast"]
        z = np.full(6, 1000.0)
        x = np.array([200.0, 350.0, 500.0, 900.0, 150.0, 0.0])  # coast, inland x3, sea x2
        before = stages.ramp(x, z, sk["ramp"]) + stages.bumps(x, z, sk["bumps"])
        d = stages.coast_distance(x, z, c, sk["world_seed"], False)
        np.testing.assert_allclose(d, [0.0, 150.0, 300.0, 700.0, -50.0, -200.0])
        h = stages.coast(before, d, c)
        self.assertEqual(h[0], -6.0, "shore height on the coast line")
        self.assertAlmostEqual(h[1], 0.5 * before[1] - 3.0, "half way through the blend")
        np.testing.assert_array_equal(h[2:4], before[2:4], "unchanged beyond the blend")
        np.testing.assert_allclose(h[4:], [-7.0, -10.0], err_msg="sea floor slopes down")
        far = stages.coast(np.zeros(1), np.array([-5000.0]), c)
        self.assertEqual(far[0], -40.0, "never below the minimum")

    def test_nearer_coast_wins(self):
        c = sketch()["coast"]
        d = stages.coast_distance(np.array([1000.0, 250.0]), np.array([1800.0, 1800.0]), c, 0, False)
        np.testing.assert_allclose(d, [50.0, 50.0])

    def test_noise_moves_the_coast_within_its_amplitude(self):
        sk = sketch()
        c = sk["coast"]
        t = np.arange(0.0, 2048.0, 4.0)
        on = stages.coast_distance(np.full_like(t, 1000.0), t, c, sk["world_seed"], True)
        off = stages.coast_distance(np.full_like(t, 1000.0), t, c, sk["world_seed"], False)
        shift = off - on  # west coast line moved east by this much (south line is far)
        self.assertLessEqual(np.abs(shift[t < 1500]).max(), c["west"]["amp"])
        self.assertGreater(shift[t < 1500].std(), 5.0, "the coast line is not straight")

    def test_continuous_across_the_coast(self):
        sk = sketch()
        g = Grid.crop(200, 1000, 512, 1)
        h = height(sk, g, "coast")
        self.assertLess(np.abs(np.diff(h, axis=1)).max(), 1.0, "no step at the coast line")

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], sk["sample_m"])
        crop = Grid.crop(400, 1700, 512, sk["sample_m"])
        r, c = crop.offset_in(full)
        hc = height(sk, crop, "coast")
        np.testing.assert_array_equal(hc, height(sk, full, "coast")[r : r + crop.nz, c : c + crop.nx])
        self.assertLess(hc.min(), 0.0)
        self.assertGreater(hc.max(), 0.0)


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
            b = os.path.join(d, "b.csv")
            with open(b, "w", encoding="utf-8") as f:
                f.write("id,name,footprint_m,storeys\nhut,Hut,6x4,1\n")
            self.assertEqual(sketch_io.load(p, q, b)["buildings"], {"hut": {"w": 6.0, "d": 4.0}})
            bad = sketch()
            bad["version"] = 2
            with open(p, "w", encoding="utf-8") as f:
                json.dump(bad, f)
            with self.assertRaises(ValueError):
                sketch_io.load(p)


if __name__ == "__main__":
    unittest.main()
