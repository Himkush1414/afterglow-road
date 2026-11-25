"""Painted ground-cover atlas from a preset (22 §3 "Ground cover": one atlas
for all ground-cover meshes):

  python -m tools.assetgen.ground_cover --preset <preset.json> --out <dir>

The atlas is a grid x grid set of square cells, one per entry of `cells`
(row by row from the top left). Each cell is painted from one shape:

- "blades": tapered, slightly curved blades fanning up from the bottom
  middle (grass, reeds: `count`, `width_px`, `fan_deg`, `bend`);
- "frond": a curved midrib with paired leaflets shrinking toward the tip
  (fern: `pairs`, `leaflet_px`);
- "twigs": thin stems with many small dots along their upper part
  (heather: `count`, `dots`, `dot_px`); dots take the accent palette;
- "flower": a few short blades and stems, each stem topped with a ring of
  petals in the accent palette (`count`, `petals`, `petal_px`);
- "scatter": leaves lying in all directions over the whole cell, seen from
  above (litter: `count`, `leaf_px`);
- "patch": a soft-edged noise blob filled with small dots, seen from above
  (moss: `cells_noise`, `dots`, `dot_px`).

Colour is reduced to the cell's palette (6-10 colours; an optional
`accent` palette for dots and petals), smoothed with the Kuwahara filter
and varied with broad brush noise, as in leaves.py. Nothing is drawn
within `margin` of a cell edge, and colour is bled into the transparent
area so mipmaps keep no dark fringe.

Writes <out>/hi/<category>_ca.png (albedo sRGB + coverage alpha),
<out>/hi/<category>_nra.png (normal x, normal y (OpenGL, Y+), roughness,
ambient occlusion), the same at half size under <out>/lo/, and
<out>/<category>.json listing every cell's name, index, shape, mean opaque
albedo and opaque bounds (u0, v0, u1, v1 inside the cell, 0-1). Output is
deterministic for a given preset.
"""
import argparse
import json
import math
import os

import numpy as np
from PIL import Image

from tools.assetgen import leaves, paint

SHAPES = ("blades", "frond", "twigs", "flower", "scatter", "patch")
UPRIGHT = ("blades", "frond", "twigs", "flower")


class PresetError(ValueError):
    pass


def check_preset(preset):
    g = preset["grid"]
    if len(preset["cells"]) > g * g:
        raise PresetError(f"{len(preset['cells'])} cells do not fit a {g} x {g} grid")
    names = set()
    for c in preset["cells"]:
        if c["shape"] not in SHAPES:
            raise PresetError(f"{c['name']}: unknown shape '{c['shape']}'")
        if c["name"] in names:
            raise PresetError(f"{c['name']}: named twice")
        names.add(c["name"])
        paint.check_material({"name": c["name"], "palette": c["palette"], "brush": c["brush"]})
        if c["shape"] in ("twigs", "flower") and not c.get("accent"):
            raise PresetError(f"{c['name']}: shape '{c['shape']}' needs an accent palette")


class Canvas:
    """Palette value, alpha, accent flag and depth for one n x n cell."""

    def __init__(self, n):
        self.n = n
        self.va = np.zeros((n, n, 2))
        self.depth = np.full((n, n), -1.0)
        self.accent = np.zeros((n, n), dtype=bool)

    def stamp(self, x, y, length, width, angle, value, z, accent=False):
        """leaves._stamp; the pixels it takes (front-most, mostly covered)
        become accent pixels or stop being them."""
        r = int(max(length, width) * 0.5) + 3
        sl = (slice(max(0, int(y) - r), int(y) + r + 1), slice(max(0, int(x) - r), int(x) + r + 1))
        before = self.depth[sl].copy()
        leaves._stamp(self.va, self.depth, x, y, length, width, angle, value, z)
        took = self.depth[sl] != before
        if accent:
            self.accent[sl] |= took
        else:
            self.accent[sl] &= ~took

    def stroke(self, rng, base, tip, bend, w0, w1, value, z):
        """A tapered curved stroke from base to tip (bend: sideways bow as a
        share of the length)."""
        d = tip - base
        length = float(np.linalg.norm(d)) + 1e-6
        side = np.array([-d[1], d[0]]) / length
        steps = int(length / max(1.0, min(w0, w1) * 0.6)) + 2
        for t in np.linspace(0.0, 1.0, steps):
            p = base + d * t + side * bend * length * math.sin(math.pi * t)
            w = w0 + (w1 - w0) * t
            self.stamp(p[0], p[1], max(w * 1.6, 1.0), w, math.atan2(d[1], d[0]), value + 0.25 * t, z)


