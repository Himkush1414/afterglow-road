"""Stage 10 tests: lots are flat at their pre-lot mean and blend back."""
import unittest

import numpy as np

from tools.worldgen import lots
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import STAGES, run
from tools.worldgen.tests.sample import sketch


class LotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.grid = Grid.full(sk["size_m"], 2)
        cls.before = run(sk, cls.grid, sk["world_seed"], until="roads").layers["height"]
        cls.ctx = run(sk, cls.grid, sk["world_seed"], until="lots")

    def test_order(self):
        self.assertEqual([n for n, _ in STAGES][8:10], ["roads", "lots"])

    def test_lots_flat_at_their_mean(self):
        x, z = self.grid.coords()
        h = self.ctx.layers["height"]
        self.assertEqual([lt["id"] for lt in self.ctx.lots], ["hut", "ring", "pad"])
        for lot in self.ctx.lots:
            core = lots.distance(x, z, lot) == 0.0
            self.assertGreater(core.sum(), 4, lot["id"])
            np.testing.assert_allclose(h[core], lot["y"], rtol=0, atol=1e-9, err_msg=lot["id"])
            self.assertAlmostEqual(lot["y"], float(self.before[core].mean()), places=9)

    def test_blend_edge_and_outside(self):
        x, z = self.grid.coords()
        h = self.ctx.layers["height"]
        for lot in self.ctx.lots:
            d = lots.distance(x, z, lot)
            outside = (d >= lot["blend_m"]) & (d < lot["blend_m"] + 20.0)
            np.testing.assert_array_equal(h[outside], self.before[outside])

    def test_rotation_and_margin(self):
        lot = {"x": 0.0, "z": 0.0, "w": 10.0, "d": 4.0, "yaw_deg": 90.0, "margin_m": 1.0}
        d = lots.distance(np.array([0.0, 5.5, 0.0]), np.array([5.5, 0.0, 6.5]), lot)
        np.testing.assert_allclose(d, [0.0, 2.5, 0.5], atol=1e-12)  # turned: long side north-south
        disc = {"x": 0.0, "z": 0.0, "r": 10.0, "margin_m": 0.0}
        np.testing.assert_allclose(lots.distance(np.array([3.0, 13.0]), np.array([4.0, 0.0]), disc), [0.0, 3.0])

    def test_extra_lot_takes_its_place_position_and_no_margin(self):
        pad = next(lt for lt in lots.all_lots(self.sk) if lt["id"] == "pad")
        village = next(p for p in self.sk["pois"] if p["id"] == "village")
        self.assertEqual((pad["x"], pad["z"], pad["margin_m"]), (village["x"], village["z"], 0.0))
        hut = next(lt for lt in lots.all_lots(self.sk) if lt["id"] == "hut")
        self.assertEqual((hut["margin_m"], hut["blend_m"]), (3.0, 6.0))

    def test_crop_cutting_a_lot_equals_the_full_window(self):
        sk = self.sk
        crop = Grid.crop(1700 - 250, 1200, 512, 2)  # x 1194..1706: the hut straddles the east edge
        r, c = crop.offset_in(self.grid)
        k = sk["erosion"]["iterations"]
        hc = run(sk, crop, sk["world_seed"], until="lots").layers["height"]
        hf = self.ctx.layers["height"][r : r + crop.nz, c : c + crop.nx]
        np.testing.assert_array_equal(hc[k:-k, k:-k], hf[k:-k, k:-k])
        ctx = run(sk, crop, sk["world_seed"], until="lots")
        self.assertEqual(next(lt for lt in ctx.lots if lt["id"] == "hut")["y"], next(lt for lt in self.ctx.lots if lt["id"] == "hut")["y"])


if __name__ == "__main__":
    unittest.main()
