"""Painted texture generator: determinism, tiling, the lo set, normals,
palette limits and the Kuwahara filter."""
import copy
import hashlib
import json
import os
import tempfile
import unittest

import numpy as np

from tools.assetgen import paint

MATERIAL = {
    "name": "sample",
    "seed": 3,
    "palette": [[40, 50, 30], [60, 70, 40], [80, 90, 50], [100, 110, 60], [120, 120, 70], [140, 130, 90]],
    "pattern": {"cells": [4, 16], "weights": [1.0, 0.4], "detail_cells": [8, 32], "detail_weights": [1.0, 0.5], "detail_mix": 0.3},
    "kuwahara_radius": 2,
    "brush": {"cells": [2, 4], "strength": 0.08},
    "height": {"blur_px": 8, "normal_strength": 4.0},
    "roughness": [0.8, 0.95],
    "ao": 0.5,
}
PRESET = {"category": "sample", "size": 64, "materials": [MATERIAL]}


class PaintTest(unittest.TestCase):
    def test_output_is_deterministic(self):
        hashes = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as d:
                paint.write(PRESET, d)
                h = hashlib.sha256()
                for sub in ("hi", "lo"):
                    for name in sorted(os.listdir(os.path.join(d, sub))):
                        with open(os.path.join(d, sub, name), "rb") as f:
                            h.update(f.read())
                hashes.append(h.hexdigest())
        self.assertEqual(hashes[0], hashes[1])

    def test_files_sizes_and_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = paint.write(PRESET, d)
            from PIL import Image

            for sub, size in (("hi", 64), ("lo", 32)):
                for kind in ("ah", "nra"):
                    with Image.open(os.path.join(d, sub, f"sample_sample_{kind}.png")) as img:
                        self.assertEqual((img.mode, img.size), ("RGBA", (size, size)), f"{sub} {kind}")
            with open(os.path.join(d, "sample.json"), encoding="ascii") as f:
                self.assertEqual(json.load(f), manifest)
            self.assertEqual([m["name"] for m in manifest["materials"]], ["sample"])
            self.assertEqual(len(manifest["materials"][0]["mean_albedo"]), 3)

    def test_stretched_noise_runs_down_the_image_and_tiles(self):
        n = paint.value_noise(np.random.default_rng(1), 128, [32, 4])
        across = np.abs(np.diff(n, axis=1)).mean()
        down = np.abs(np.diff(n, axis=0)).mean()
        self.assertGreater(across, 4.0 * down)
        self.assertLessEqual(np.abs(n[:, 0] - n[:, -1]).max(), np.abs(np.diff(n, axis=1)).max())
        self.assertLessEqual(np.abs(n[0] - n[-1]).max(), np.abs(np.diff(n, axis=0)).max())
        square = paint.value_noise(np.random.default_rng(1), 64, 8)
        self.assertTrue(np.array_equal(square, paint.value_noise(np.random.default_rng(1), 64, [8, 8])))

    def test_textures_tile(self):
        # the jump across the tile edge is no larger than jumps inside it
        ah, nra = paint.paint(MATERIAL, 64)
        for img in (ah, nra):
            a = img.astype(float)
            inner = np.abs(np.diff(a, axis=1)).max()
            seam = np.abs(a[:, 0] - a[:, -1]).max()
            self.assertLessEqual(seam, inner)
            inner_v = np.abs(np.diff(a, axis=0)).max()
            self.assertLessEqual(np.abs(a[0] - a[-1]).max(), inner_v)

    def test_lo_is_the_box_half(self):
        img = np.arange(16, dtype=np.uint8).reshape(4, 4, 1).repeat(4, axis=2)
        lo = paint.half(img)
        self.assertEqual(lo.shape, (2, 2, 4))
        self.assertEqual(int(lo[0, 0, 0]), 3)  # mean of 0, 1, 4, 5 = 2.5, rounded half up

    def test_normals_follow_opengl_convention(self):
        x = np.tile(np.linspace(0.0, 1.0, 32), (32, 1))  # rises to the right
        n = paint.normals(x, 4.0)
        self.assertTrue((n[2:-2, 2:-2, 0] < 0).all(), "a slope rising to the right faces left")
        y_up = x.T[::-1].copy()  # rises towards row 0 (up the image)
        n = paint.normals(y_up, 4.0)
        self.assertTrue((n[2:-2, 2:-2, 1] < 0).all(), "a slope rising up the image faces down")
        self.assertTrue(np.allclose(np.linalg.norm(n, axis=-1), 1.0))

    def test_palette_and_brush_limits(self):
        for count in (5, 11):
            bad = copy.deepcopy(MATERIAL)
            bad["palette"] = [[i * 10, i * 10, i * 10] for i in range(count)]
            with self.assertRaises(ValueError):
                paint.paint(bad, 32)
        bad = copy.deepcopy(MATERIAL)
        bad["brush"]["cells"] = [2]
        with self.assertRaises(ValueError):
            paint.paint(bad, 32)

    def test_kuwahara_keeps_edges_and_flattens_noise(self):
        rng = np.random.default_rng(1)
        img = np.zeros((32, 32, 3))
        img[:, 16:] = 1.0
        noisy = np.clip(img + rng.normal(0, 0.05, img.shape), 0, 1)
        out = paint.kuwahara(noisy, 3)
        self.assertLess(out[:, 4:12].std(), noisy[:, 4:12].std() * 0.5, "flat area smoothed")
        self.assertLess(out[:, 13:15].mean(), 0.2, "dark side of the edge stays dark")
        self.assertGreater(out[:, 17:19].mean(), 0.8, "light side stays light")


if __name__ == "__main__":
    unittest.main()