def _fan(rng, c, n, margin, i, count):
    """Base and tip of the i-th of `count` stems fanning up from the bottom."""
    base = np.array([n * 0.5 + rng.uniform(-0.06, 0.06) * n, n - margin])
    spread = i / (count - 1) - 0.5 if count > 1 else 0.0
    ang = math.radians(-90.0 + c.get("fan_deg", 60) * spread + rng.uniform(-8.0, 8.0))
    length = (n - 2 * margin) * rng.uniform(0.7, 1.0)
    tip = base + length * np.array([math.cos(ang), math.sin(ang)])
    tip = np.clip(tip, margin + 2, n - margin - 2)
    return base, tip


def paint_cell(rng, n, c):
    cv = Canvas(n)
    margin = c["margin"] * n
    shape = c["shape"]
    if shape in ("blades", "flower"):
        count = c["count"]
        for i in range(count):
            base, tip = _fan(rng, c, n, margin, i, count)
            if shape == "flower":
                tip = base + (tip - base) * rng.uniform(0.45, 0.7)
            w = c["width_px"] * rng.uniform(0.8, 1.2)
            cv.stroke(rng, base, tip, c.get("bend", 0.08) * rng.choice([-1.0, 1.0]), w, w * 0.15, 0.2, rng.random())
        if shape == "flower":
            for i in range(c["stems"]):
                base, tip = _fan(rng, c, n, margin, i, c["stems"])
                r = c["petal_px"]
                tip = np.clip(tip, margin + 2 * r, n - margin - 2 * r)
                cv.stroke(rng, base, tip, 0.03, 1.5, 1.0, 0.15, 0.5)
                for k in range(c["petals"]):
                    a = 2 * math.pi * k / c["petals"]
                    px, py = tip[0] + math.cos(a) * r * 0.5, tip[1] + math.sin(a) * r * 0.5
                    cv.stamp(px, py, r, r * 0.55, a, 0.5 + 0.3 * rng.random(), 0.9, True)
                cv.stamp(tip[0], tip[1], r * 0.45, r * 0.45, 0.0, 0.05, 1.0, True)
    elif shape == "frond":
        base = np.array([n * 0.5, n - margin])
        tip = np.array([n * 0.5 + rng.uniform(-0.1, 0.1) * n, margin + 2])
        cv.stroke(rng, base, tip, c.get("bend", 0.08), 2.5, 1.0, 0.1, 0.4)
        d = tip - base
        side = np.array([-d[1], d[0]]) / np.linalg.norm(d)
        for k in range(c["pairs"]):
            t = 0.12 + 0.85 * k / max(1, c["pairs"] - 1)
            p = base + d * t + side * c.get("bend", 0.08) * np.linalg.norm(d) * math.sin(math.pi * t)
            size = c["leaflet_px"] * (1.0 - 0.75 * t)
            for sgn in (-1.0, 1.0):
                a = math.atan2(d[1], d[0]) + sgn * math.radians(70.0)
                q = p + np.array([math.cos(a), math.sin(a)]) * size * 0.5
                q = np.clip(q, margin + size * 0.6, n - margin - size * 0.6)
                cv.stamp(q[0], q[1], size, size * 0.35, a, 0.35 + 0.4 * t, rng.random())
    elif shape == "twigs":
        for i in range(c["count"]):
            base, tip = _fan(rng, c, n, margin, i, c["count"])
            cv.stroke(rng, base, tip, 0.05 * rng.choice([-1.0, 1.0]), 2.0, 1.0, 0.1, 0.3)
            for _ in range(c["dots"]):
                t = rng.uniform(0.35, 1.0)
                p = base + (tip - base) * t + rng.normal(0.0, c["dot_px"], 2)
                p = np.clip(p, margin + c["dot_px"], n - margin - c["dot_px"])
                d = c["dot_px"]
                cv.stamp(p[0], p[1], d, d * 0.8, rng.uniform(0, math.pi), rng.uniform(0.3, 0.9), rng.random(), True)
    elif shape == "scatter":
        lp, wp = c["leaf_px"]
        for _ in range(c["count"]):
            size = rng.uniform(0.7, 1.2)
            reach = lp * size * 0.6 + 1
            x, y = rng.uniform(margin + reach, n - margin - reach, 2)
            cv.stamp(x, y, lp * size, wp * size, rng.uniform(0, math.pi), rng.uniform(0.1, 1.0), rng.random())
    else:  # patch
        blob = paint.normalise(paint.fbm(rng, n, c["cells_noise"], [1.0, 0.5]))
        yy, xx = (np.mgrid[0:n, 0:n] + 0.5) / n - 0.5
        inner = 0.5 - c["margin"] - 0.02
        fall = np.clip((inner - np.sqrt(xx * xx + yy * yy)) / 0.12, 0.0, 1.0)
        cover = np.clip((blob * fall - 0.25) * 6.0, 0.0, 1.0)
        cv.va[..., 1] = cover
        cv.va[..., 0] = 0.2 + 0.5 * blob
        cv.depth[:] = np.where(cover > 0.5, blob, -1.0)
        for _ in range(c["dots"]):
            x, y = rng.uniform(margin, n - margin, 2)
            if cover[int(y), int(x)] > 0.5:
                cv.stamp(x, y, c["dot_px"], c["dot_px"], 0.0, rng.uniform(0.5, 1.0), 1.0)
    m = int(math.ceil(margin))
    for a in (cv.va, cv.depth, cv.accent):
        a[:m], a[n - m :], a[:, :m], a[:, n - m :] = 0, 0, 0, 0
    return cv


