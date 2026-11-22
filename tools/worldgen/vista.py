"""The vista check of T-05-8 (05 §14) on written world files. Looking from
the eye beside the start place toward the peak, the horizon (the terrain
sample of greatest elevation angle) must lie on the summit (within the
peak's noise-free radius), and the ray to that horizon point must clear
every placed tree. A rounded summit hides its own top point from below, so
the silhouette is what is seen (Q-86). A tree is a vertical cylinder of its
canopy radius from its ground to its top (both times its scale), which
covers the trunk."""
import json
import math
import os

import numpy as np

from . import files, placement
from .grid import Grid
from .pipeline import bilinear

## Tree scale byte -> factor (04 §2).
SCALE_BASE, SCALE_DIV = 0.75, 510.0


def load_height(world_dir, sk):
    """(grid, height) of height.bin."""
    with open(os.path.join(world_dir, "height.bin"), "rb") as f:
        u = np.frombuffer(files.decompress(f.read()), dtype="<u2")
    n = int(round(math.sqrt(u.size)))
    return Grid(0.0, 0.0, float(sk["sample_m"]), n, n), files.decode_height(u.reshape(n, n), sk)


def ends(sk, grid, h):
    """(eye, target) as (x, z, y): the eye stands eye_offset_m from the start
    place on eye_bearing_deg (compass), the target stands on the peak place;
    both eye_height_m above the ground."""
    ck = sk["checks"]
    pois = {p["id"]: p for p in sk["pois"]}
    s, p = pois[ck["start_poi"]], pois[ck["peak_poi"]]
    b = math.radians(float(ck["eye_bearing_deg"]))
    ex = s["x"] + float(ck["eye_offset_m"]) * math.sin(b)
    ez = s["z"] - float(ck["eye_offset_m"]) * math.cos(b)
    lift = float(ck["eye_height_m"])
    eye = (ex, ez, float(bilinear(grid, h, ex, ez)) + lift)
    target = (p["x"], p["z"], float(bilinear(grid, h, p["x"], p["z"])) + lift)
    return eye, target


def horizon(grid, h, eye, target, step_m=1.0):
    """(x, z, y) of the terrain sample of greatest elevation angle seen from
    the eye along the ray, sampled every step_m (the first metre skipped)."""
    (ex, ez, ey), (tx, tz, _) = eye, target
    length = math.hypot(tx - ex, tz - ez)
    t = np.linspace(0.0, 1.0, max(int(length / step_m), 1) + 1)[1:]
    x, z = ex + (tx - ex) * t, ez + (tz - ez) * t
    y = bilinear(grid, h, x, z)
    k = int(np.argmax((y - ey) / (t * length)))
    return float(x[k]), float(z[k]), float(y[k])


def chunks_along(eye, target, reach_m, chunk_m=placement.CHUNK_M):
    """Tree chunk keys (cx, cz) within reach_m of the ray in plan view."""
    (ex, ez, _), (tx, tz, _) = eye, target
    n = int(math.hypot(tx - ex, tz - ez) / (chunk_m / 4)) + 1
    out = set()
    for t in np.linspace(0.0, 1.0, n + 1):
        x, z = ex + (tx - ex) * t, ez + (tz - ez) * t
        for dx in (-reach_m, 0.0, reach_m):
            for dz in (-reach_m, 0.0, reach_m):
                out.add((int(math.floor((x + dx) / chunk_m)), int(math.floor((z + dz) / chunk_m))))
    return sorted(out)


