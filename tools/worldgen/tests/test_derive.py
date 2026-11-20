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
