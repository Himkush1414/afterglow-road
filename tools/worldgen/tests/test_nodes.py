"""Stage 14b resource nodes on the sample sketch: counts per rule, ground,
gaps, cut faces, road wrecks and top-ups."""
import math
import unittest

import numpy as np

from tools.worldgen import nodes, placement
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


class NodesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sk = sketch()
        cls.ctx = run(cls.sk, Grid.full(cls.sk["size_m"], 2), cls.sk["world_seed"])
        cls.gd = placement.ground(cls.ctx)
        cls.objs, cls.plan = nodes.place_nodes(cls.ctx, cls.gd)

    def _of(self, tid):
        return [o for o in self.objs if o[1] == tid]

    def test_every_rule_places_its_count(self):
        for (tid, k), (want, have) in self.plan.items():
            self.assertEqual(have, want, (tid, k))
        self.assertEqual(len(self._of("car_wreck")), 12, "wrecks topped up to the total")

    def test_nodes_keep_their_gap(self):
        xy = np.array([(o[2], o[3]) for o in self.objs])
        for i in range(len(xy)):
            d = np.hypot(*(xy[i + 1 :] - xy[i]).T)
            self.assertTrue((d >= nodes.MIN_GAP_M - 1e-6).all(), self.objs[i])

    def test_area_nodes_on_their_ground(self):
        g = self.gd
        hills = [b for b, n in g["names"].items() if n == "hills"]
        veins = self._of("iron_vein")[:15]
        for _, _, x, z, _ in veins:
            row, col = int(z // 4), int(x // 4)
            self.assertIn(int(g["biome"][row, col]), hills)
            self.assertGreaterEqual(float(g["slope"][row, col]), 30.0)
            self.assertTrue(g["open"][row, col])

    def test_cut_face_nodes_line_the_bench_wall(self):
        bench = next(c for c in self.ctx.cuts if c["type"] == "bench")
        dx, dz = bench["downhill"]
        for _, _, x, z, yaw in self._of("iron_vein")[21:]:
            across = (x - bench["x"]) * dx + (z - bench["z"]) * dz
            self.assertAlmostEqual(across, -bench["deep_m"] / 2 + 1.0, places=6)
            self.assertEqual(yaw, int(round(math.degrees(math.atan2(dx, -dz)))) % 360)

    def test_steepest_rule_takes_the_steepest_ground(self):
        g = self.gd
        steep = self._of("iron_vein")[15:21]
        self.assertEqual(len(steep), 6)
        slopes = [float(g["slope"][int(z // 4), int(x // 4)]) for _, _, x, z, _ in steep]
        hills = np.isin(g["biome"], [b for b, n in g["names"].items() if n == "hills"]) & g["open"]
        self.assertGreaterEqual(min(slopes), float(np.sort(g["slope"][hills])[-200]), "among the steepest hill texels")

    def test_road_wrecks_face_north_east_beside_the_road(self):
        road = next(r for r in self.ctx.roads if r["id"] == "lane")
        along = self._of("car_wreck")[: self.plan[("car_wreck", 0)][1]]
        self.assertTrue(along)
        pts = np.asarray(road["points"])
        for _, _, x, z, yaw in along:
            self.assertEqual(yaw, 45)
            d = min(_seg_dist(x, z, pts[i], pts[i + 1]) for i in range(len(pts) - 1))
            self.assertAlmostEqual(d, road["core_m"] + 2.0, delta=0.5)


def _seg_dist(x, z, a, b):
    ab = b - a
    t = min(max(((x - a[0]) * ab[0] + (z - a[1]) * ab[1]) / float(ab @ ab), 0.0), 1.0)
    return math.hypot(x - a[0] - ab[0] * t, z - a[1] - ab[1] * t)


if __name__ == "__main__":
    unittest.main()
