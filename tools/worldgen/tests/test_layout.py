"""Lot list tests: contents parsing, single places, farmsteads, overlaps."""
import math
import unittest

import numpy as np

from tools.worldgen import layout, lots
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch

ARCH = {"village_house_a": {}, "shop": {}, "shed": {}, "garage_workshop": {}, "cabin": {}}


def front(lot):
    a = math.radians(lot["yaw_deg"])
    return -math.sin(a), math.cos(a)


class ParseTest(unittest.TestCase):
    def test_buildings_of(self):
        got = layout.buildings_of("village: 2 village_house_a; shop; 3 sheds; 2 garage_workshops; jetty; boats (props)", ARCH)
        self.assertEqual(got, ["village_house_a"] * 2 + ["shop"] + ["shed"] * 3 + ["garage_workshop"] * 2)
        self.assertEqual(layout.buildings_of("reed beds; clay", ARCH), [])

    def test_yaw_facing(self):
        for (fx, fz), yaw in (((0, 1), 0.0), ((1, 0), 270.0), ((0, -1), 180.0), ((-1, 0), 90.0)):
            self.assertAlmostEqual(layout.yaw_facing(fx, fz), yaw)
            got = front({"yaw_deg": yaw})
            self.assertAlmostEqual(got[0], fx)
            self.assertAlmostEqual(got[1], fz)


class LayoutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.ctx = run(sk, Grid.full(sk["size_m"], 4), sk["world_seed"], until="lots")
        cls.gen = [lt for lt in cls.ctx.lots if "poi" in lt and "archetype" in lt]

    def by_poi(self, poi):
        return [lt for lt in self.gen if lt["poi"] == poi]

    def test_single_place_faces_its_way_with_outbuildings_behind(self):
        cabin, *sheds = self.by_poi("village")
        self.assertEqual([cabin["archetype"]] + [s["archetype"] for s in sheds], ["cabin", "shed", "shed"])
        dist, (qx, qz), _ = layout.nearest_way(self.ctx.roads, cabin["x"], cabin["z"])
        fx, fz = front(cabin)
        to_way = ((qx - cabin["x"]) / dist, (qz - cabin["z"]) / dist)
        self.assertAlmostEqual(fx * to_way[0] + fz * to_way[1], 1.0, places=6)
        for s in sheds:
            self.assertLess((s["x"] - cabin["x"]) * fx + (s["z"] - cabin["z"]) * fz, 0.0, "behind the cabin")
            self.assertEqual(s["yaw_deg"], cabin["yaw_deg"])

    def test_cores_never_within_a_blend_of_each_other(self):
        g = Grid.crop(500, 500, 120, 0.5)
        x, z = g.coords()
        group = self.by_poi("village")
        d = [lots.distance(x, z, lt) for lt in group]
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                self.assertFalse(np.any((d[i] == 0) & (d[j] < self.sk["lots"]["blend_m"] - 0.5)), (group[i]["id"], group[j]["id"]))

    def test_farmstead_around_the_yard(self):
        farm = next(p for p in self.sk["pois"] if p["id"] == "farm")
        group = self.by_poi("farm")
        self.assertEqual(sorted(lt["archetype"] for lt in group), ["barn", "farmhouse", "shed", "shed"])
        half = self.sk["lots"]["yard_m"] / 2.0
        for lt in group:
            fx, fz = front(lt)
            cx, cz = farm["x"] - lt["x"], farm["z"] - lt["z"]
            r = math.hypot(cx, cz)
            self.assertAlmostEqual((fx * cx + fz * cz) / r, 1.0, places=6) if lt["archetype"] != "shed" else self.assertGreater(fx * cx + fz * cz, 0)
            self.assertGreaterEqual(r, half + lt["d"] / 2.0 - 1e-9, "outside the yard")
        house = next(lt for lt in group if lt["archetype"] == "farmhouse")
        track = next(r for r in self.ctx.roads if r["id"] == "track_farm")
        tx, tz = np.array(track["points"][-1]) - np.array(track["points"][-5])
        self.assertGreater((house["x"] - farm["x"]) * tx + (house["z"] - farm["z"]) * tz, 0, "on the far side")

    def test_no_building_on_a_way_and_nothing_pending(self):
        buildings = {lt["id"] for lt in self.gen}
        self.assertEqual([o for o in self.ctx.lot_way_overlaps if o[0] in buildings], [])
        self.assertEqual(self.ctx.lot_pending, [])
        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        x, z = lane["points"][100]
        planted = {"id": "x", "x": x, "z": z, "w": 6.0, "d": 4.0, "yaw_deg": 0.0}
        self.assertIn(("x", "lane"), layout.way_overlaps([planted], self.ctx.roads))

    def test_pull_back_to_the_setback(self):
        sk = sketch()
        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        x, z = lane["points"][300]
        poi = {"id": "p", "x": float(x) + 2.0, "z": float(z) + 2.0, "contents": "cabin"}
        (lot,) = layout.single(sk, poi, ["cabin"], self.ctx.roads)
        dist, _, rec = layout.nearest_way(self.ctx.roads, lot["x"], lot["z"])
        self.assertAlmostEqual(dist, rec["core_m"] + sk["lots"]["setback_m"] + 2.0, delta=1.0)

    def test_fixed_layout_and_settlements(self):
        sk = sketch()
        sk["lots"]["fixed"] = {"village": [{"archetype": "cabin", "dx": 0.0, "dz": 0.0}, {"archetype": "shed", "dx": -14.0, "dz": -10.0}]}
        sk["lots"]["settlements"] = ["farm", "cove", "hamlet", "town"]
        gen, pending = layout.generate(sk, self.ctx.roads)
        self.assertEqual([(lt["archetype"], lt["x"], lt["z"], lt["yaw_deg"]) for lt in gen], [("cabin", 500.0, 500.0, 0.0), ("shed", 486.0, 490.0, 0.0)])
        self.assertEqual(pending, ["farm", "cove", "hamlet", "town"])


if __name__ == "__main__":
    unittest.main()
