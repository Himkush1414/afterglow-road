"""Settlement layout tests: the shore row and the street crossing."""
import itertools
import math
import unittest

import numpy as np

from tools.worldgen import layout, lots, roads, settle
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


def _cross(u, v):
    return u[0] * v[1] - u[1] * v[0]


def front(lot):
    a = math.radians(lot["yaw_deg"])
    return -math.sin(a), math.cos(a)


class SettleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.ctx = run(sk, Grid.crop(500, 1650, 700, 2), sk["world_seed"], until="lots")
        cls.plan = cls.ctx.settlement

    def of(self, poi):
        return [lt for lt in self.ctx.lots if lt.get("poi") == poi]

    def test_class_order_and_gardens(self):
        main, garden = settle.ordered(self.sk, ["village_house_a", "shed", "shop", "village_house_a", "shed"])
        self.assertEqual((main, garden), (["shop", "village_house_a", "village_house_a"], ["shed", "shed"]))

    def test_handled_places_leave_nothing_pending(self):
        self.assertEqual(self.plan["handled"], {"cove", "hamlet", "town"})
        self.assertEqual(self.ctx.lot_pending, [])
        self.assertEqual([lt["archetype"] for lt in self.of("cove")], ["shop", "village_house_a"])

    def test_every_building_faces_its_way_at_the_setback(self):
        cfg = self.sk["lots"]
        for lt in self.of("cove") + self.of("hamlet"):
            if lt["archetype"] == "shed":
                continue
            way = [r for r in self.ctx.roads if r["id"] == lt["way"]]
            dist, (qx, qz), rec = layout.nearest_way(way, lt["x"], lt["z"])
            self.assertAlmostEqual(dist, rec["core_m"] + cfg["setback_m"] + lt["d"] / 2.0, delta=0.2, msg=lt["id"])
            fx, fz = front(lt)
            self.assertGreater((fx * (qx - lt["x"]) + fz * (qz - lt["z"])) / dist, 0.98, lt["id"])

    def test_row_is_one_side_in_order(self):
        cove = self.of("cove")
        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        sides = []
        for lt in cove:
            _, (qx, qz), _ = layout.nearest_way([lane], lt["x"], lt["z"])
            k = int(np.argmin(np.hypot(*(lane["points"] - (qx, qz)).T)))
            t = lane["points"][min(k + 1, len(lane["points"]) - 1)] - lane["points"][max(k - 1, 0)]
            sides.append(np.sign(t[0] * (lt["z"] - qz) - t[1] * (lt["x"] - qx)))
        self.assertEqual(len(set(sides)), 1)

    def test_cross_has_one_street_through_the_place(self):
        (street,) = [st for st in self.plan["streets"] if st["id"] == "street_hamlet"]
        lane0 = next(r for r in self.ctx.roads if r["id"] == "lane")
        reach = self.sk["lots"]["sizes_m"]["house"][1] + lane0["core_m"]
        for end in np.array(street["points"]):
            self.assertGreaterEqual(layout.nearest_way([lane0], *end)[0], reach - 1.0, "reaches past the Road plots")
        self.assertEqual(street["kind"], "street")
        rec = next(r for r in self.ctx.roads if r["id"] == street["id"])
        self.assertEqual(rec["type"], "street")
        (a, b) = np.array(street["points"])
        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        k = int(np.argmin(np.hypot(lane["points"][:, 0] - 650, lane["points"][:, 1] - 1590)))
        t = lane["points"][k + 1] - lane["points"][k - 1]
        self.assertLess(abs(np.dot((b - a) / np.linalg.norm(b - a), t / np.linalg.norm(t))), 1e-6, "perpendicular")
        self.assertTrue(any(lt["archetype"] != "shed" and abs(_cross(b - a, np.array([lt["x"], lt["z"]]) - a)) / np.linalg.norm(b - a) < 20 for lt in self.of("hamlet")), "plots on the street")

    def test_sheds_behind_houses(self):
        sheds = [lt for lt in self.of("hamlet") if lt["archetype"] == "shed"]
        self.assertEqual(len(sheds), 2)
        houses = [lt for lt in self.of("hamlet") if lt["archetype"] == "village_house_a"]
        for sh, house in zip(sheds, houses):
            way = [r for r in self.ctx.roads if r["id"] == sh["way"]]
            dist, _, rec = layout.nearest_way(way, sh["x"], sh["z"])
            self.assertEqual(sh["way"], house["way"])
            self.assertGreater(dist, layout.nearest_way(way, house["x"], house["z"])[0] + house["d"] / 2.0, "behind its house")

    def test_no_building_on_a_way_and_no_cores_overlap(self):
        mine = {lt["id"] for lt in self.of("cove") + self.of("hamlet")}
        self.assertEqual([o for o in self.ctx.lot_way_overlaps if o[0] in mine], [])
        g = Grid.crop(500, 1650, 700, 1)
        x, z = g.coords()
        group = self.of("cove") + self.of("hamlet")
        cores = [lots.distance(x, z, lt) == 0 for lt in group]
        for (i, a), (j, b) in itertools.combinations(enumerate(cores), 2):
            self.assertFalse(np.any(a & b), (group[i]["id"], group[j]["id"]))

    def test_lots_flat(self):
        x, z = self.ctx.grid.coords()
        h = self.ctx.layers["height"]
        for lt in self.of("cove") + self.of("hamlet"):
            core = lots.distance(x, z, lt) == 0
            np.testing.assert_allclose(h[core], lt["y"], rtol=0, atol=1e-9, err_msg=lt["id"])


