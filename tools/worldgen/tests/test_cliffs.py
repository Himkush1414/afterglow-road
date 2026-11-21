"""Cliff faces on the sample sketch: every steep texel of a patch spanning
6 m lies under a face, faces face downhill, veins and seams get carriers."""
import math
import unittest

import numpy as np

from tools.worldgen import cliffs, nodes, placement
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


class CliffTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sk = sketch()
        cls.ctx = run(cls.sk, Grid.full(cls.sk["size_m"], 2), cls.sk["world_seed"])
        cls.gd = placement.ground(cls.ctx)
        cls.node_objs, _ = nodes.place_nodes(cls.ctx, cls.gd)
        cls.faces, cls.steep, cls.covered = cliffs.place_faces(cls.ctx, cls.gd, cls.node_objs)

    def test_no_steep_patch_without_a_face(self):
        self.assertGreater(int(self.steep.sum()), 50, "the sample's scarp is steep")
        self.assertEqual(cliffs.uncovered(self.steep, self.covered), 0)

    def test_single_steep_texels_do_not_count(self):
        lone = np.zeros((10, 10), dtype=bool)
        lone[2, 2] = True
        lone[6, 5:7] = True
        gd = {"slope": np.where(lone, 60.0, 10.0)}
        got = cliffs.steep_texels(gd, {"min_slope_deg": 50, "min_extent_m": 6})
        self.assertFalse(got[2, 2], "a 4 m texel alone spans less than 6 m")
        self.assertTrue(got[6, 5] and got[6, 6], "two texels span 8 m")

    def test_faces_face_downhill_and_lean_with_the_slope(self):
        for v, x, z, yaw, pitch, why in self.faces[:200]:
            row, col = int(z // 4), int(x // 4)
            nx, nz = self.gd["normal"][0][row, col], self.gd["normal"][1][row, col]
            want = math.degrees(math.atan2(nx, -nz)) % 360
            self.assertLessEqual(min(abs(yaw - want), 360 - abs(yaw - want)), 0.5 + 1e-9)
            self.assertAlmostEqual(pitch, round(float(self.gd["slope"][row, col])))
            self.assertIn(v, self.sk["cliffs"]["variants"])

    def test_every_vein_and_seam_stands_on_a_face(self):
        carried = [o for o in self.node_objs if o[1] in ("iron_vein", "coal_seam")]
        self.assertTrue(carried)
        for _, _, x, z, _ in carried:
            self.assertTrue(self.covered[int(z // 4), int(x // 4)], (x, z))


if __name__ == "__main__":
    unittest.main()
