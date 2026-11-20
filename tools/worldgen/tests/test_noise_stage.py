"""Stage 4 tests: biome-weighted noise and the corridor mask."""
import unittest

import numpy as np

from tools.worldgen import stages
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


def ctx(sk, grid, noise=True, seed=None):
    return run(sk, grid, sk["world_seed"] if seed is None else seed, until="noise", noise=noise)


class NoiseStageTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][:4], ["ramp", "bumps", "coast", "noise"])

    def test_noise_off_leaves_the_macro_terrain(self):
        sk = sketch()
        g = Grid.crop(1100, 900, 256, 4)
        before = run(sk, g, 1, until="coast", noise=False).layers["height"]
        np.testing.assert_array_equal(ctx(sk, g, noise=False).layers["height"], before)

    def test_noise_changes_land_and_depends_on_seed(self):
        sk = sketch()
        g = Grid.crop(800, 1000, 256, 4)  # forest, away from every corridor
        a = ctx(sk, g).layers["noise"]
        self.assertGreater(np.abs(a).max(), 2.0)
        self.assertFalse(np.allclose(a, ctx(sk, g, seed=99).layers["noise"]))

    def test_zero_on_every_corridor(self):
        sk = sketch()
        cases = {
            "road centre line": (900, 1500),
            "river centre line": (1400, 1000),
            "point place": (1700, 1200),
            "settlement disc": (560, 540),
            "extra disc": (1720, 310),
            "vista strip": (1300, 1200),
            "north band": (900, 150),
            "east band": (1900, 900),
            "west noise-free edge": (40, 900),
        }
        for what, (x, z) in cases.items():
            g = Grid(float(x) - 8, float(z) - 8, 4.0, 5, 5)
            n = ctx(sk, g).layers["noise"]
            self.assertEqual(float(np.abs(n[2, 2])), 0.0, what)

    def test_mask_tapers_between_d0_and_d1(self):
        sk = sketch()
        d = np.array([0.0, 20.0, 90.0, 160.0, 400.0])
        m = stages.smoothstep(sk["corridor"]["d0"], sk["corridor"]["d1"], d)
        np.testing.assert_allclose(m, [0.0, 0.0, 0.5, 1.0, 1.0])

    def test_amplitude_follows_the_biome_and_is_blended(self):
        sk = sketch()
        # a line of samples from the field rectangle (6 m) into forest (14 m)
        g = Grid(100.0, 1580.0, 4.0, 201, 1)
        fbm, ridged = stages.amplitude_maps(sk, g, sk["world_seed"])
        x = g.coords()[0][0]
        self.assertAlmostEqual(float(fbm[0, np.searchsorted(x, 500.0)]), 6.0, places=6)
        self.assertAlmostEqual(float(fbm[0, np.searchsorted(x, 800.0)]), 14.0, places=6)
        edge = fbm[0, (x > 550) & (x < 650)]
        self.assertTrue(np.all(np.diff(edge) >= -1e-12), "rises monotonically across the edge")
        self.assertLess(np.abs(np.diff(fbm[0])).max(), 8.0 / (100.0 / 4.0) * 1.5, "spread over the blend width")
        self.assertTrue(np.all(ridged == 0.0))

    def test_noise_stays_within_the_worst_case(self):
        sk = sketch()
        g = Grid.full(sk["size_m"], 8)
        n = ctx(sk, g).layers["noise"]
        self.assertLessEqual(n.max(), sk["noise"]["worst_case_m"])
        self.assertGreaterEqual(n.min(), -sk["noise"]["worst_case_m"])

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1300, 700, 512, 4)
        r, c = crop.offset_in(full)
        hf = ctx(sk, full).layers["height"][r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(ctx(sk, crop).layers["height"], hf)


if __name__ == "__main__":
    unittest.main()


class ScarpTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][:5], ["ramp", "bumps", "coast", "noise", "scarp"])

    def test_profile(self):
        sk = sketch()
        sc, size = sk["scarp"], sk["size_m"]
        z = np.array([0.0, 110.0, 155.0, 200.0, 600.0])
        v = stages.scarp(np.full(5, 900.0), z, sc, size)
        np.testing.assert_allclose(v, [160.0, 160.0, 80.0, 0.0, 0.0])
        e = stages.scarp(size - z, np.full(5, 900.0), sc, size)
        np.testing.assert_allclose(e, v, err_msg="east edge like the north edge")

    def test_only_listed_edges_and_nearest_wins(self):
        sk = sketch()
        sc, size = sk["scarp"], sk["size_m"]
        v = stages.scarp(np.array([10.0, 900.0, size - 150.0]), np.array([900.0, size - 10.0, 100.0]), sc, size)
        self.assertEqual(float(v[0]), 0.0, "west edge not listed")
        self.assertEqual(float(v[1]), 0.0, "south edge not listed")
        self.assertEqual(float(v[2]), 160.0, "corner: the nearer (north) edge sets the height")

    def test_steepest_slope(self):
        sk = sketch()
        sc = sk["scarp"]
        z = np.arange(0.0, 300.0, 0.25)
        v = stages.scarp(np.full_like(z, 900.0), z, sc, sk["size_m"])
        steep = np.abs(np.diff(v)).max() / 0.25
        self.assertAlmostEqual(steep, 1.5 * sc["height_m"] / (sc["band_m"] - sc["full_at_m"]), delta=0.01)

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1792, 256, 512, 4)  # touches the north and east edges
        r, c = crop.offset_in(full)
        hf = run(sk, full, 1, until="scarp").layers["height"][r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(run(sk, crop, 1, until="scarp").layers["height"], hf)


class LakeTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][:6], ["ramp", "bumps", "coast", "noise", "scarp", "lake"])

    def test_bed_profile_shore_blend_and_outside(self):
        sk = sketch()
        lk = sk["lake"]
        x = lk["x"] + np.array([0.0, 0.5 * lk["a"], lk["a"], lk["a"] + 15.0, lk["a"] + 30.0, lk["a"] + 80.0])
        z = np.full_like(x, lk["z"])
        h = np.full_like(x, 70.0)
        got = stages.lake_basin(h, x, z, lk)
        lv, dep = lk["level"], lk["max_depth"]
        np.testing.assert_allclose(got, [lv - dep, lv - dep * 0.75, lv, 0.5 * (lv + 70.0), 70.0, 70.0])

    def test_continuous_at_the_outline(self):
        sk = sketch()
        lk = sk["lake"]
        g = Grid(lk["x"] - 260.0, lk["z"] - 160.0, 1.0, 521, 321)
        h = run(sk, g, 1, until="lake", noise=False).layers["height"]
        jump = max(np.abs(np.diff(h, axis=0)).max(), np.abs(np.diff(h, axis=1)).max())
        self.assertLess(jump, 1.0)

    def test_water_record(self):
        sk = sketch()
        c = run(sk, Grid.crop(1000, 1000, 64, 8), 1, until="lake", noise=False)
        (lake,) = c.water["lakes"]
        self.assertEqual((lake["id"], lake["level"], len(lake["polygon"])), ("pond", 50.0, 64))
        lk = sk["lake"]
        rho = [np.hypot((px - lk["x"]) / lk["a"], (pz - lk["z"]) / lk["b"]) for px, pz in lake["polygon"]]
        np.testing.assert_allclose(rho, 1.0, atol=1e-5)

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1100, 1000, 512, 4)
        r, c = crop.offset_in(full)
        hf = run(sk, full, 1, until="lake").layers["height"][r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(run(sk, crop, 1, until="lake").layers["height"], hf)