if __name__ == "__main__":
    unittest.main()


class JunctionTest(unittest.TestCase):
    def test_ways_take_the_road_height_inside_its_cross_section(self):
        sk = sketch()
        ctx = run(sk, Grid.crop(900, 1550, 256, 4), sk["world_seed"], until="roads")
        lane = next(r for r in ctx.roads if r["id"] == "lane")
        for rec in ctx.roads:
            if rec["type"] == "road":
                continue
            fixed, value = roads.junction_pins(rec["points"], [(lane["points"], lane["arc"], lane["profile"], lane["core_m"])])
            if fixed.any():
                np.testing.assert_array_equal(rec["profile"][fixed], value[fixed], err_msg=rec["id"])


class GridTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.ctx = run(sk, Grid.crop(1520, 1560, 420, 2), sk["world_seed"], until="lots")
        cls.town = [lt for lt in cls.ctx.lots if lt.get("poi") == "town"]

    def test_all_buildings_placed(self):
        self.assertEqual(self.ctx.settlement["unplaced"], [])
        self.assertEqual(sorted(lt["archetype"] for lt in self.town), sorted(["village_house_a"] * 4 + ["shop"] * 2 + ["warehouse"] + ["shed"] * 2))
        self.assertIn("town", self.ctx.settlement["handled"])

    def test_streets(self):
        ids = [st["id"] for st in self.ctx.settlement["streets"] if st["id"].startswith("street_town")]
        self.assertEqual(len(ids), 2 + 3, "one parallel street per side and three cross streets")
        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        par = next(r for r in self.ctx.roads if r["id"] == "street_town_l1")
        d = [layout.nearest_way([lane], *p)[0] for p in par["points"][::10]]
        np.testing.assert_allclose(d, lane["core_m"] + 40.0 + 2.5, atol=0.3, err_msg="an offset curve of the Road")

    def test_shops_front_the_road_and_everything_faces_its_way(self):
        cfg = self.sk["lots"]
        for lt in self.town:
            if lt["archetype"] == "shop":
                self.assertEqual(lt["way"], "lane")
            if lt["archetype"] == "shed":
                continue
            way = [r for r in self.ctx.roads if r["id"] == lt["way"]]
            dist, (qx, qz), rec = layout.nearest_way(way, lt["x"], lt["z"])
            self.assertAlmostEqual(dist, rec["core_m"] + cfg["setback_m"] + lt["d"] / 2.0, delta=0.3, msg=lt["id"])

    def test_no_overlaps_and_flat(self):
        ids = {lt["id"] for lt in self.town}
        self.assertEqual([o for o in self.ctx.lot_way_overlaps if o[0] in ids], [])
        x, z = self.ctx.grid.coords()
        h = self.ctx.layers["height"]
        cores = [lots.distance(x, z, lt) == 0 for lt in self.town]
        for (i, a), (j, b) in itertools.combinations(enumerate(cores), 2):
            self.assertFalse(np.any(a & b), (self.town[i]["id"], self.town[j]["id"]))
        for lt, c in zip(self.town, cores):
            np.testing.assert_allclose(h[c], lt["y"], rtol=0, atol=1e-9, err_msg=lt["id"])

    def test_cross_streets_meet_the_parallel_streets_level(self):
        recs = {r["id"]: r for r in self.ctx.roads}
        par = recs["street_town_l1"]
        for k in range(3):
            cross_st = recs[f"street_town_c{k}"]
            fixed, value = roads.junction_pins(cross_st["points"], [(par["points"], par["arc"], par["profile"], par["core_m"])])
            self.assertTrue(fixed.any())
            np.testing.assert_array_equal(cross_st["profile"][fixed], value[fixed])

    def test_way_grades(self):
        for r in roads.grade_report(self.ctx):
            if r["id"].startswith("street_town"):
                self.assertTrue(r["ok"], r)
