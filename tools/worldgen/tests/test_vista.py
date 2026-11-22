"""T-05-8 data part: the vista ray against terrain and trees on world files."""
import os
import tempfile
import unittest

import numpy as np

from tools.worldgen import files, placement, vista

SK = {
    "size_m": 1024,
    "sample_m": 2,
    "height_encoding": {"scale": 0.02, "offset_m": 64.0},
    "pois": [{"id": "home", "x": 100.0, "z": 900.0}, {"id": "top", "x": 900.0, "z": 100.0}],
    "corridor": {"poi_r_m": {"top": 100.0}},
    "checks": {"start_poi": "home", "peak_poi": "top", "eye_offset_m": 15.0, "eye_bearing_deg": 45.0, "eye_height_m": 1.62},
}
TABLE = [{"id": "tall", "height_m": 30.0, "canopy_r_m": 4.0, "trunk_r_m": 0.3}, {"id": "low", "height_m": 2.0, "canopy_r_m": 1.0, "trunk_r_m": 0.05}]


def world(dirname, bump=0.0, trees=()):
    n = 513
    zs, xs = np.mgrid[0:n, 0:n] * 2.0
    h = 10.0 + 0.0004 * (1024.0 - zs) ** 2  # a valley rising ever steeper to the north
    h += bump * np.exp(-((xs - 500.0) ** 2 + (zs - 500.0) ** 2) / 400.0)
    with open(os.path.join(dirname, "height.bin"), "wb") as f:
        f.write(files.compress(files.encode_height(h, SK).tobytes()))
    trees = list(trees) + [(1, 20.0, 20.0, 0)]  # one far from the ray (the writer needs a record)
    rec = {k: np.array([t[i] for t in trees], dtype=dt) for i, (k, dt) in enumerate((("model", np.uint8), ("x", float), ("z", float), ("scale", np.uint8)))}
    rec["yaw"] = np.zeros(len(trees), dtype=np.uint8)
    placement.write_tree_files(rec, dirname)


class VistaTest(unittest.TestCase):
    def run_report(self, **kw):
        with tempfile.TemporaryDirectory() as d:
            world(d, **kw)
            return vista.report(d, SK, TABLE)

    def test_clear_view(self):
        lines, bad = self.run_report(trees=[(1, 500.0, 500.0, 0)])
        self.assertEqual(bad, 0, lines)

    def test_terrain_in_the_way(self):
        lines, bad = self.run_report(bump=200.0)
        self.assertEqual(bad, 1, lines)
        self.assertIn("FAIL", lines[1])
        self.assertIn("(500,500)", lines[1])

    def test_horizon_on_a_rounded_summit(self):
        row = 50.0 - 0.01 * (np.arange(101) - 100.0) ** 2  # a dome whose top is at x = 100
        x, _, _ = vista.horizon(vista.Grid(0.0, 0.0, 1.0, 101, 2), np.vstack([row, row]), (-1000.0, 0.5, 0.0), (100.0, 0.5, 51.62))
        self.assertLess(x, 100.0)  # the near shoulder hides the very top
        self.assertGreater(x, 50.0)

    def test_tree_in_the_way_and_beside_it(self):
        # the eye is 1.62 m up; at 20 m along the ray it is still low enough for a 30 m tree
        ex, ez = 100.0 + 15.0 * np.sin(np.pi / 4), 900.0 - 15.0 * np.cos(np.pi / 4)
        u = np.array([900.0 - ex, 100.0 - ez]) / np.hypot(900.0 - ex, 100.0 - ez)
        on = (ex + 20.0 * u[0], ez + 20.0 * u[1])
        off = (on[0] + 6.0 * u[1], on[1] - 6.0 * u[0])  # 6 m to the side: beyond the 4 m canopy (scale 0.75..1.25)
        lines, bad = self.run_report(trees=[(0, on[0], on[1], 0), (0, off[0], off[1], 0)])
        self.assertEqual(bad, 1, lines)
        self.assertIn("1 in the way", lines[2])

    def test_scale_byte(self):
        self.assertAlmostEqual(vista.SCALE_BASE + 255 / vista.SCALE_DIV, 1.25)


if __name__ == "__main__":
    unittest.main()
