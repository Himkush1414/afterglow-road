"""Neutral skin texture generator."""
import unittest

import numpy as np

from tools.assetgen import skin

SPEC = {"size": 64, "seed": 3, "base": "#c0b0a0", "variation": 0.05, "pores": 0.02, "roughness": 0.6}


class SkinTest(unittest.TestCase):
    def test_deterministic_sizes_and_mean(self):
        a1, n1 = skin.make(SPEC)
        a2, n2 = skin.make(SPEC)
        self.assertTrue(np.array_equal(a1, a2) and np.array_equal(n1, n2))
        self.assertEqual(a1.shape, (64, 64, 3))
        self.assertEqual(n1.shape, (64, 64, 4))
        mean = a1.reshape(-1, 3).mean(axis=0)
        np.testing.assert_allclose(mean, [0xC0, 0xB0, 0xA0], atol=6)

    def test_variation_and_channels(self):
        a, n = skin.make(SPEC)
        self.assertGreater(int(a[..., 0].max()) - int(a[..., 0].min()), 5)
        self.assertTrue((n[..., 3] == 255).all())
        self.assertTrue((n[..., 2] == round(0.6 * 255)).all())
        self.assertGreater(int(n[..., 2].min()), 0)

    def test_tiles(self):
        a, _ = skin.make(dict(SPEC, pores=0.0))
        edge = np.abs(a[0].astype(int) - a[-1].astype(int)).max()
        inner = np.abs(a[10].astype(int) - a[11].astype(int)).max()
        self.assertLessEqual(edge, inner + 2)

    def test_bad_colour(self):
        with self.assertRaises(ValueError):
            skin.hex_rgb("#abc")
