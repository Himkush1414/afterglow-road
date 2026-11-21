"""Painted, tileable material textures from a preset (22 §2):

  python -m tools.assetgen.paint --preset <preset.json> --out <dir>

Per material: periodic procedural noise -> height field; colour by reducing
a blend of height and detail noise to the preset palette (6-10 colours);
edge-preserving Kuwahara smoothing removes grain; broad brush variation at
2-3 scales; the normal map comes from a blurred height so only form-level
relief remains. Every step wraps around the edges, so textures tile.

Writes <out>/hi/<category>_<name>_ah.png (albedo sRGB + height in alpha) and
<out>/hi/<category>_<name>_nra.png (normal x, normal y (OpenGL, Y+),
roughness, ambient occlusion), the same at half size under <out>/lo/, and
<out>/<category>.json listing the materials in preset order with their mean
albedo. Output is deterministic for a given preset.
"""
import argparse
import json
import os

import numpy as np
from PIL import Image

PALETTE_MIN, PALETTE_MAX = 6, 10


def value_noise(rng, size, cells):
    """Periodic value noise in [0, 1]: a cells x cells random lattice, smooth
    (smoothstep) interpolation, wrapping at the tile edge."""
    lattice = rng.random((cells, cells))
    t = np.arange(size) * cells / size
    i0 = np.floor(t).astype(int)
    f = t - i0
    f = f * f * (3.0 - 2.0 * f)
    i1 = (i0 + 1) % cells
    rows0, rows1 = lattice[i0], lattice[i1]  # (size, cells)
    a = rows0[:, i0] * (1 - f) + rows0[:, i1] * f
    b = rows1[:, i0] * (1 - f) + rows1[:, i1] * f
    return a * (1 - f)[:, None] + b * f[:, None]


def fbm(rng, size, cells, weights):
    """Weighted sum of value-noise octaves, normalised to [0, 1]."""
    out = sum(w * value_noise(rng, size, c) for c, w in zip(cells, weights))
    return normalise(out)


def normalise(a):
    lo, hi = float(a.min()), float(a.max())
    return (a - lo) / (hi - lo) if hi > lo else np.zeros_like(a)


def blur(a, sigma):
    """Periodic Gaussian blur (in the frequency domain)."""
    if sigma <= 0:
        return a.copy()
    n = a.shape[0]
    k = np.fft.fftfreq(n)
    g = np.exp(-2.0 * (np.pi * sigma) ** 2 * (k[:, None] ** 2 + k[None, :] ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a, axes=(0, 1)) * (g[..., None] if a.ndim == 3 else g), axes=(0, 1)))


def _box_sum(a, k):
    """Sum over the k x k window whose top-left corner is each pixel (wrapping)."""
    p = np.pad(a, [(0, k), (0, k)] + [(0, 0)] * (a.ndim - 2), mode="wrap")
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, [(1, 0), (1, 0)] + [(0, 0)] * (a.ndim - 2))
    n = a.shape[0]
    return c[k : k + n, k : k + n] - c[:n, k : k + n] - c[k : k + n, :n] + c[:n, :n]


def kuwahara(rgb, radius):
    """Kuwahara filter: each pixel takes the mean colour of whichever of its
    four (radius + 1)^2 quadrants has the lowest luminance variance."""
    if radius <= 0:
        return rgb.copy()
    k = radius + 1
    lum = rgb @ np.array([0.299, 0.587, 0.114])
    s_rgb, s_l, s_l2 = _box_sum(rgb, k), _box_sum(lum, k), _box_sum(lum * lum, k)
    best_var = np.full(lum.shape, np.inf)
    out = np.zeros_like(rgb)
    for dy, dx in ((radius, radius), (radius, 0), (0, radius), (0, 0)):
        m_l = np.roll(s_l, (dy, dx), axis=(0, 1)) / (k * k)
        var = np.roll(s_l2, (dy, dx), axis=(0, 1)) / (k * k) - m_l * m_l
        take = var < best_var
        best_var = np.where(take, var, best_var)
        out[take] = (np.roll(s_rgb, (dy, dx), axis=(0, 1)) / (k * k))[take]
    return out


