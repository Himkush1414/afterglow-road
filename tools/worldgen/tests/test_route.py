"""Track routing tests."""
import math
import unittest

import numpy as np

from tools.worldgen import geometry, roads, route
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


def goal_row(nz, nx, row):
    g = np.zeros((nz, nx), dtype=bool)
    g[row, :] = True
    return g


class AStarTest(unittest.TestCase):
    def test_moves(self):
        self.assertEqual(len(route.MOVES), 16)

    def test_flat_ground_goes_straight(self):
        h = np.zeros((20, 20))
        target = [(c * 16.0, 0.0) for c in range(20)]
        path = route.astar(h, 16.0, (15, 5), goal_row(20, 20, 0), target, 0.18, 150.0)
        self.assertEqual(path[0], (15, 5))
        self.assertEqual(path[-1][0], 0)
        self.assertTrue(all(c == 5 for _, c in path), path)

    def test_walls_force_a_detour_or_block(self):
        h = np.zeros((20, 20))
        h[8, :15] = 100.0  # wall with a gap on the east side
        target = [(c * 16.0, 0.0) for c in range(20)]
        path = route.astar(h, 16.0, (15, 5), goal_row(20, 20, 0), target, 0.18, 150.0)
        self.assertIsNotNone(path)
        for (r1, c1), (r2, c2) in zip(path, path[1:]):
            if min(r1, r2) < 8 < max(r1, r2) or 8 in (r1, r2):
                self.assertGreaterEqual(min(c1, c2), 14, f"crosses the wall at {(r1, c1)} -> {(r2, c2)}")
        for (r1, c1), (r2, c2) in zip(path, path[1:]):
            self.assertLessEqual(abs(h[r2, c2] - h[r1, c1]) / (math.hypot(r2 - r1, c2 - c1) * 16.0), 0.18)
        h[8:10, :] = 100.0  # closed (two rows, so no knight move jumps it)
        self.assertIsNone(route.astar(h, 16.0, (15, 5), goal_row(20, 20, 0), target, 0.18, 150.0))

    def test_simplify(self):
        pts = [(0, 0), (10, 0.5), (20, 0), (20, 30)]
        self.assertEqual(route.simplify(pts, 1.0), [(0, 0), (20, 0), (20, 30)])


class RoutedTrackTest(unittest.TestCase):
    def test_sample_place_gets_a_track_from_the_road(self):
        sk = sketch()
        lines, failed = route.routed_tracks(sk, sk["world_seed"], True)
        self.assertEqual(failed, [])
        self.assertEqual([ln["id"] for ln in lines], ["track_farm"])
        line = lines[0]
        road = geometry.catmull_rom(sk["lines"][0]["points"])
        start, end = line["points"][0], line["points"][-1]
        self.assertLess(np.hypot(*(road - start).T).min(), 1e-6, "starts on the road")
        farm = next(p for p in sk["pois"] if p["id"] == "farm")
        self.assertEqual(end, [farm["x"], farm["z"]])
        self.assertEqual(lines, route.routed_tracks(sketch(), sk["world_seed"], True)[0], "deterministic")

    def test_profile_and_field_hold_the_limit(self):
        sk = sketch()
        ctx = run(sk, Grid.crop(1700, 1400, 512, 4), sk["world_seed"], until="roads")
        rec = next(r for r in ctx.roads if r["id"] == "track_farm")
        self.assertLessEqual((np.abs(np.diff(rec["profile"])) / np.diff(rec["arc"])).max(), 0.18 + 1e-9)
        self.assertEqual(ctx.route_failures, [])

    def test_unreachable_place_is_reported(self):
        sk = sketch()
        sk["tracks"]["max_grade"] = 1e-6
        lines, failed = route.routed_tracks(sk, sk["world_seed"], True)
        self.assertEqual((lines, failed), ([], ["farm"]))

    def test_listed_track_end_needs_no_route(self):
        sk = sketch()
        farm = next(p for p in sk["pois"] if p["id"] == "farm")
        sk["lines"][1]["points"][-1] = [farm["x"], farm["z"]]
        self.assertEqual(route.routed_tracks(sk, sk["world_seed"], True), ([], []))
        self.assertEqual([ln["kind"] for ln in roads.ways(sk)], ["track", "road"])


if __name__ == "__main__":
    unittest.main()
