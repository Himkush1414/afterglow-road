"""Leaf-card atlas painter: determinism, sizes, cell margins, coverage,
colour bleed and palette limits."""
import copy
import os
import tempfile
import unittest

import numpy as np
from PIL import Image

from tools.assetgen import leaves

ATLAS = {
    "name": "sample", "seed": 5, "grid": 2, "shape": "leaf",
    "palette": [[30, 50, 20], [45, 65, 30], [60, 80, 40], [75, 95, 50], [90, 110, 60], [105, 125, 70]],
    "twigs": 4, "fan_deg": 100, "twig_px": 1.5, "count": 60, "leaf_px": [10, 5],
    "spread": 0.06, "margin": 0.06,
    "kuwahara_radius": 1, "brush": {"cells": [2, 4], "strength": 0.06},
    "normal_strength": 2.0, "roughness": [0.6, 0.85], "ao": 0.5,
}
SIZE = 128


class LeavesTest(unittest.TestCase):
    def test_deterministic_and_both_shapes_paint(self):
        a1, n1 = leaves.paint_atlas(ATLAS, SIZE)
        a2, n2 = leaves.paint_atlas(ATLAS, SIZE)
        self.assertTrue(np.array_equal(a1, a2) and np.array_equal(n1, n2))
        needle = dict(ATLAS, shape="needle", leaf_px=[12, 1.2], bundle=5)
        a3, _ = leaves.paint_atlas(needle, SIZE)
        self.assertGreater((a3[..., 3] >= 128).mean(), 0.02)

    def test_cells_keep_their_margin_and_hold_a_clump(self):
        ca, _ = leaves.paint_atlas(ATLAS, SIZE)
        n = SIZE // ATLAS["grid"]
        m = int(np.ceil(ATLAS["margin"] * n))
        for cy in range(ATLAS["grid"]):
            for cx in range(ATLAS["grid"]):
                alpha = ca[cy * n : (cy + 1) * n, cx * n : (cx + 1) * n, 3]
                border = np.ones_like(alpha, dtype=bool)
                border[m : n - m, m : n - m] = False
                self.assertEqual(int(alpha[border].max()), 0, (cx, cy))
                cover = (alpha >= 128).mean()
                self.assertTrue(0.05 < cover < 0.8, (cx, cy, cover))
                rows = np.nonzero((alpha >= 128).any(axis=1))[0]
                self.assertGreater(rows.max(), n * 0.8)  # the twigs start at the bottom edge

    def test_transparent_pixels_carry_leaf_colour(self):
        ca, _ = leaves.paint_atlas(ATLAS, SIZE)
        clear = ca[..., 3] == 0
        self.assertTrue(clear.any())
        self.assertGreater(ca[..., 1][clear].mean(), 30)  # bled green, not black

    def test_files_and_lo_set(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = leaves.write({"category": "s", "size": SIZE, "atlases": [ATLAS]}, d)
            for kind in ("ca", "nra"):
                with Image.open(os.path.join(d, "hi", f"s_sample_{kind}.png")) as hi, Image.open(os.path.join(d, "lo", f"s_sample_{kind}.png")) as lo:
                    self.assertEqual((hi.size, lo.size, hi.mode), ((SIZE, SIZE), (SIZE // 2, SIZE // 2), "RGBA"))
            self.assertEqual(manifest["atlases"][0]["grid"], 2)
            self.assertTrue(os.path.exists(os.path.join(d, "s_leaves.json")))

    def test_palette_limits(self):
        bad = copy.deepcopy(ATLAS)
        bad["palette"] = bad["palette"][:3]
        with self.assertRaises(ValueError):
            leaves.paint_atlas(bad, SIZE)


if __name__ == "__main__":
    unittest.main()
