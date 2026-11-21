"""Stage 14a tree placement on the sample sketch: exact counts on usable
ground, spacing, size mix, stunted biomes, tree limits and dead wood."""
import unittest

import numpy as np

from tools.worldgen import placement
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import run
from tools.worldgen.tests.sample import sketch


def _row(i, sp, size, canopy, trunk):
    return {"id": i, "species": sp, "size": size, "canopy_r_m": canopy, "trunk_r_m": trunk}


TABLE = [
    _row("pine_young", "pine", "young", 1.2, 0.07),
    _row("pine_mature", "pine", "mature", 3.0, 0.2),
    _row("pine_old", "pine", "old", 4.5, 0.32),
    _row("birch_young", "birch", "young", 1.0, 0.05),
    _row("birch_mature", "birch", "mature", 2.8, 0.14),
    _row("birch_old", "birch", "old", 3.6, 0.2),
    _row("oak_young", "oak", "young", 1.6, 0.08),
    _row("oak_mature", "oak", "mature", 5.5, 0.3),
    _row("oak_old", "oak", "old", 8.0, 0.5),
    _row("willow_young", "willow", "young", 1.6, 0.07),
    _row("willow_mature", "willow", "mature", 5.0, 0.25),
    _row("snag", "dead", "dead", 0.8, 0.18),
    _row("fallen_log", "dead", "dead", 0.0, 0.2),
]


class PlacementTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sk = sketch()
        cls.ctx = run(cls.sk, Grid.full(cls.sk["size_m"], 2), cls.sk["world_seed"])
        cls.gd = placement.ground(cls.ctx)
        cls.expect = placement.expected_counts(cls.sk, cls.gd)
        cls.rec = placement.place_trees(cls.ctx, TABLE, cls.gd)

    def test_counts_match_density_times_usable_area(self):
        report = placement.count_report(self.rec, self.expect, TABLE)
        self.assertTrue(report)
        for bid, sp, want, have in report:
            self.assertGreater(want, 0, (bid, sp))
            self.assertLessEqual(abs(have - want), max(1, 0.02 * want), (bid, sp, want, have))

    def test_mixed_uses_the_catch_all_mix(self):
        dens = placement.species_densities(self.sk)
        self.assertAlmostEqual(sum(dens[3].values()), 8.0)
        self.assertAlmostEqual(dens[3]["oak"] / dens[3]["willow"], 56 / 14)

    def test_trees_stand_on_usable_ground(self):
        g = self.gd
        col = np.floor(self.rec["x"] / placement.CELL_M).astype(int)
        row = np.floor(self.rec["z"] / placement.CELL_M).astype(int)
        self.assertTrue(g["usable"][row, col].all(), "no tree on a way, lot, water or steep slope")
        self.assertTrue((g["factor"][row, col] > 0).all(), "none above the tree limit")
        self.assertTrue((g["biome"][row, col] == self.rec["biome"]).all())

    def test_spacing(self):
        x, z, m = self.rec["x"], self.rec["z"], self.rec["planted"]
        canopy = np.array([r["canopy_r_m"] for r in TABLE])[m]
        trunk = np.array([r["trunk_r_m"] for r in TABLE])[m]
        species = np.array([r["species"] for r in TABLE])[m]
        order = np.argsort(x)
        worst_same, worst_trunk = np.inf, np.inf
        reach = 1.2 * canopy.max()
        for a_i, a in enumerate(order):
            for b in order[a_i + 1 :]:
                if x[b] - x[a] > reach:
                    break
                d = np.hypot(x[a] - x[b], z[a] - z[b])
                worst_trunk = min(worst_trunk, d - trunk[a] - trunk[b])
                if species[a] == species[b]:
                    worst_same = min(worst_same, d - 1.2 * max(canopy[a], canopy[b]))
        self.assertGreaterEqual(worst_trunk, placement.TRUNK_GAP_M - 1e-9)
        self.assertGreaterEqual(worst_same, -1e-9)

    def test_size_mix_and_stunted_biomes(self):
        size = np.array([r["size"] for r in TABLE])[self.rec["planted"]]
        wet = self.rec["biome"] == 4
        self.assertTrue(wet.any())
        self.assertTrue((size[wet] == "young").all(), "stunted biome: young trees only")
        forest_oak = (self.rec["biome"] == 2) & (np.array([r["species"] for r in TABLE])[self.rec["planted"]] == "oak")
        n = int(forest_oak.sum())
        for s, share in self.sk["placement"]["size_mix"].items():
            self.assertLessEqual(abs(int((size[forest_oak] == s).sum()) - share * n), 1.0, s)

    def test_dead_wood_fractions_of_forest_trees(self):
        forest = self.rec["biome"] == 2
        n = int(forest.sum())
        snag = int((self.rec["model"][forest] == 11).sum())
        log = int((self.rec["model"][forest] == 12).sum())
        self.assertEqual(snag, round(0.03 * n))
        self.assertEqual(log, round(0.04 * n))
        self.assertFalse(np.isin(self.rec["model"][~forest], [11, 12]).any(), "only in forest biomes")

    def test_deterministic(self):
        again = placement.place_trees(self.ctx, TABLE, self.gd)
        for k in ("model", "x", "z", "yaw", "scale"):
            np.testing.assert_array_equal(again[k], self.rec[k], k)


if __name__ == "__main__":
    unittest.main()


class ChunkFileTest(unittest.TestCase):
    def test_records_round_trip_and_files_check(self):
        import os
        import tempfile

        rec = {
            "model": np.array([3, 0, 7], dtype=np.uint8),
            "x": np.array([5.25, 130.0, 255.998]),
            "z": np.array([1.0, 2.5, 127.9]),
            "yaw": np.array([0, 128, 255], dtype=np.uint8),
            "scale": np.array([10, 20, 30], dtype=np.uint8),
        }
        chunks = placement.chunk_records(rec)
        self.assertEqual(sorted(chunks), [(0, 0), (1, 0)])
        a = placement.decode_chunk(chunks[(0, 0)])
        self.assertEqual(a["m"].tolist(), [3])
        self.assertEqual(a["x"][0], int(5.25 * 512))
        b = placement.decode_chunk(chunks[(1, 0)])
        self.assertEqual(b["m"].tolist(), [0, 7])
        self.assertEqual(b["x"].tolist(), [int(2.0 * 512), 65535])  # clamped at the chunk's far edge
        self.assertEqual(b["yaw"].tolist(), [128, 255])
        with tempfile.TemporaryDirectory() as d:
            placement.write_tree_files(rec, d)
            self.assertEqual(placement.check_tree_files(d), [])
            with open(os.path.join(d, "trees", "1_0.bin"), "ab") as f:
                f.write(b"x")
            self.assertTrue(placement.check_tree_files(d), "a changed chunk is reported")
