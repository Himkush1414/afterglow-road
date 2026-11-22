"""Stage 12a: the outer ring heights and file."""
import copy
import unittest

import numpy as np

from tools.worldgen import files, outer, stages
from tools.worldgen.tests.sample import sketch


class OuterRingTest(unittest.TestCase):
    def test_grid_lines_and_layout(self):
        sk = sketch()
        a = outer.axis(sk)
        self.assertEqual(a.size, 33)
        self.assertEqual((a[0], a[-1]), (-1024.0, 3072.0))
        self.assertIn(0.0, a)
        self.assertIn(2048.0, a)
        self.assertEqual(outer.check_layout(sk), [])
        bad = copy.deepcopy(sk)
        bad["outer"]["range"] = [-1000.0, 3096.0]
        self.assertEqual(len(outer.check_layout(bad)), 2, "map edges off the grid")
        bad["outer"]["cells"] = 31
        self.assertEqual(len(outer.check_layout(bad)), 3, "range not cells x cell_m")

    def test_heights_continue_the_macro_terrain(self):
        sk = sketch()
        a = outer.axis(sk)
        x, z = np.meshgrid(a, a)
        h = outer.heights(sk)
        want = stages.macro(x, z, sk, sk["world_seed"], True) + stages.scarp(x, z, sk["scarp"], sk["size_m"])
        far = np.hypot(x - 1000.0, z + 600.0) >= 800.0  # beyond the backdrop bump
        np.testing.assert_allclose(h[far], want[far])
        d = float(np.hypot(x[0, 16] - 1000.0, z[0, 16] + 600.0))
        self.assertAlmostEqual(float(h[0, 16] - want[0, 16]), 200.0 * (1 - (d / 800.0) ** 2) ** 2, places=6)

    def test_north_and_east_stay_raised_and_west_is_sea(self):
        sk = sketch()
        a = outer.axis(sk)
        x, z = np.meshgrid(a, a)
        h = outer.heights(sk)
        self.assertTrue(np.all(h[(x < 0.0) & (z > 300.0) & (z < 1800.0)] < 0.0), "west of the map is sea")
        inland = (x > 300.0) & (x < 1800.0) & (z < -900.0)
        base = stages.macro(x, z, sk, sk["world_seed"], True)
        np.testing.assert_allclose((h - base)[inland & (np.hypot(x - 1000.0, z + 600.0) >= 800.0)], 160.0)

    def test_file_bytes(self):
        sk = sketch()
        raw = outer.outer_bytes(sk)
        self.assertEqual(len(raw), 33 * 33 * 2)
        back = files.decode_height(np.frombuffer(raw, dtype="<u2").reshape(33, 33), sk)
        np.testing.assert_allclose(back, outer.heights(sk), atol=0.01 + 1e-9)


if __name__ == "__main__":
    unittest.main()
