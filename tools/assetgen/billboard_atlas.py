"""Billboard atlas files from the raw bake of tools/assetgen/billboards.py:

  python -m tools.assetgen.billboard_atlas --raw <dir> --grid <n> --category <c> --out <dir>

Reads <raw>/colour.png and <raw>/normal.png (both RGBA, alpha = coverage),
bleeds colour and normal into the transparent pixels of each cell (never
across cells), and writes <out>/hi/<category>_billboards_ca.png (albedo sRGB
+ coverage) and <out>/hi/<category>_billboards_n.png (normal x, y, z encoded
n * 0.5 + 0.5, + coverage), and the same at half size under <out>/lo/.
"""
import argparse
import os

import numpy as np
from PIL import Image

from tools.assetgen import leaves, paint

BLEED_STEPS = 7


def bleed_cells(img, grid):
    """RGBA uint8 -> RGBA uint8 with RGB bled into alpha-0 pixels per cell."""
    out = img.copy()
    n = img.shape[0] // grid
    for row in range(grid):
        for col in range(grid):
            sl = (slice(row * n, (row + 1) * n), slice(col * n, (col + 1) * n))
            alpha = img[sl][..., 3].astype(np.float64) / 255.0
            if not (alpha > 0.5).any():
                continue
            rgb = img[sl][..., :3].astype(np.float64) / 255.0
            out[sl][..., :3] = paint._u8(leaves.bleed(rgb, alpha, BLEED_STEPS))[..., :3]
    return out


def write(raw, grid, category, out):
    names = {"colour": "ca", "normal": "n"}
    for d in ("hi", "lo"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    for src, kind in names.items():
        with Image.open(os.path.join(raw, f"{src}.png")) as im:
            img = np.asarray(im.convert("RGBA"))
        if img.shape[0] != img.shape[1] or img.shape[0] % grid:
            raise ValueError(f"{src}.png: {img.shape[1]} x {img.shape[0]} does not split into {grid} x {grid} cells")
        done = bleed_cells(img, grid)
        base = f"{category}_billboards_{kind}.png"
        Image.fromarray(done, "RGBA").save(os.path.join(out, "hi", base), optimize=False)
        Image.fromarray(paint.half(done), "RGBA").save(os.path.join(out, "lo", base), optimize=False)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--raw", required=True)
    ap.add_argument("--grid", type=int, required=True)
    ap.add_argument("--category", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    write(a.raw, a.grid, a.category, a.out)
    print(f"billboard atlas: wrote {a.category}_billboards_ca/_n (hi, lo)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
