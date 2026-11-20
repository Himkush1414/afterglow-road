"""Triangle interpolation (the collision rule) and the public sample world."""
import os
import tempfile
import unittest

import numpy as np

from tools.worldgen import files, sample_world

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


class TriangleTest(unittest.TestCase):
    def test_samples_diagonal_and_planes(self):
        rng = np.random.default_rng(1)
        h = rng.uniform(0, 100, (5, 6))
        self.assertEqual(float(files.height_tri(h, 2.0, 4.0, 6.0)), h[3, 2])
        mid = float(files.height_tri(h, 2.0, 5.0, 7.0))  # centre of cell (2, 3)
        self.assertAlmostEqual(mid, (h[3, 3] + h[4, 2]) / 2.0)
        x, z = np.meshgrid(np.arange(6) * 2.0, np.arange(5) * 2.0)
        plane = 3.0 + 0.4 * x - 0.7 * z
        px, pz = rng.uniform(0, 10, 50), rng.uniform(0, 8, 50)
        np.testing.assert_allclose(files.height_tri(plane, 2.0, px, pz), 3.0 + 0.4 * px - 0.7 * pz)
        self.assertEqual(float(files.height_tri(h, 2.0, -5.0, -5.0)), h[0, 0], "clamped")


class SampleWorldTest(unittest.TestCase):
    def test_committed_sample_world_is_reproduced(self):
        with tempfile.TemporaryDirectory() as d:
            sample_world.write(d)
            for name in ("meta.json", "height.bin", "biome.bin", "height_points.json"):
                with open(os.path.join(d, name), "rb") as a, open(os.path.join(ROOT, "game/content_sample/world", name), "rb") as b:
                    self.assertEqual(a.read(), b.read(), name)


if __name__ == "__main__":
    unittest.main()
