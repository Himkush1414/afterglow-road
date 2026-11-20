"""Geometry tests: splines and distance fields."""
import unittest

import numpy as np

from tools.worldgen import geometry
from tools.worldgen.grid import Grid


class SplineTest(unittest.TestCase):
    def test_passes_through_every_point(self):
        pts = [(0, 0), (100, 50), (180, 40), (300, 200)]
        s = geometry.catmull_rom(pts, 8.0)
        for p in pts:
            self.assertLess(np.hypot(*(s - p).T).min(), 1e-9)
        np.testing.assert_array_equal(s[0], pts[0])
        np.testing.assert_array_equal(s[-1], pts[-1])
        # uniform parameter steps: arc spacing varies, but stays near `step`
        self.assertLessEqual(np.hypot(*np.diff(s, axis=0).T).max(), 1.5 * 8.0)

    def test_straight_points_give_a_straight_line(self):
        s = geometry.catmull_rom([(0, 0), (100, 0), (200, 0)], 10.0)
        np.testing.assert_array_equal(s[:, 1], 0.0)


class DistanceTest(unittest.TestCase):
    def test_polyline_distance_and_cap(self):
        g = Grid(0.0, 0.0, 10.0, 31, 21)  # x 0..300, z 0..200
        d = geometry.polyline_distance(g, [(50, 100), (250, 100)], 60.0)
        x, z = g.coords()
        exact = np.where(
            x < 50, np.hypot(x - 50, z - 100), np.where(x > 250, np.hypot(x - 250, z - 100), np.abs(z - 100))
        )
        np.testing.assert_allclose(d, np.minimum(exact, 60.0))
        self.assertEqual(d.max(), 60.0)

    def test_polyline_distance_far_line_leaves_the_cap(self):
        g = Grid(0.0, 0.0, 10.0, 11, 11)
        d = geometry.polyline_distance(g, [(500, 500), (600, 500)], 40.0)
        self.assertTrue(np.all(d == 40.0))

    def test_polyline_distance_crop_equals_full_window(self):
        line = geometry.catmull_rom([(100, 900), (700, 300), (1500, 800)])
        full = Grid.full(2048, 4)
        crop = Grid.crop(700, 400, 512, 4)
        r, c = crop.offset_in(full)
        a = geometry.polyline_distance(full, line, 160.0)[r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(a, geometry.polyline_distance(crop, line, 160.0))

    def test_strip_bearing_and_distance(self):
        # 90 degrees = east: the strip covers x 100..300, z 90..110
        x = np.array([150.0, 150.0, 350.0, 50.0, 150.0])
        z = np.array([100.0, 109.0, 100.0, 100.0, 130.0])
        d = geometry.strip_distance(x, z, (100.0, 100.0), 90.0, 200.0, 20.0)
        np.testing.assert_allclose(d, [0.0, 0.0, 50.0, 50.0, 20.0], atol=1e-9)
        # 0 degrees = north (-z)
        d = geometry.strip_distance(np.array([0.0]), np.array([-50.0]), (0.0, 0.0), 0.0, 100.0, 4.0)
        self.assertAlmostEqual(float(d[0]), 0.0)
        d = geometry.strip_distance(np.array([0.0]), np.array([50.0]), (0.0, 0.0), 0.0, 100.0, 4.0)
        self.assertAlmostEqual(float(d[0]), 50.0)

    def test_disc_distance(self):
        d = geometry.disc_distance(np.array([0.0, 30.0, 0.0]), np.array([0.0, 40.0, 10.0]), 0.0, 0.0, 20.0)
        np.testing.assert_allclose(d, [0.0, 30.0, 0.0])


if __name__ == "__main__":
    unittest.main()
