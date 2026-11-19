"""Framework tests: deterministic noise, crop alignment, stage order, hashes."""
import unittest

import numpy as np

from tools.worldgen import noise
from tools.worldgen.grid import Grid
from tools.worldgen.pipeline import layer_bytes, run, sha256


def _ramp(ctx):
    ctx.layers["height"] += 0.01 * ctx.x + 0.02 * ctx.z


def _hills(ctx):
    ctx.layers["height"] += 30.0 * noise.fbm(ctx.x, ctx.z, 900.0, ctx.seed)


def _never(ctx):
    raise AssertionError("ran past the until stage")


STAGES = [("ramp", _ramp), ("hills", _hills), ("never", _never)]


class NoiseTest(unittest.TestCase):
    def test_range_and_seed(self):
        x, z = Grid.full(4096, 16).coords()
        a = noise.fbm(x, z, 900.0, 7)
        self.assertTrue(np.all(a >= -1.0) and np.all(a <= 1.0))
        self.assertGreater(a.std(), 0.05)
        self.assertTrue(np.array_equal(a, noise.fbm(x, z, 900.0, 7)), "same seed, same values")
        self.assertFalse(np.allclose(a, noise.fbm(x, z, 900.0, 8)), "seed changes values")
        r = noise.ridged(x, z, 400.0, 7)
        self.assertTrue(np.all(r >= 0.0) and np.all(r <= 1.0))

    def test_continuity(self):
        t = np.arange(0.0, 2000.0, 0.5)
        v = noise.value1(t, 700.0, 3)
        self.assertLess(np.abs(np.diff(v)).max(), 0.01, "no jumps between nearby samples")

    def test_golden_values(self):
        # Pinned so a change to the hash or interpolation is noticed.
        v = noise.value2(np.array([0.0, 123.4, 4096.0]), np.array([0.0, 567.8, 8191.0]), 900.0, 42)
        np.testing.assert_allclose(v, GOLDEN, rtol=0, atol=1e-12)


class PipelineTest(unittest.TestCase):
    def test_same_input_gives_identical_bytes(self):
        g = Grid.full(1024, 8)
        a = run({}, g, 5, STAGES, until="hills").layers["height"]
        b = run({}, g, 5, STAGES, until="hills").layers["height"]
        self.assertEqual(sha256(layer_bytes(a, "f8")), sha256(layer_bytes(b, "f8")))

    def test_a_crop_equals_the_window_of_the_full_map(self):
        full = Grid.full(2048, 2)
        crop = Grid.crop(1000, 700, 512, 2)
        self.assertEqual((crop.nx, crop.nz), (257, 257))
        h_full = run({}, full, 9, STAGES, until="hills").layers["height"]
        h_crop = run({}, crop, 9, STAGES, until="hills").layers["height"]
        r, c = crop.offset_in(full)
        np.testing.assert_array_equal(h_crop, h_full[r : r + 257, c : c + 257])

    def test_stages_run_in_order_and_stop_at_until(self):
        order = []
        stages = [(n, lambda ctx, n=n: order.append(n)) for n in ("a", "b", "c")]
        run({}, Grid.full(64, 32), 1, stages, until="b")
        self.assertEqual(order, ["a", "b"])

    def test_full_grid_shape_and_orientation(self):
        g = Grid.full(8192, 2)
        self.assertEqual((g.nx, g.nz), (4097, 4097))
        x, z = Grid.full(64, 32).coords()
        self.assertEqual((x[0, 2], z[2, 0]), (64.0, 64.0), "row = z (north first), column = x")


GOLDEN = [0.7620220160489022, 0.31555777545383806, 0.1521797008765947]

if __name__ == "__main__":
    unittest.main()