def load_trees(world_dir, keys, chunk_m=placement.CHUNK_M):
    """Trees of the listed chunks: model, x, z (map metres), scale factor."""
    with open(os.path.join(world_dir, "trees", "index.json"), encoding="ascii") as f:
        listed = set(json.load(f)["files"])
    parts = []
    for cx, cz in keys:
        name = f"{cx}_{cz}.bin"
        if name not in listed:
            continue
        with open(os.path.join(world_dir, "trees", name), "rb") as f:
            r = placement.decode_chunk(files.decompress(f.read()))
        parts.append((r["m"].astype(int), cx * chunk_m + r["x"] / placement.POS_UNITS_PER_M, cz * chunk_m + r["z"] / placement.POS_UNITS_PER_M, SCALE_BASE + r["s"] / SCALE_DIV))
    if not parts:
        return {"model": np.zeros(0, int), "x": np.zeros(0), "z": np.zeros(0), "scale": np.zeros(0)}
    return {k: np.concatenate([p[i] for p in parts]) for i, k in enumerate(("model", "x", "z", "scale"))}


def tree_blockers(grid, h, eye, target, trees, table):
    """Trees whose cylinder the ray passes through: list of (model id, x, z,
    lowest ray height in the cylinder above the tree's ground, tree height)."""
    (ex, ez, ey), (tx, tz, ty) = eye, target
    dx, dz = tx - ex, tz - ez
    length = math.hypot(dx, dz)
    ux, uz = dx / length, dz / length
    radius = np.array([float(r["canopy_r_m"]) for r in table])[trees["model"]] * trees["scale"]
    height = np.array([float(r["height_m"]) for r in table])[trees["model"]] * trees["scale"]
    rx, rz = trees["x"] - ex, trees["z"] - ez
    along = rx * ux + rz * uz
    across = np.abs(-rx * uz + rz * ux)
    near = (across < radius) & (along > -radius) & (along < length + radius)
    half = np.sqrt(np.maximum(radius[near] ** 2 - across[near] ** 2, 0.0))
    a0 = np.clip(along[near] - half, 0.0, length)
    a1 = np.clip(along[near] + half, 0.0, length)
    low = ey + (ty - ey) * np.minimum(a0, a1) / length
    low = np.minimum(low, ey + (ty - ey) * np.maximum(a0, a1) / length)
    ground = bilinear(grid, h, trees["x"][near], trees["z"][near])
    above = low - ground
    hit = above < height[near]
    ids = [r["id"] for r in table]
    idx = np.flatnonzero(near)[hit]
    return [(ids[trees["model"][i]], float(trees["x"][i]), float(trees["z"][i]), float(a), float(height[i])) for i, a in zip(idx, above[hit])]


def report(world_dir, sk, table):
    """(lines, failures) of the data part of T-05-8."""
    ck = sk["checks"]
    grid, h = load_height(world_dir, sk)
    eye, target = ends(sk, grid, h)
    hx, hz, hy = horizon(grid, h, eye, target)
    summit = float(sk["corridor"]["poi_r_m"][ck["peak_poi"]])
    d = math.hypot(hx - target[0], hz - target[1])
    seen = (hx, hz, hy)
    reach = max(float(r["canopy_r_m"]) for r in table) * (SCALE_BASE + 255 / SCALE_DIV)
    trees = load_trees(world_dir, chunks_along(eye, seen, reach))
    hits = tree_blockers(grid, h, eye, seen, trees, table)
    angle = math.degrees(math.atan2(hy - eye[2], math.hypot(hx - eye[0], hz - eye[1])))
    lines = [
        f"  eye ({eye[0]:.1f},{eye[1]:.1f}) y {eye[2]:.2f} toward the peak ({target[0]:g},{target[1]:g}), {math.hypot(target[0] - eye[0], target[1] - eye[1]):.0f} m",
        f"  horizon at ({hx:.0f},{hz:.0f}) y {hy:.2f}, {angle:.2f} deg up, {d:.0f} m from the peak (summit radius {summit:g} m){'' if d <= summit else '  FAIL'}",
        f"  trees: {trees['x'].size} near the ray, {len(hits)} in the way{'  FAIL' if hits else ''}",
    ]
    for tid, tx, tz, above, tall in hits[:10]:
        lines.append(f"    {tid} at ({tx:.1f},{tz:.1f}): ray {above:.1f} m above its ground, tree {tall:.1f} m")
    return lines, int(d > summit) + int(bool(hits))