def normals(height, strength):
    """OpenGL (Y+) normal map from a height field in [0, 1]: x to the right,
    y up the image (towards row 0)."""
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * strength
    dy_up = (np.roll(height, 1, 0) - np.roll(height, -1, 0)) * 0.5 * strength
    n = np.stack([-dx, -dy_up, np.ones_like(height)], axis=-1)
    return n / np.linalg.norm(n, axis=-1, keepdims=True)


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(np.clip(c, 0, None), 1 / 2.4) - 0.055)


def check_material(m):
    n = len(m["palette"])
    if not PALETTE_MIN <= n <= PALETTE_MAX:
        raise ValueError(f"{m['name']}: palette has {n} colours, needs {PALETTE_MIN}-{PALETTE_MAX}")
    if not 2 <= len(m["brush"]["cells"]) <= 3:
        raise ValueError(f"{m['name']}: brush variation needs 2-3 scales")


def paint(m, size):
    """(albedo_height RGBA uint8, normal_rough_ao RGBA uint8) for one material."""
    check_material(m)
    rng = np.random.default_rng(m["seed"])
    pat = m["pattern"]
    height = fbm(rng, size, pat["cells"], pat["weights"])
    detail = fbm(rng, size, pat["detail_cells"], pat["detail_weights"])
    # palette reduction: dark to light by the blend of height and detail
    palette = np.asarray(m["palette"], dtype=np.float64) / 255.0
    palette = palette[np.argsort(palette @ np.array([0.299, 0.587, 0.114]))]
    mix = normalise((1.0 - pat["detail_mix"]) * height + pat["detail_mix"] * detail)
    idx = np.minimum((mix * len(palette)).astype(int), len(palette) - 1)
    rgb = srgb_to_linear(palette[idx])
    rgb = kuwahara(rgb, m["kuwahara_radius"])
    brush = m["brush"]
    for cells in brush["cells"]:
        rgb = rgb * (1.0 + brush["strength"] * (2.0 * value_noise(rng, size, cells) - 1.0))[..., None]
    albedo = linear_to_srgb(np.clip(rgb, 0.0, 1.0))
    h = normalise(blur(height, m["height"]["blur_px"] * size / 1024.0))
    n = normals(h, m["height"]["normal_strength"] * size / 1024.0)
    r0, r1 = m["roughness"]
    rough = r0 + (r1 - r0) * detail
    cavity = np.clip((blur(h, 8.0 * size / 1024.0) - h) * 4.0, 0.0, 1.0)
    ao = 1.0 - m["ao"] * cavity
    ah = np.dstack([albedo, h])
    nra = np.dstack([n[..., 0] * 0.5 + 0.5, n[..., 1] * 0.5 + 0.5, rough, ao])
    return _u8(ah), _u8(nra)


def _u8(a):
    return np.floor(np.clip(a, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def half(img):
    """The lo set: half size in each dimension (box filter)."""
    a = img.astype(np.float64)
    a = (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2]) * 0.25
    return np.floor(a + 0.5).astype(np.uint8)


def mean_albedo(ah):
    """Mean albedo as sRGB bytes, averaged in linear light."""
    lin = srgb_to_linear(ah[..., :3].astype(np.float64) / 255.0).mean(axis=(0, 1))
    return [int(v) for v in np.floor(linear_to_srgb(lin) * 255.0 + 0.5)]


def write(preset, out):
    category, size = preset["category"], preset["size"]
    manifest = {"category": category, "size": size, "materials": []}
    for d in ("hi", "lo"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    for m in preset["materials"]:
        ah, nra = paint(m, size)
        for name, img in (("ah", ah), ("nra", nra)):
            base = f"{category}_{m['name']}_{name}.png"
            Image.fromarray(img, "RGBA").save(os.path.join(out, "hi", base), optimize=False)
            Image.fromarray(half(img), "RGBA").save(os.path.join(out, "lo", base), optimize=False)
        manifest["materials"].append({"name": m["name"], "mean_albedo": mean_albedo(ah)})
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
    for m in write(preset, args.out)["materials"]:
        print(f"{m['name']}: mean albedo {m['mean_albedo']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