def _colour(values, palette):
    pal = np.asarray(palette, dtype=np.float64) / 255.0
    pal = pal[np.argsort(pal @ np.array([0.299, 0.587, 0.114]))]
    idx = np.minimum((np.clip(values, 0.0, 0.999) * len(pal)).astype(int), len(pal) - 1)
    return paint.srgb_to_linear(pal[idx])


def bounds(alpha):
    """(u0, v0, u1, v1) of the pixels with alpha >= 0.5, 0-1 over the array."""
    ys, xs = np.nonzero(alpha >= 0.5)
    if len(xs) == 0:
        return [0.0, 0.0, 0.0, 0.0]
    h, w = alpha.shape
    return [round(float(v), 4) for v in (xs.min() / w, ys.min() / h, (xs.max() + 1) / w, (ys.max() + 1) / h)]


def paint_atlas(preset):
    """(colour_alpha RGBA uint8, normal_rough_ao RGBA uint8, cell list)."""
    check_preset(preset)
    size, g = preset["size"], preset["grid"]
    n = size // g
    rng = np.random.default_rng(preset["seed"])
    rgb = np.zeros((size, size, 3))
    alpha, depth = np.zeros((size, size)), np.zeros((size, size))
    rough = np.full((size, size), 1.0)
    cells = []
    for i, c in enumerate(preset["cells"]):
        cv = paint_cell(rng, n, c)
        col = _colour(cv.va[..., 0], c["palette"])
        if c.get("accent"):
            col = np.where(cv.accent[..., None], _colour(cv.va[..., 0], c["accent"]), col)
        col = paint.kuwahara(col, c["kuwahara_radius"])
        for k in c["brush"]["cells"]:
            col = col * (1.0 + c["brush"]["strength"] * (2.0 * paint.value_noise(rng, n, k) - 1.0))[..., None]
        sl = (slice((i // g) * n, (i // g + 1) * n), slice((i % g) * n, (i % g + 1) * n))
        rgb[sl], alpha[sl], depth[sl] = col, cv.va[..., 1], np.clip(cv.depth, 0.0, 1.0)
        r0, r1 = c["roughness"]
        rough[sl] = r0 + (r1 - r0) * (1.0 - depth[sl])
        cells.append(
            {"name": c["name"], "index": i, "shape": c["shape"], "upright": c["shape"] in UPRIGHT,
             "bounds": bounds(cv.va[..., 1])}
        )
    rgb = leaves.bleed(np.clip(rgb, 0.0, 1.0), alpha, 8)
    ca = paint._u8(np.dstack([paint.linear_to_srgb(rgb), alpha]))
    nm = paint.normals(paint.blur(alpha, 1.5 * size / 1024.0), preset["normal_strength"] * size / 1024.0)
    ao = 1.0 - preset["ao"] * (1.0 - depth) * (alpha > 0.5)
    nra = paint._u8(np.dstack([nm[..., 0] * 0.5 + 0.5, nm[..., 1] * 0.5 + 0.5, rough, ao]))
    for c in cells:
        i = c["index"]
        sl = (slice((i // g) * n, (i // g + 1) * n), slice((i % g) * n, (i % g + 1) * n))
        c["mean_albedo"] = leaves.mean_opaque_albedo(ca[sl])
    return ca, nra, cells


def write(preset, out):
    category = preset["category"]
    ca, nra, cells = paint_atlas(preset)
    for d in ("hi", "lo"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    for name, img in (("ca", ca), ("nra", nra)):
        base = f"{category}_{name}.png"
        Image.fromarray(img, "RGBA").save(os.path.join(out, "hi", base), optimize=False)
        Image.fromarray(paint.half(img), "RGBA").save(os.path.join(out, "lo", base), optimize=False)
    manifest = {"category": category, "size": preset["size"], "grid": preset["grid"], "cells": cells}
    with open(os.path.join(out, f"{category}.json"), "w", encoding="ascii") as f:
        f.write(json.dumps(manifest, indent=1) + "\n")
    return manifest


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--preset", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    with open(args.preset, encoding="utf-8") as f:
        preset = json.load(f)
    for c in write(preset, args.out)["cells"]:
        print(f"{c['name']}: cell {c['index']}, mean albedo {c['mean_albedo']}, bounds {c['bounds']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
