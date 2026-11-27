"""The neutral skin texture of the player bodies (22 §4), from the "skin"
group of the character preset:

  python -m tools.assetgen.skin --preset <character preset.json> --out <dir>

  "skin": {"size": px, "seed": int, "base": "#rrggbb", "variation": v,
           "pores": p, "roughness": r}

The albedo is the light, neutral base colour with soft blotches (fbm,
+-variation in value) and fine pore noise; the game multiplies it by the
chosen skin tone. The normal map carries only the pores. Every step wraps
around the edges.

Writes <out>/skin_albedo.png (sRGB) and <out>/skin_nra.png (normal x,
normal y (OpenGL, Y+), roughness, ambient occlusion 1). Deterministic for a
preset.
"""
import argparse
import json
import os

import numpy as np
from PIL import Image

from tools.assetgen.paint import fbm, normals

BLOTCH_CELLS = (4, 8, 16)
BLOTCH_WEIGHTS = (0.5, 0.3, 0.2)
PORE_CELLS = (128, 256)
PORE_WEIGHTS = (0.6, 0.4)
PORE_NORMAL_STRENGTH = 2.0


def hex_rgb(text):
    """'#rrggbb' -> floats 0..1."""
    text = text.lstrip("#")
    if len(text) != 6:
        raise ValueError(f"not a #rrggbb colour: {text}")
    return np.array([int(text[i : i + 2], 16) / 255.0 for i in (0, 2, 4)])


def make(spec):
    """(albedo uint8 HxWx3, nra uint8 HxWx4) for a skin spec."""
    size = int(spec["size"])
    rng = np.random.default_rng(int(spec["seed"]))
    blotch = fbm(rng, size, BLOTCH_CELLS, BLOTCH_WEIGHTS) - 0.5
    pores = fbm(rng, size, PORE_CELLS, PORE_WEIGHTS) - 0.5
    shade = 1.0 + 2.0 * float(spec["variation"]) * blotch + 2.0 * float(spec["pores"]) * pores
    albedo = np.clip(hex_rgb(spec["base"])[None, None, :] * shade[..., None], 0.0, 1.0)
    n = normals(pores + 0.5, PORE_NORMAL_STRENGTH)
    nra = np.empty((size, size, 4))
    nra[..., 0] = n[..., 0] * 0.5 + 0.5
    nra[..., 1] = n[..., 1] * 0.5 + 0.5
    nra[..., 2] = float(spec["roughness"])
    nra[..., 3] = 1.0
    to8 = lambda a: np.round(a * 255.0).astype(np.uint8)  # noqa: E731
    return to8(albedo), to8(nra)


def main(argv=None):
    ap = argparse.ArgumentParser(description="neutral skin texture")
    ap.add_argument("--preset", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    with open(a.preset, encoding="utf-8") as f:
        spec = json.load(f)["skin"]
    albedo, nra = make(spec)
    os.makedirs(a.out, exist_ok=True)
    Image.fromarray(albedo, "RGB").save(os.path.join(a.out, "skin_albedo.png"))
    Image.fromarray(nra, "RGBA").save(os.path.join(a.out, "skin_nra.png"))
    mean = albedo.reshape(-1, 3).mean(axis=0)
    print("RESULT skin %dpx, mean albedo %s" % (albedo.shape[0], [round(float(c)) for c in mean]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
