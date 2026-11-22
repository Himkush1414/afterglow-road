"""T-05-5 walkable grid: edges, components, pocket fill and the report."""
import copy
import unittest

import numpy as np

from tools.worldgen import reach
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


class GridTest(unittest.TestCase):
    def test_shift(self):
        a = np.arange(12).reshape(3, 4)
        out = reach._shift(a, 0, 1, -1)
        np.testing.assert_array_equal(out[:, :3], a[:, 1:])
        self.assertTrue(np.all(out[:, 3] == -1))
        out = reach._shift(a, -1, 0, -1)
        np.testing.assert_array_equal(out[1:], a[:2])

    def test_edges_slope_and_depth(self):
        h = np.array([[0.0, 1.7, 3.6], [0.0, 0.0, 0.0]])  # tan(42 deg) * 2 m = 1.80 m
        d = np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 1.3]])
        e, s = reach.edges(h, d, 2.0, 42.0, 1.2)
        np.testing.assert_array_equal(e, [[True, False], [True, False]])
        np.testing.assert_array_equal(s, [[True, True, False]])

    def test_components_follow_a_winding_path(self):
        n = 41
        e = np.zeros((n, n - 1), dtype=bool)
        s = np.zeros((n - 1, n), dtype=bool)
        for j in range(0, n, 2):  # a serpentine: rows joined at alternating ends
            e[j, :] = True
            if j + 2 < n:
                s[j, n - 1 if j % 4 == 0 else 0] = True
                s[j + 1, n - 1 if j % 4 == 0 else 0] = True
        lab = reach.components(e, s)
        self.assertEqual(len(np.unique(lab[::2])), 1)
        self.assertEqual(lab[n - 1, 5], 0)
        self.assertNotEqual(lab[1, 5], 0)

    def test_fill_takes_the_closest_reached_height(self):
        h = np.array([[0.0, 0.0, 0.0, 0.0], [0.0, 5.0, 9.0, 0.0], [10.0, 10.0, 10.0, 10.0]])
        reached = np.ones(h.shape, dtype=bool)
        pocket = np.zeros(h.shape, dtype=bool)
        pocket[1, 1:3] = True
        reached &= ~pocket
        out, changed, left = reach.fill(h, pocket, reached)
        self.assertEqual((changed, left), (2, 0))
        self.assertEqual(out[1, 1], 0.0)  # 5 is closer to the row above (0) than below (10)
        self.assertEqual(out[1, 2], 10.0)
        island = np.zeros(h.shape, dtype=bool)
        island[1, 1] = True
        self.assertEqual(reach.fill(h, island, np.zeros(h.shape, dtype=bool))[1:], (0, 1))


class PocketStageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.ctx = run(sk, Grid.full(sk["size_m"], 2), sk["world_seed"])

    def test_order_and_crop(self):
        self.assertEqual([n for n, _ in STAGES][-1], "pockets")
        sk = sketch()
        ctx = run(sk, Grid.crop(900, 1500, 64, 2), sk["world_seed"])
        self.assertEqual(ctx.pocket_fill["rounds"], 0)

    def test_T_05_5_on_the_sample(self):
        self.assertEqual(self.ctx.pocket_fill["left"], 0)
        lines, bad = reach.report(self.ctx)
        pockets = [ln for ln in lines if "pockets" in ln]
        self.assertTrue(pockets and "FAIL" not in pockets[0], lines)
        outer = [ln for ln in lines if "outer" in ln]
        self.assertTrue(outer and "FAIL" not in outer[0], lines)

    def test_a_planted_pit_is_found_and_filled(self):
        ctx = copy.copy(self.ctx)
        ctx.layers = {"height": self.ctx.layers["height"].copy()}
        h = ctx.layers["height"]
        j, i = reach.cell_of(ctx.grid, 600.0, 1000.0)
        h[j - 5 : j + 6, i - 5 : i + 6] -= 30.0  # a 22 m shaft with vertical walls
        w = reach.Walk(ctx)
        self.assertTrue(w.pockets()[j, i])
        self.assertGreater(reach.report(ctx, w)[1], 0)
        reach._stage_pockets(ctx)
        self.assertGreater(ctx.pocket_fill["cells"], 0)
        self.assertFalse(reach.Walk(ctx).pockets().any())


if __name__ == "__main__":
    unittest.main()
