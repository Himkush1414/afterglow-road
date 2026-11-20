"""Stage 7 tests: river beds, banks, valleys and the water record."""
import math
import unittest

import numpy as np

from tools.worldgen import geometry, stages
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


def lines():
    return {w["line"]["id"]: w for w in stages.water_lines(sketch())}


class RiverTest(unittest.TestCase):
    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][5:7], ["lake", "rivers"])

    def test_width_and_depth_ramp_over_the_chain(self):
        w = lines()
        up, low, rill = w["brook"], w["brook_low"], w["rill"]
        self.assertAlmostEqual(up["width"][0], 4.0)
        self.assertAlmostEqual(low["width"][-1], 8.0)
        self.assertAlmostEqual(low["depth"][-1], 1.0)
        self.assertLess(up["width"][-1], low["width"][0] + 1e-9)
        self.assertTrue(np.all(np.diff(np.concatenate([up["width"], low["width"]])) >= 0))
        self.assertTrue(np.all(rill["width"] == 2.0) and np.all(rill["depth"] == 0.3))

    def test_nearest_segment_and_position(self):
        g = Grid(0.0, 0.0, 10.0, 11, 3)
        d, seg, t = geometry.polyline_nearest(g, [(0, 10), (50, 10), (100, 10)], 15.0)
        self.assertEqual(seg[1, 3], 0)
        self.assertAlmostEqual(t[1, 3], 0.6)
        self.assertEqual(seg[1, 8], 1)
        self.assertTrue(np.all(d[1] == 0.0))

    def test_bed_never_rises_and_starts_right(self):
        sk = sketch()
        terrain = np.array([30.0, 28.0, 29.0, 25.0, 27.0, 20.0])
        depth = np.full(6, 0.5)
        bed = stages.river_bed(sk, terrain, depth, None)
        np.testing.assert_allclose(bed, [29.5, 27.5, 27.5, 24.5, 24.5, 19.5])
        lake = stages.river_bed(sk, terrain + 40.0, depth, "lake")
        self.assertEqual(lake[0], sk["lake"]["level"] - 0.5)
        self.assertTrue(np.all(np.diff(lake) <= 0))

    def test_level_never_rises_and_stays_above_the_bed(self):
        bed = np.array([10.0, 9.0, 9.0, 9.0, 8.0])
        depth = np.array([0.3, 0.5, 0.8, 1.0, 1.2])  # deepens downstream on a flat bed
        lv = stages.water_level(bed, depth)
        self.assertTrue(np.all(np.diff(lv) <= 0))
        self.assertTrue(np.all(lv > bed))
        np.testing.assert_allclose(lv, [10.3, 9.5, 9.5, 9.5, 9.2])

    def test_carve_profile(self):
        cfg = sketch()["rivers"]
        d = np.array([0.0, 3.0, 4.0 + 10.0, 60.0, 149.0, 400.0])
        h0 = np.full(6, 100.0)
        bed, width, surface = np.full(6, 80.0), np.full(6, 8.0), np.full(6, 81.0)
        v = stages.carve(h0, d, bed, width, surface, cfg, valley=True)
        self.assertEqual(v[0], 80.0)
        self.assertEqual(v[1], 80.0)
        self.assertAlmostEqual(v[2], 80.0 + 10.0 * math.tan(math.radians(30.0)))
        self.assertGreaterEqual(v[3], 100.0 - 12.0)
        self.assertLess(v[3], 100.0)
        self.assertEqual(v[5], 100.0, "nothing beyond the valley")
        low = stages.carve(np.full(6, 82.0), d, bed, width, surface, cfg, valley=True)
        self.assertTrue(np.all(low[3:] >= 81.0), "the valley never goes below the water surface")
        nv = stages.carve(h0, d, bed, width, surface, cfg, valley=False)
        self.assertEqual(nv[3], 100.0, "no valley without the flag")

    def test_run_records_and_levels(self):
        sk = sketch()
        c = run(sk, Grid.crop(1000, 1000, 512, 4), sk["world_seed"], until="rivers")
        rec = {r["id"]: r for r in c.water["rivers"]}
        self.assertEqual(set(rec), {"brook", "brook_low", "ditch", "rill"})
        for r in rec.values():
            lv = np.array(r["level"])
            self.assertTrue(np.all(np.diff(lv) <= 1e-9), f"{r['id']} level rises")
            self.assertEqual(len(r["centre"]), len(lv))
        self.assertAlmostEqual(rec["brook_low"]["level"][0], sk["lake"]["level"], places=6)

    def test_bed_is_cut_into_the_grid(self):
        sk = sketch()
        g = Grid.crop(1400, 1000, 128, 2)
        before = run(sk, g, sk["world_seed"], until="lake").layers["height"]
        after = run(sk, g, sk["world_seed"], until="rivers").layers["height"]
        self.assertTrue(np.all(after <= before + 1e-12), "carving only lowers")
        x, z = g.coords()
        on_line = np.abs(z - 1000.0) < 1.0
        rec = {r["id"]: r for r in run(sk, g, sk["world_seed"], until="rivers").water["rivers"]}["brook"]
        self.assertLessEqual(after[on_line].max(), max(rec["level"]))

    def test_stream_has_no_valley(self):
        sk = sketch()
        g = Grid(1450.0 + 60.0, 600.0, 2.0, 1, 1)  # 60 m east of the rill
        a = run(sk, g, sk["world_seed"], until="lake").layers["height"]
        b = run(sk, g, sk["world_seed"], until="rivers").layers["height"]
        np.testing.assert_array_equal(a, b)

    def test_crop_equals_full_window(self):
        sk = sketch()
        full = Grid.full(sk["size_m"], 4)
        crop = Grid.crop(900, 1100, 512, 4)
        r, c = crop.offset_in(full)
        hf = run(sk, full, 1, until="rivers").layers["height"][r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(run(sk, crop, 1, until="rivers").layers["height"], hf)


if __name__ == "__main__":
    unittest.main()
