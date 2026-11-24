"""Billboard atlas finishing: per-cell bleed, hi and lo files."""
import os
import tempfile
import unittest

import numpy as np
from PIL import Image

from tools.assetgen import billboard_atlas


def _raw(d, size=32, grid=2):
    img = np.zeros((size, size, 4), np.uint8)
    img[4:8, 4:8] = (200, 40, 40, 255)  # a red tree in cell 0
    img[4:8, 20:24] = (40, 40, 200, 255)  # a blue tree in cell 1; cells 2 and 3 empty
    for name in ("colour", "normal"):
        Image.fromarray(img, "RGBA").save(os.path.join(d, f"{name}.png"))
    return img


class BillboardAtlasTest(unittest.TestCase):
    def test_bleeds_within_cells_and_writes_hi_lo(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory() as out:
            src = _raw(raw)
            billboard_atlas.write(raw, 2, "tree", out)
            with Image.open(os.path.join(out, "hi", "tree_billboards_ca.png")) as im:
                hi = np.asarray(im)
            with Image.open(os.path.join(out, "lo", "tree_billboards_n.png")) as im:
                self.assertEqual(im.size, (16, 16))
            self.assertTrue(np.array_equal(hi[..., 3], src[..., 3]))  # coverage unchanged
            self.assertTrue(np.array_equal(hi[4:8, 4:8], src[4:8, 4:8]))  # covered pixels unchanged
            cell0, cell1 = hi[:16, :16], hi[:16, 16:]
            self.assertTrue((cell0[..., 0] > cell0[..., 2]).all())  # cell 0 bled red only
            self.assertTrue((cell1[..., 2] > cell1[..., 0]).all())  # cell 1 bled blue only
            self.assertEqual(int(hi[16:, :, :3].max()), 0)  # empty cells stay empty

    def test_rejects_a_size_that_does_not_split(self):
        with tempfile.TemporaryDirectory() as raw, tempfile.TemporaryDirectory() as out:
            _raw(raw, size=30)
            with self.assertRaises(ValueError):
                billboard_atlas.write(raw, 4, "tree", out)


if __name__ == "__main__":
    unittest.main()
