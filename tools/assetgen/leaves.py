"""Painted leaf-card atlases from a preset (22 §1.1 foliage, §2):

  python -m tools.assetgen.leaves --preset <preset.json> --out <dir>

Each atlas is a grid x grid set of cells; each cell holds one clump: thin
twigs fanning up from the middle of the cell's bottom edge, and leaves
("leaf": ellipses) or needle bundles ("needle": fans of thin strokes) along
them. Leaves facing the top and the outside of the clump take the lighter
palette colours. Colour is reduced to the preset palette (6-10 colours),
smoothed with the Kuwahara filter and varied with broad brush noise, as in
paint.py. Nothing is drawn within `margin` of a cell edge, and colour is
bled into the transparent area so mipmaps keep no dark fringe.

Writes <out>/hi/<category>_<name>_ca.png (albedo sRGB + coverage alpha) and
<out>/hi/<category>_<name>_nra.png (normal x, normal y (OpenGL, Y+),
roughness, ambient occlusion), the same at half size under <out>/lo/, and
<out>/<category>_leaves.json listing the atlases with their grid and mean
opaque albedo. Output is deterministic for a given preset.
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image

from tools.assetgen import paint


def _stamp(canvas, depth, cx, cy, length, width, angle, value, z):
    """Draws an ellipse (centre cx, cy; full length and width in px; angle
    from +x) into canvas (H, W, 2: palette value, alpha) where it lies in
    front (z) of what is there; returns nothing."""
    r = max(length, width) * 0.5 + 1.5
    x0, x1 = max(0, int(cx - r)), min(canvas.shape[1], int(cx + r) + 2)
    y0, y1 = max(0, int(cy - r)), min(canvas.shape[0], int(cy + r) + 2)
    if x0 >= x1 or y0 >= y1:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    dx, dy = xs + 0.5 - cx, ys + 0.5 - cy
    c, s = math.cos(angle), math.sin(angle)
    u = (dx * c + dy * s) / (length * 0.5)
    v = (-dx * s + dy * c) / max(width * 0.5, 0.5)
    d = np.sqrt(u * u + v * v)
    # one pixel of soft edge, measured across the narrow axis
    cover = np.clip((1.0 - d) * max(width * 0.5, 0.5) + 0.5, 0.0, 1.0)
    shade = value + 0.08 * v  # a lighter and a darker half either side of the midrib
    region = canvas[y0:y1, x0:x1]
    zr = depth[y0:y1, x0:x1]
    take = (cover > 0.0) & (z >= zr)
    region[..., 0] = np.where(take, shade * cover + region[..., 0] * (1.0 - cover), region[..., 0])
    region[..., 1] = np.where(take, np.maximum(region[..., 1], cover), region[..., 1])
    zr[take & (cover > 0.5)] = z


def paint_cell(rng, n, a):
    """(palette value 0-1, alpha, leaf depth 0-1) for one n x n cell."""
    canvas = np.zeros((n, n, 2))
    depth = np.full((n, n), -1.0)
    margin = a["margin"] * n
    base = np.array([n * 0.5, n - margin])  # x, y (rows grow downward)
    top = margin
    span = base[1] - top
    twigs = []
    for k in range(a["twigs"]):
        spread = k / (a["twigs"] - 1) - 0.5 if a["twigs"] > 1 else 0.0
        ang = math.radians(-90.0 + a["fan_deg"] * spread + rng.uniform(-10.0, 10.0))
        length = span * rng.uniform(0.75, 1.0)
        tip = base + length * np.array([math.cos(ang), math.sin(ang)])
        tip[0] = np.clip(tip[0], margin + 2, n - margin - 2)
        tip[1] = max(tip[1], top + 2)
        twigs.append(tip)
        for t in np.linspace(0.0, 1.0, int(length / 2) + 2):  # dark twig line
            p = base + (tip - base) * t
            _stamp(canvas, depth, p[0], p[1], a["twig_px"] * (1.6 - t), a["twig_px"] * (1.6 - t), 0.0, 0.05, -0.5)
    lp, wp = a["leaf_px"]
    for _ in range(a["count"]):
        tip = twigs[rng.integers(len(twigs))]
        t = rng.uniform(0.25, 1.0) ** 0.7
        p = base + (tip - base) * t
        out = (tip - base) / (np.linalg.norm(tip - base) + 1e-6)
        side = np.array([-out[1], out[0]]) * rng.choice([-1.0, 1.0])
        p = p + side * rng.uniform(0.0, a["spread"] * n)
        size = rng.uniform(0.7, 1.15)
        reach = lp * size + 2.0  # whole leaf or bundle stays inside the margin
        p = np.clip(p, margin + reach, n - margin - reach)
        z = rng.random()
        # light from above and from outside the clump; leaves behind are darker
        height = 1.0 - (p[1] - top) / span
        value = np.clip(0.25 + 0.35 * height + 0.35 * z + rng.normal(0.0, 0.08), 0.0, 1.0)
        direction = math.atan2(out[1], out[0])
        if a["shape"] == "needle":
            fan = math.radians(a.get("bundle_fan_deg", 50))
            heading = math.atan2(out[1], out[0]) + rng.uniform(-0.6, 0.6)
            for j in range(a.get("bundle", 7)):
                ang = heading + fan * (j / max(1, a.get("bundle", 7) - 1) - 0.5)
                cx = p[0] + math.cos(ang) * lp * size * 0.5
                cy = p[1] + math.sin(ang) * lp * size * 0.5
                _stamp(canvas, depth, cx, cy, lp * size, wp, ang, value + rng.normal(0.0, 0.04), z)
        else:
            ang = direction + rng.uniform(-1.1, 1.1)
            cx = p[0] + math.cos(ang) * lp * size * 0.45
            cy = p[1] + math.sin(ang) * lp * size * 0.45
            _stamp(canvas, depth, cx, cy, lp * size, wp * size, ang, value, z)
    m = int(math.ceil(margin))
    canvas[:m], canvas[n - m :], canvas[:, :m], canvas[:, n - m :] = 0.0, 0.0, 0.0, 0.0
    return canvas[..., 0], canvas[..., 1], np.clip(depth, 0.0, 1.0)


def bleed(rgb, alpha, steps):
    """Fills transparent pixels with the colour of nearby opaque ones."""
    w = (alpha > 0.5).astype(np.float64)
    acc = rgb * w[..., None]
    out = rgb.copy()
    filled = w > 0
    for s in range(steps):
        sigma = 2.0 ** s
        num, den = paint.blur(acc, sigma), paint.blur(w, sigma)
        new = (~filled) & (den > 1e-4)
        out[new] = num[new] / den[new][:, None]
        filled |= new
    return out


def paint_atlas(a, size):
    """(colour_alpha RGBA uint8, normal_rough_ao RGBA uint8) for one atlas."""
    paint.check_material({"name": a["name"], "palette": a["palette"], "brush": a["brush"]})
    rng = np.random.default_rng(a["seed"])
    g = a["grid"]
    n = size // g
    value, alpha, depth = np.zeros((size, size)), np.zeros((size, size)), np.zeros((size, size))
    for cy in range(g):
        for cx in range(g):
            v, al, d = paint_cell(rng, n, a)
            sl = (slice(cy * n, (cy + 1) * n), slice(cx * n, (cx + 1) * n))
            value[sl], alpha[sl], depth[sl] = v, al, d
    palette = np.asarray(a["palette"], dtype=np.float64) / 255.0
    palette = palette[np.argsort(palette @ np.array([0.299, 0.587, 0.114]))]
    idx = np.minimum((np.clip(value, 0.0, 0.999) * len(palette)).astype(int), len(palette) - 1)
    rgb = paint.kuwahara(paint.srgb_to_linear(palette[idx]), a["kuwahara_radius"])
    for cells in a["brush"]["cells"]:
        rgb = rgb * (1.0 + a["brush"]["strength"] * (2.0 * paint.value_noise(rng, size, cells) - 1.0))[..., None]
    rgb = bleed(np.clip(rgb, 0.0, 1.0), alpha, 8)
    ca = np.dstack([paint.linear_to_srgb(rgb), alpha])
    # form-level relief only: each leaf a soft dome over the coverage
    h = paint.blur(alpha, 1.5 * size / 1024.0)
    nm = paint.normals(h, a["normal_strength"] * size / 1024.0)
    r0, r1 = a["roughness"]
    rough = r0 + (r1 - r0) * (1.0 - depth)
    ao = 1.0 - a["ao"] * (1.0 - depth) * (alpha > 0.5)
    nra = np.dstack([nm[..., 0] * 0.5 + 0.5, nm[..., 1] * 0.5 + 0.5, rough, ao])
    return paint._u8(ca), paint._u8(nra)


def mean_opaque_albedo(ca):
    m = ca[..., 3] >= 128
    lin = paint.srgb_to_linear(ca[..., :3][m].astype(np.float64) / 255.0).mean(axis=0)
    return [int(v) for v in np.floor(paint.linear_to_srgb(lin) * 255.0 + 0.5)]


def write(preset, out):
    category, size = preset["category"], preset["size"]
    manifest = {"category": category, "size": size, "atlases": []}
    for d in ("hi", "lo"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    for a in preset["atlases"]:
        ca, nra = paint_atlas(a, size)
        for name, img in (("ca", ca), ("nra", nra)):
            base = f"{category}_{a['name']}_{name}.png"
            Image.fromarray(img, "RGBA").save(os.path.join(out, "hi", base), optimize=False)
            Image.fromarray(paint.half(img), "RGBA").save(os.path.join(out, "lo", base), optimize=False)
        manifest["atlases"].append({"name": a["name"], "grid": a["grid"], "mean_albedo": mean_opaque_albedo(ca)})
    with open(os.path.join(out, f"{category}_leaves.json"), "w", encoding="ascii") as f:
        f.write(json.dumps(manifest, indent=1) + "\n")
    return manifest


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--preset", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    with open(args.preset, encoding="utf-8") as f:
        preset = json.load(f)
    for a in write(preset, args.out)["atlases"]:
        print(f"{a['name']}: mean albedo {a['mean_albedo']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
