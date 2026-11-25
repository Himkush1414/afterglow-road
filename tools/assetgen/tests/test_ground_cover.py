"""Ground-cover atlas painter: determinism, every shape paints inside its
cell margin, accents, bounds, outputs and preset checks."""
import copy
import json
import os
import tempfile
import unittest

import numpy as np
from PIL import Image

from tools.assetgen import ground_cover

GREEN = [[30, 50, 20], [45, 65, 30], [60, 80, 40], [75, 95, 50], [90, 110, 60], [105, 125, 70]]
ACCENT = [[200, 60, 160], [230, 200, 60]]
COMMON = {"margin": 0.06, "kuwahara_radius": 1, "brush": {"cells": [2, 4], "strength": 0.05}, "roughness": [0.6, 0.9]}
PRESET = {
    "category": "sample_cover",
    "size": 192,
    "grid": 3,
    "seed": 9,
    "normal_strength": 2.0,
    "ao": 0.4,
    "cells": [
        dict(COMMON, name="a", shape="blades", palette=GREEN, count=9, width_px=3.0, fan_deg=70, bend=0.1),
        dict(COMMON, name="b", shape="frond", palette=GREEN, pairs=8, leaflet_px=14),
        dict(COMMON, name="c", shape="twigs", palette=GREEN, accent=ACCENT, count=4, dots=30, dot_px=2.5),
        dict(COMMON, name="d", shape="flower", palette=GREEN, accent=ACCENT, count=5, width_px=2.0, stems=2, petals=6, petal_px=6),
        dict(COMMON, name="e", shape="scatter", palette=GREEN, count=20, leaf_px=[10, 6]),
        dict(COMMON, name="f", shape="patch", palette=GREEN, cells_noise=[3, 6], dots=60, dot_px=2.0),
    ],
}


def cell(img, i, grid=3, size=192):
    n = size // grid
    return img[(i // grid) * n : (i // grid + 1) * n, (i % grid) * n : (i % grid + 1) * n]


class GroundCoverTest(unittest.TestCase):
    def test_deterministic(self):
        a1, n1, c1 = ground_cover.paint_atlas(PRESET)
        a2, n2, c2 = ground_cover.paint_atlas(copy.deepcopy(PRESET))
        self.assertTrue(np.array_equal(a1, a2) and np.array_equal(n1, n2))
        self.assertEqual(c1, c2)

    def test_every_shape_paints_inside_its_margin(self):
        ca, _, cells = ground_cover.paint_atlas(PRESET)
        n = 192 // 3
        m = int(np.ceil(0.06 * n))
        for c in cells:
            alpha = cell(ca, c["index"])[..., 3]
            self.assertGreater((alpha >= 128).mean(), 0.02, c["name"])
            border = np.ones_like(alpha, dtype=bool)
            border[m : n - m, m : n - m] = False
            self.assertEqual(int(alpha[border].max()), 0, c["name"])
            u0, v0, u1, v1 = c["bounds"]
            self.assertTrue(0.0 < u0 < u1 < 1.0 and 0.0 < v0 < v1 < 1.0, c["name"])
        self.assertEqual([c["upright"] for c in cells], [True, True, True, True, False, False])
        empty = cell(ca, 6)[..., 3]
        self.assertEqual(int(empty.max()), 0, "unused cells stay clear")

    def test_accent_colours_only_where_asked(self):
        ca, _, cells = ground_cover.paint_atlas(PRESET)

        def magenta(i):
            rgb = cell(ca, i)[..., :3].astype(int)
            opaque = cell(ca, i)[..., 3] >= 128
            return int(((rgb[..., 0] - rgb[..., 1] > 60) & opaque).sum())

        self.assertGreater(magenta(2) + magenta(3), 0, "accent dots and petals")
        self.assertEqual(magenta(0) + magenta(1) + magenta(4) + magenta(5), 0)

    def test_write_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            m = ground_cover.write(PRESET, d)
            for sub, size in (("hi", 192), ("lo", 96)):
                for kind in ("ca", "nra"):
                    with Image.open(os.path.join(d, sub, f"sample_cover_{kind}.png")) as img:
                        self.assertEqual((img.size, img.mode), ((size, size), "RGBA"))
            with open(os.path.join(d, "sample_cover.json"), encoding="ascii") as f:
                self.assertEqual(json.load(f), m)
            self.assertEqual([c["name"] for c in m["cells"]], list("abcdef"))

    def test_preset_errors(self):
        bad = copy.deepcopy(PRESET)
        bad["cells"][0]["shape"] = "spiral"
        with self.assertRaises(ground_cover.PresetError):
            ground_cover.check_preset(bad)
        bad = copy.deepcopy(PRESET)
        del bad["cells"][2]["accent"]
        with self.assertRaises(ground_cover.PresetError):
            ground_cover.check_preset(bad)
        bad = copy.deepcopy(PRESET)
        bad["grid"] = 2
        with self.assertRaises(ground_cover.PresetError):
            ground_cover.check_preset(bad)


if __name__ == "__main__":
    unittest.main()
