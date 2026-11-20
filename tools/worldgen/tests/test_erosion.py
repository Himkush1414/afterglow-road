"""Stage 8 tests: thermal erosion."""
import math
import unittest

import numpy as np

from tools.worldgen import stages
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch

FREE = np.zeros((41, 41), dtype=bool)


def max_step(h):
    return max(np.abs(np.diff(h, axis=0)).max(), np.abs(np.diff(h, axis=1)).max())


class ErosionTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][6:8], ["rivers", "erosion"])

    def test_gentle_slopes_do_not_move(self):
        x = np.arange(41) * 2.0
        h = np.tile(x * math.tan(math.radians(30.0)), (41, 1))
        np.testing.assert_array_equal(stages.thermal_erosion(h, 2.0, 38.0, 30, FREE), h)

    def test_spike_spreads_and_mass_is_kept(self):
        h = np.zeros((41, 41))
        h[20, 20] = 50.0
        out = stages.thermal_erosion(h, 2.0, 38.0, 30, FREE)
        self.assertAlmostEqual(out.sum(), h.sum(), places=9)
        self.assertLess(out.max(), 50.0)
        self.assertLess(max_step(out), max_step(h))
        self.assertTrue(np.all(out >= -1e-12), "no hole is dug next to the spike")
        np.testing.assert_allclose(out, out.T, atol=1e-9)  # symmetric spread

    def test_converges_to_the_talus_slope(self):
        h = np.zeros((41, 41))
        h[:, 20:] = 20.0  # a 20 m wall
        out = stages.thermal_erosion(h, 2.0, 38.0, 400, FREE)
        self.assertLessEqual(max_step(out), 2.0 * math.tan(math.radians(38.0)) + 0.05)

    def test_frozen_cells_neither_give_nor_take(self):
        h = np.zeros((41, 41))
        h[:, 20:] = 20.0
        frozen = np.zeros_like(FREE)
        frozen[:, 18:23] = True
        out = stages.thermal_erosion(h, 2.0, 38.0, 30, frozen)
        np.testing.assert_array_equal(out[:, 18:23], h[:, 18:23])
        self.assertAlmostEqual(out.sum(), h.sum(), places=9)

    def test_scarp_band_is_frozen(self):
        sk = sketch()
        band = stages.scarp_band(np.array([900.0, 900.0, 1900.0, 10.0]), np.array([100.0, 900.0, 900.0, 900.0]), sk["scarp"], sk["size_m"])
        self.assertEqual(band.tolist(), [True, False, True, False])

    def test_crop_equals_full_window_inside_the_reach(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(1500, 500, 512, 4)  # steep ground on the big bump
        r, c = crop.offset_in(full)
        k = sk["erosion"]["iterations"]
        hf = run(sk, full, 1, until="erosion").layers["height"][r : r + crop.nz, c : c + crop.nx]
        hc = run(sk, crop, 1, until="erosion").layers["height"]
        np.testing.assert_array_equal(hc[k:-k, k:-k], hf[k:-k, k:-k])


if __name__ == "__main__":
    unittest.main()
