"""Stage 14b area objects on the sample sketch: counts, ground, reeds on
the lake shore, region documents and files."""
import os
import tempfile
import unittest

import numpy as np

from tools.worldgen import objects, placement
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch
from tools.worldgen.tests.test_placement import TABLE


class ObjectsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sk = sketch()
        cls.ctx = run(cls.sk, Grid.full(cls.sk["size_m"], 2), cls.sk["world_seed"])
        cls.gd = placement.ground(cls.ctx)
        rec = placement.place_trees(cls.ctx, TABLE, cls.gd)
        cls.cover = placement.tree_cover(rec, TABLE, cls.sk["size_m"])
        cls.objs, cls.counts = objects.area_objects(cls.ctx, cls.gd, cls.cover)

    def test_counts_follow_the_rates(self):
        for name, (want, have) in self.counts.items():
            self.assertEqual(have, want, name)
            self.assertGreater(want, 0, name)
        areas = objects.plan_areas(self.ctx, self.gd, self.cover)
        w, n = areas["stick"]
        self.assertEqual(n, round(float(w.sum()) * 16 / 60), "one stick per 60 m2 under trees")

    def test_objects_stand_where_their_rule_allows(self):
        areas = objects.plan_areas(self.ctx, self.gd, self.cover)
        for kind, tid, x, z, _ in self.objs:
            if tid == "reed_bed" and kind == "forage":
                continue
            col, row = int(x // 4), int(z // 4)
            allowed = any(areas[name][0][row, col] > 0 for name, (k, t) in objects.AREA_KINDS.items() if t == tid)
            self.assertTrue(allowed, (tid, x, z))

    def test_lake_reeds_cover_the_written_share(self):
        lk = self.sk["lake"]
        reeds = [(x, z) for k, t, x, z, _ in self.objs if t == "reed_bed"]
        shore = [(x, z) for x, z in reeds if abs(np.hypot((x - lk["x"]) / lk["a"], (z - lk["z"]) / lk["b"]) - 1) < 0.02]
        want, have = self.counts["reed_bed_shore"]
        self.assertEqual(len(shore), have)
        self.assertEqual(have, want)

    def test_region_documents_and_files(self):
        docs = objects.region_documents(self.objs, self.sk, self.ctx.layers["height"])
        sids = [row[0] for d in docs.values() for kinds in d["objects"].values() for rows in kinds.values() for row in rows]
        self.assertEqual(len(sids), len(set(sids)), "sids unique")
        self.assertEqual(len(sids), len(self.objs))
        for (rx, rz), d in docs.items():
            for kinds in d["objects"].values():
                for rows in kinds.values():
                    for sid, x, y, z, yaw in rows:
                        self.assertEqual(sid >> 20, rz * 4 + rx)
                        self.assertEqual((int(x // 512), int(z // 512)), (rx, rz))
                        self.assertTrue(0 <= yaw < 360)
        with tempfile.TemporaryDirectory() as tmp:
            objects.write_region_files(docs, tmp)
            self.assertEqual(objects.check_region_files(tmp), [])
            name = sorted(os.listdir(os.path.join(tmp, "regions")))[0]
            with open(os.path.join(tmp, "regions", name), "ab") as f:
                f.write(b" ")
            self.assertTrue(objects.check_region_files(tmp))


if __name__ == "__main__":
    unittest.main()
