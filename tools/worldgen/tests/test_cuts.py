"""Stage 11 tests: the mine bench and its trench."""
import math
import unittest

import numpy as np

from tools.worldgen import cuts
from tools.worldgen.grid import Grid
from tools.worldgen import stages
from tools.worldgen.pipeline import STAGES, bilinear, run
from tools.worldgen.tests.sample import sketch


class MineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.grid = Grid.crop(1250, 450, 320, 1)
        cls.before = run(sk, cls.grid, sk["world_seed"], until="lots").layers["height"]
        cls.ctx = run(sk, cls.grid, sk["world_seed"], until="mine")
        cls.bench, cls.trench = cls.ctx.cuts

    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][9:11], ["lots", "mine"])

    def coords(self, cx, cz, ax, az):
        return cuts.box_coords(*self.grid.coords(), cx, cz, ax, az)

    def test_bench_is_level_at_its_lowest_corner_and_only_cuts(self):
        b = self.bench
        dx, dz = b["downhill"]
        along, across = self.coords(b["x"], b["z"], -dz, dx)
        inside = (np.abs(along) <= b["long_m"] / 2) & (np.abs(across) <= b["deep_m"] / 2)
        h = self.ctx.layers["height"]
        np.testing.assert_array_equal(h[inside], np.minimum(self.before[inside], b["floor_y"]), "level at the floor, lower ground kept")
        self.assertGreater(np.mean(h[inside] == b["floor_y"]), 0.5)
        self.assertTrue(np.all(h <= self.before + 1e-9), "cut only, nothing filled")
        corners = [(b["x"] + su * -dz * 60 + sd * dx * 20, b["z"] + su * dx * 60 + sd * dz * 20) for su in (-1, 1) for sd in (-1, 1)]
        self.assertAlmostEqual(b["floor_y"], float(np.min(bilinear(self.grid, self.before, *np.array(corners).T))), places=9)

    def test_bench_runs_along_the_contour(self):
        dx, dz = self.bench["downhill"]
        a = cuts.downhill(self.sk, self.sk["world_seed"], True, self.bench["x"], self.bench["z"])
        self.assertAlmostEqual(math.hypot(dx, dz), 1.0)
        self.assertEqual((dx, dz), a)
        e = 30.0
        up = stages.centre_profile(self.sk, 1, True, np.array([[self.bench["x"] - dx * e, self.bench["z"] - dz * e]]))[0]
        down = stages.centre_profile(self.sk, 1, True, np.array([[self.bench["x"] + dx * e, self.bench["z"] + dz * e]]))[0]
        self.assertGreater(up, down)

    def test_trench_depth_and_floor(self):
        t = self.trench
        ax, az = t["dir"]
        along, across = self.coords(t["start"][0] + ax * t["l_m"] / 2, t["start"][1] + az * t["l_m"] / 2, ax, az)
        inside = (np.abs(along) <= t["l_m"] / 2) & (np.abs(across) <= t["w_m"] / 2)
        self.assertGreater(inside.sum(), 60)
        h, h0 = self.ctx.layers["height"], self.before
        self.assertTrue(np.all(h[inside] >= t["floor_y"] - 1e-9), "never below the bench floor")
        beyond = inside & (along > -t["l_m"] / 2 + self.sk["lots"]["blend_m"])  # past the bench's blend
        expect = np.minimum(h0[beyond], np.maximum(t["floor_y"], h0[beyond] - 6.0))
        np.testing.assert_allclose(h[beyond], expect, rtol=0, atol=1e-9)
        self.assertGreater((h0[inside] - h[inside]).max(), 1.0, "the trench is cut into the slope")

    def test_crop_equals_full_window(self):
        sk = self.sk
        full = Grid.full(sk["size_m"], 2)
        crop = Grid.crop(1150, 450, 256, 2)  # cuts the bench
        r, c = crop.offset_in(full)
        k = sk["erosion"]["iterations"]
        hf = run(sk, full, 1, until="mine").layers["height"][r : r + crop.nz, c : c + crop.nx]
        hc = run(sk, crop, 1, until="mine").layers["height"]
        np.testing.assert_array_equal(hc[k:-k, k:-k], hf[k:-k, k:-k])


if __name__ == "__main__":
    unittest.main()


class QuarryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.grid = Grid.crop(500, 500, 600, 2)
        cls.before = run(sk, cls.grid, sk["world_seed"], until="mine").layers["height"]
        cls.ctx = run(sk, cls.grid, sk["world_seed"], until="quarry")
        cls.q = next(c for c in cls.ctx.cuts if c["type"] == "quarry")

    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][10:12], ["mine", "quarry"])

    def box(self):
        dx, dz = self.q["downhill"]
        return cuts.box_coords(*self.grid.coords(), self.q["x"], self.q["z"], -dz, dx)

    def test_level_floor_with_the_face_height(self):
        along, across = self.box()
        inside = (np.abs(along) <= 100) & (np.abs(across) <= 40)
        h = self.ctx.layers["height"]
        np.testing.assert_allclose(h[inside], self.q["floor_y"], rtol=0, atol=1e-9)
        back = float(bilinear(self.grid, self.before, *self.q["back"]))
        self.assertAlmostEqual(back - self.q["floor_y"], 25.0, places=9)

    def test_face_is_a_two_sample_step_behind_the_bench(self):
        along, across = self.box()
        h, h0 = self.ctx.layers["height"], self.before
        # with the contour as first axis, "across" grows uphill
        behind = (np.abs(along) <= 90) & (across > 40 + 2 * 2.0 + 1e-9) & (across < 60)
        self.assertGreater(behind.sum(), 100)
        np.testing.assert_array_equal(h[behind], h0[behind])
        step = (np.abs(along) <= 90) & (across > 40) & (across <= 44)
        self.assertGreater((h[step] - self.q["floor_y"]).max(), 10.0, "the face rises within two samples")

    def test_uphill_of_the_place_lots(self):
        village_lots = [lt for lt in self.ctx.lots if lt.get("poi") == "village"]
        dx, dz = self.q["downhill"]
        for lt in village_lots:
            for cx, cz in cuts._core_corners(lt):
                along, across = cuts.box_coords(np.array(cx), np.array(cz), self.q["x"], self.q["z"], -dz, dx)
                self.assertLess(float(across), -40.0 - self.sk["lots"]["blend_m"] + 1e-9, "downhill of the bench and its blend")
