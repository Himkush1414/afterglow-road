"""Stage 13 tests: normals and the biome map at texel centres."""
import math
import unittest

import numpy as np

from tools.worldgen import biome, derive
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import Context, run
from tools.worldgen.tests.sample import sketch


def ctx_with(height, sk):
    g = Grid.full(sk["size_m"], sk["sample_m"])
    ctx = Context(sk, g, sk["world_seed"])
    ctx.layers["height"] = height(*g.coords())
    return ctx


class NormalTest(unittest.TestCase):
    def test_size_and_flat_ground(self):
        sk = sketch()
        ctx = ctx_with(lambda x, z: np.full(x.shape, 10.0), sk)
        raw = derive.normal_bytes(ctx)
        self.assertEqual(len(raw), (2048 // 4) ** 2 * 2)
        self.assertEqual(set(raw), {128})  # n = (0, 1, 0) -> 127.5 rounds to 128

    def test_slopes(self):
        sk = sketch()
        ctx = ctx_with(lambda x, z: 0.5 * x - 0.25 * z, sk)
        nx, nz = derive.normals(ctx)
        k = 1.0 / math.sqrt(0.25 + 1.0 + 0.0625)
        np.testing.assert_allclose(nx, -0.5 * k)
        np.testing.assert_allclose(nz, 0.25 * k)
        raw = np.frombuffer(derive.normal_bytes(ctx), dtype=np.uint8).reshape(512, 512, 2)
        self.assertEqual(int(raw[0, 0, 0]), int(math.floor((-0.5 * k * 0.5 + 0.5) * 255 + 0.5)))

    def test_texel_centres(self):
        sk = sketch()
        ctx = ctx_with(lambda x, z: x, sk)
        idx, count = derive.texel_samples(ctx, 4.0)
        self.assertEqual((count, int(idx[0]), int(idx[-1])), (512, 1, 1023))
        idx, count = derive.texel_samples(ctx, 16.0)
        self.assertEqual((count, int(idx[0]), int(idx[1])), (128, 4, 12))

    def test_needs_the_full_map(self):
        sk = sketch()
        ctx = Context(sk, Grid.crop(500, 500, 64, 2), 1)
        with self.assertRaises(ValueError):
            derive.normal_bytes(ctx)


class BiomeFileTest(unittest.TestCase):
    def test_ids_at_texel_centres(self):
        sk = sketch()
        ctx = run(sk, Grid.full(sk["size_m"], 4), sk["world_seed"], until="coast")
        ids = derive.biome_ids(ctx)
        self.assertEqual(ids.shape, (128, 128))
        # the same rules on a 16 m grid of the same heights at the same points
        h = ctx.layers["height"][2::4, 2::4]
        want = biome.classify(sk, Grid(8.0, 8.0, 16.0, 128, 128), h, sk["world_seed"], True)
        np.testing.assert_array_equal(ids, want)
        raw = derive.biome_bytes(ctx)
        self.assertEqual(len(raw), 128 * 128)
        self.assertTrue(set(np.unique(ids)) <= {b["id"] for b in sk["biomes"]})


if __name__ == "__main__":
    unittest.main()


class MaskTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.ctx = run(sk, Grid.full(sk["size_m"], 2), sk["world_seed"])
        cls.m = derive.mask_rgba(cls.ctx)
        cls.g = Grid(2.0, 2.0, 4.0, 512, 512)

    def at(self, x, z):
        return self.m[int(z // 4), int(x // 4)]

    def test_shape_and_alpha(self):
        self.assertEqual(self.m.shape, (512, 512, 4))
        self.assertEqual(len(derive.mask_bytes(self.ctx)), 512 * 512 * 4)
        self.assertTrue(np.all(self.m[..., 3] == 0), "tree cover comes with placement")

    def test_way_surface_and_lot_cores(self):
        from tools.worldgen import geometry, lots

        lane = next(r for r in self.ctx.roads if r["id"] == "lane")
        x, z = self.g.coords()
        d = geometry.polyline_distance(self.g, lane["points"], 20.0)
        free = np.ones(x.shape, dtype=bool)
        for lot in self.ctx.lots:
            free &= lots.distance(x, z, lot) > 0.0
        self.assertTrue(np.all(self.m[..., 0][(d < lane["core_m"] - 0.01) & free] == 255))
        any_way = np.zeros(x.shape, dtype=bool)
        for rec in self.ctx.roads:
            any_way |= geometry.polyline_distance(self.g, rec["points"], rec["core_m"]) < rec["core_m"]
        self.assertTrue(np.all(self.m[..., 0][~any_way] == 0))
        self.assertTrue(np.all(self.m[..., 0][~free] == 0), "never inside a lot core")

    def test_wetness(self):
        lk = self.sk["lake"]
        self.assertEqual(int(self.at(lk["x"], lk["z"])[1]), 255, "in the lake")
        self.assertEqual(int(self.at(1400, 1000)[1]), 255, "on the brook")
        far = self.at(700, 900)
        self.assertEqual(int(far[1]), 0, "far from water, not wet biome")

    def test_rock_where_steep(self):
        nx, nz = derive.normals(self.ctx)
        slope = np.degrees(np.arccos(np.sqrt(np.maximum(1 - nx * nx - nz * nz, 0))))
        np.testing.assert_array_equal(self.m[..., 2] == 255, slope > 38.0)
        self.assertTrue((self.m[..., 2] == 255).any(), "the scarp is rock")


class MinMaxTest(unittest.TestCase):
    def test_matches_brute_force_including_far_edges(self):
        sk = sketch()
        g = Grid.full(sk["size_m"], sk["sample_m"])
        ctx = Context(sk, g, 1)
        rng = np.random.default_rng(3)
        enc = rng.integers(0, 65536, size=(g.nz, g.nx)).astype("<u2")
        levels = derive.minmax_levels(ctx, enc)
        self.assertEqual([m.shape[0] for m, _ in levels], [32, 16, 8, 4, 2, 1])
        for level, (mins, maxs) in enumerate(levels):
            n = 32 * 2**level
            for r in range(mins.shape[0]):
                for c in range(mins.shape[0]):
                    block = enc[r * n : r * n + n + 1, c * n : c * n + n + 1]
                    self.assertEqual((int(mins[r, c]), int(maxs[r, c])), (int(block.min()), int(block.max())), (level, r, c))

    def test_far_edge_counts(self):
        sk = sketch()
        g = Grid.full(sk["size_m"], sk["sample_m"])
        enc = np.full((g.nz, g.nx), 100, dtype="<u2")
        enc[32, 32] = 5  # corner shared by four level-0 nodes
        mins, _ = derive.minmax_levels(Context(sk, g, 1), enc)[0]
        self.assertEqual(int((mins == 5).sum()), 4)

    def test_byte_layout(self):
        sk = sketch()
        g = Grid.full(sk["size_m"], sk["sample_m"])
        enc = np.arange(g.nz * g.nx, dtype=np.int64).reshape(g.nz, g.nx) % 60000
        enc = enc.astype("<u2")
        raw = derive.minmax_bytes(Context(sk, g, 1), enc)
        self.assertEqual(len(raw), 4 * sum(4**k for k in range(6)))
        first = np.frombuffer(raw[:8], dtype="<u2")
        block = enc[0:33, 0:33]
        self.assertEqual(first[:2].tolist(), [int(block.min()), int(block.max())])


class MacroTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sk = sketch()
        cls.sk = sk
        cls.ctx = run(sk, Grid.full(sk["size_m"], 2), sk["world_seed"])
        cls.mask = derive.mask_rgba(cls.ctx)
        cls.rgb = derive.macro_rgb(cls.ctx, cls.mask)

    def test_rules(self):
        cfg = self.sk["derive"]["macro"]
        layers = cfg["layers"]
        rgb, m = self.rgb, self.mask
        self.assertEqual(rgb.shape, (512, 512, 3))
        way = m[..., 0] == 255
        np.testing.assert_array_equal(rgb[way], np.tile(layers["dirt"], (int(way.sum()), 1)))
        nx, nz = derive.normals(self.ctx)
        slope = np.degrees(np.arccos(np.sqrt(np.maximum(1 - nx * nx - nz * nz, 0))))
        rock = (slope > 38.0) & ~way & (m[..., 1] == 0)
        self.assertTrue(rock.any())
        np.testing.assert_array_equal(rgb[rock], np.tile(layers["rock"], (int(rock.sum()), 1)))
        ids = np.repeat(np.repeat(derive.biome_ids(self.ctx), 4, 0), 4, 1)
        names = biome.names(self.sk)
        plain = ~way & (m[..., 1] == 0) & (slope <= 30.0)
        for bid, name in names.items():
            sel = plain & (ids == bid)
            if sel.any():
                np.testing.assert_array_equal(rgb[sel], np.tile(layers[cfg["biome_layer"][name]], (int(sel.sum()), 1)), name)

    def test_layer_colours_from_a_manifest(self):
        import copy

        sk = copy.deepcopy(self.sk)
        names = list(sk["derive"]["macro"]["layers"])
        manifest = {"materials": [{"name": n, "mean_albedo": [i, 2 * i, 3 * i]} for i, n in enumerate(names)] + [{"name": "unused", "mean_albedo": [1, 1, 1]}]}
        layers = derive.apply_layer_colours(sk, manifest)
        self.assertEqual(layers, {n: [i, 2 * i, 3 * i] for i, n in enumerate(names)})
        self.assertFalse(sk["derive"]["macro"]["placeholder"])
        manifest["materials"] = manifest["materials"][1:]
        with self.assertRaises(ValueError):
            derive.apply_layer_colours(copy.deepcopy(self.sk), manifest)

    def test_png(self):
        import io

        from PIL import Image

        raw = derive.macro_png(self.ctx, self.mask)
        img = Image.open(io.BytesIO(raw))
        self.assertEqual((img.size, img.mode), ((512, 512), "RGB"))
        np.testing.assert_array_equal(np.asarray(img), self.rgb)
        self.assertEqual(raw, derive.macro_png(self.ctx, self.mask), "deterministic")
