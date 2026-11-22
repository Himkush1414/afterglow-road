"""T-05-10 checks on the final height field (sample sketch)."""
import copy
import unittest

from tools.worldgen import final_check
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


class FinalCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.ctx = run(sk, Grid.full(sk["size_m"], 2), sk["world_seed"])

    def planted(self):
        ctx = copy.copy(self.ctx)
        ctx.layers = {"height": self.ctx.layers["height"].copy()}
        return ctx

    def with_checks(self, ctx):
        top, x, z = final_check.highest(ctx)
        ctx.sketch = copy.deepcopy(ctx.sketch)
        ctx.sketch["pois"].append({"id": "summit", "x": x + 30.0, "z": z, "y": top})
        ctx.sketch["checks"] = {"peak_poi": "summit", "sea_mouths": ["brook_low"], "river_incision_max_m": 15.0, "peak_within_m": 60.0, "peak_headroom_m": 20.0}
        return ctx

    def test_max_encodable(self):
        self.assertAlmostEqual(final_check.max_encodable(sketch()), 1246.7)

    def test_highest_skips_the_edge_band(self):
        ctx = self.planted()
        before = final_check.highest(ctx)
        ctx.layers["height"][10, 500] += 5000.0  # z = 20 m: inside the north band
        self.assertEqual(final_check.highest(ctx), before)
        ctx.layers["height"][500, 300] += 5000.0
        self.assertEqual(final_check.highest(ctx)[1:], (600.0, 1000.0))

    def test_incision_and_mouths(self):
        rows = final_check.river_incision(self.ctx)
        self.assertEqual([r["id"] for r in rows], ["brook", "brook_low", "ditch", "rill"])
        depth = {r["id"]: r["depth"] for r in rows}
        for i in ("brook", "brook_low", "ditch"):
            self.assertTrue(0.0 < depth[i] <= 14.0, depth)
        # the made-up rill runs over a bump crest, so its running-minimum bed cuts deeper
        self.assertGreater(depth["rill"], 14.0)
        (m,) = final_check.mouths(self.ctx, ["brook_low"])
        self.assertLess(m["y"], 0.0)

    def test_T_05_10_report_passes_and_sees_faults(self):
        ctx = self.with_checks(self.planted())
        lines, bad = final_check.report(ctx)
        self.assertEqual(bad, 0, "\n".join(lines))
        ctx.sketch["checks"]["sea_mouths"] = ["rill"]  # ends inland
        ctx.sketch["checks"]["peak_within_m"] = 10.0
        ctx.sketch["checks"]["river_incision_max_m"] = 0.0
        self.assertEqual(final_check.report(ctx)[1], 1 + 1 + 4)


if __name__ == "__main__":
    unittest.main()
