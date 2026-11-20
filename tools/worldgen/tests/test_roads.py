"""Stage 9 tests: way profiles and the cross-section flatten."""
import unittest

import numpy as np

from tools.worldgen import roads
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


def bilinear(h, grid, x, z):
    fx, fz = (x - grid.x0) / grid.sample_m, (z - grid.z0) / grid.sample_m
    i, j = np.floor(fx).astype(int), np.floor(fz).astype(int)
    tx, tz = fx - i, fz - j
    return (h[j, i] * (1 - tx) + h[j, i + 1] * tx) * (1 - tz) + (h[j + 1, i] * (1 - tx) + h[j + 1, i + 1] * tx) * tz


class ProfileTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][7:9], ["erosion", "roads"])

    def test_resample_arc(self):
        p, s = roads.resample_arc([(0, 0), (10, 0), (10, 7)], 2.0)
        self.assertEqual(s[-1], 17.0)
        np.testing.assert_allclose(np.diff(s)[:-1], 2.0)
        np.testing.assert_allclose(p[-1], [10, 7])

    def test_smooth_keeps_lines_and_removes_bumps(self):
        x = np.arange(200) * 2.0
        np.testing.assert_allclose(roads.smooth(0.1 * x, 60.0)[20:-20], (0.1 * x)[20:-20])
        bump = np.zeros(200)
        bump[100] = 31.0
        self.assertAlmostEqual(roads.smooth(bump, 60.0).max(), 1.0)

    def test_clamp_grade(self):
        h = np.array([0.0, 0.0, 10.0, 10.0, 0.0, 0.0])
        ds = np.full(5, 2.0)
        out = roads.clamp_grade(h, np.full(5, 0.5), ds)
        self.assertLessEqual(np.abs(np.diff(out) / ds).max(), 0.5 + 1e-12)
        np.testing.assert_allclose(out, out[::-1], err_msg="no direction bias")
        ok = np.array([0.0, 0.5, 1.0, 0.8])
        np.testing.assert_array_equal(roads.clamp_grade(ok, np.full(3, 0.5), np.full(3, 2.0)), ok)

    def test_road_limits_split_at_the_point(self):
        sk = sketch()
        line = sk["lines"][0]
        pts, _ = roads.resample_arc([(300, 1700), (900, 1500), (1900, 1600)])
        g = roads.grade_limits(sk, line, pts)
        k = int(np.argmin(np.hypot(pts[:, 0] - 900, pts[:, 1] - 1500)))
        self.assertTrue(np.all(g[:k] == 0.12) and np.all(g[k:] == 0.18))
        self.assertTrue(np.all(roads.grade_limits(sk, sk["lines"][1], pts) == 0.18))

    def test_profiles_hold_their_limits(self):
        sk = sketch()
        for line in roads.ways(sk):
            pts, s, prof = roads.profile(sk, sk["world_seed"], True, line)
            g = roads.grade_limits(sk, line, pts)
            self.assertLessEqual((np.abs(np.diff(prof)) / np.diff(s) - g).max(), 1e-9, line["id"])


class FlattenTest(unittest.TestCase):
    def test_cross_section(self):
        g = Grid(0.0, -40.0, 1.0, 101, 81)
        h = np.full((81, 101), 50.0)
        pts = np.array([[0.0, 0.0], [100.0, 0.0]])
        out = roads.flatten(h, g, pts, np.array([40.0, 40.0]), 6.5, 6.0)
        z = g.coords()[1][:, 50]
        col = out[:, 50]
        self.assertTrue(np.all(col[np.abs(z) <= 6.5] == 40.0))
        self.assertTrue(np.all(col[np.abs(z) >= 12.5] == 50.0))
        mid = col[np.abs(np.abs(z) - 9.5) < 0.01]
        np.testing.assert_allclose(mid, 45.0)

    def test_final_field_follows_the_profile_and_the_limits(self):
        sk = sketch()
        g = Grid.full(sk["size_m"], 2)
        ctx = run(sk, g, sk["world_seed"], until="roads")
        h = ctx.layers["height"]
        for rec in ctx.roads:
            pts, prof = rec["points"], rec["profile"]
            inside = (pts[:, 0] > 2) & (pts[:, 0] < sk["size_m"] - 4) & (pts[:, 1] > 2) & (pts[:, 1] < sk["size_m"] - 4)
            on = bilinear(h, g, pts[inside, 0], pts[inside, 1])
            # samples lie up to sqrt(2) sample spacings along the line from the point
            self.assertLess(np.abs(on - prof[inside]).max(), 0.18 * 2.0 * 2**0.5, rec["id"])

    def test_track_meets_the_road_at_the_junction(self):
        sk = sketch()
        ctx = run(sk, Grid.crop(900, 1500, 64, 2), sk["world_seed"], until="roads")
        rec = {r["id"]: r for r in ctx.roads}
        road, track = rec["lane"], rec["path"]
        k = int(np.argmin(np.hypot(*(road["points"] - track["points"][0]).T)))
        self.assertLess(abs(road["profile"][k] - track["profile"][0]), 0.5)
        self.assertLess(track["max_cut_fill_m"], 15.0)

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1000, 1450, 512, 4)
        r, c = crop.offset_in(full)
        k = sk["erosion"]["iterations"]
        hf = run(sk, full, 1, until="roads").layers["height"][r : r + crop.nz, c : c + crop.nx]
        hc = run(sk, crop, 1, until="roads").layers["height"]
        np.testing.assert_array_equal(hc[k:-k, k:-k], hf[k:-k, k:-k])


if __name__ == "__main__":
    unittest.main()
