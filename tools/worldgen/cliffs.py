"""Stage 14 cliff faces (05 §5.1): where the slope exceeds min_slope_deg
over at least min_extent_m, rock-face meshes (face_m wide along the
contour and high up the slope) are placed facing downhill and tilted to
the slope until every such texel lies under one; iron veins and coal
seams not already on a face get a face of their own (they hang on it).

Steep ground is judged on the 4 m texels of placement.ground(); a steep
patch counts when its connected texels (4-neighbours) span at least
min_extent_m. A face covers the texels whose centres fall inside its
footprint on the map: face width along the contour by face height x
cos(slope) across it.
"""
import math

import numpy as np

from . import placement


def steep_texels(gd, cfg, cell_m=placement.CELL_M):
    """Texels steeper than the limit in patches spanning min_extent_m."""
    steep = gd["slope"] > float(cfg["min_slope_deg"])
    labels, count = _label(steep)
    if count == 0:
        return steep
    rows, cols = np.nonzero(steep)
    lab = labels[rows, cols]
    span = np.zeros(count + 1)
    for axis in (rows, cols):
        lo = np.full(count + 1, np.inf)
        hi = np.full(count + 1, -np.inf)
        np.minimum.at(lo, lab, axis)
        np.maximum.at(hi, lab, axis)
        span = np.maximum(span, (hi - lo + 1) * cell_m)
    keep = span >= float(cfg["min_extent_m"])
    return steep & keep[labels]


def _label(mask):
    """Connected components (4-neighbours) by union-find over the texels."""
    idx = -np.ones(mask.shape, dtype=np.int64)
    rows, cols = np.nonzero(mask)
    idx[rows, cols] = np.arange(rows.size)
    parent = np.arange(rows.size)

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for dr, dc in ((0, 1), (1, 0)):
        a = idx[: mask.shape[0] - dr, : mask.shape[1] - dc]
        b = idx[dr:, dc:]
        both = (a >= 0) & (b >= 0)
        for x, y in zip(a[both], b[both]):
            rx, ry = find(int(x)), find(int(y))
            if rx != ry:
                parent[max(rx, ry)] = min(rx, ry)
    roots = np.array([find(i) for i in range(rows.size)], dtype=np.int64)
    uniq, lab = np.unique(roots, return_inverse=True)
    labels = np.zeros(mask.shape, dtype=np.int64)
    labels[rows, cols] = lab + 1
    return labels, uniq.size


def _frame(gd, row, col):
    """(downhill unit vector in the map plane, slope in degrees) at a texel."""
    nx, nz = gd["normal"][0][row, col], gd["normal"][1][row, col]
    h = math.hypot(nx, nz)
    d = (nx / h, nz / h) if h > 1e-9 else (0.0, 1.0)
    return d, float(gd["slope"][row, col])


def _footprint(gd, x, z, d, slope, cfg, cell_m):
    """Texel indices whose centres lie inside a face's map footprint."""
    w, hgt = cfg["face_m"]
    half_w, half_d = w / 2.0, hgt * math.cos(math.radians(slope)) / 2.0
    reach = math.hypot(half_w, half_d)
    r0 = max(int((z - reach) // cell_m), 0)
    r1 = min(int((z + reach) // cell_m) + 1, gd["slope"].shape[0])
    c0 = max(int((x - reach) // cell_m), 0)
    c1 = min(int((x + reach) // cell_m) + 1, gd["slope"].shape[1])
    cx = (np.arange(c0, c1) + 0.5) * cell_m - x
    cz = (np.arange(r0, r1) + 0.5) * cell_m - z
    gx, gz = np.meshgrid(cx, cz)
    across = gx * d[0] + gz * d[1]  # downhill
    along = -gx * d[1] + gz * d[0]  # contour
    inside = (np.abs(along) <= half_w) & (np.abs(across) <= half_d)
    rr, cc = np.nonzero(inside)
    return rr + r0, cc + c0


def place_faces(ctx, gd, node_objs=(), cell_m=placement.CELL_M):
    """Faces as (variant type id, x, z, yaw degrees, pitch degrees) and the
    steep mask they cover. Yaw: the face's outward normal points downhill
    (0 = map -z, clockwise); pitch = the slope it leans back at."""
    cfg = ctx.sketch["cliffs"]
    rng = np.random.default_rng([int(ctx.seed), 143])
    variants = cfg["variants"]
    steep = steep_texels(gd, cfg, cell_m)
    covered = np.zeros_like(steep)
    faces = []
    order = np.argsort(-np.where(steep, gd["slope"], -1.0).ravel(), kind="stable")
    for c in order:
        row, col = divmod(int(c), steep.shape[1])
        if not steep[row, col]:
            break
        if covered[row, col]:
            continue
        x, z = (col + 0.5) * cell_m, (row + 0.5) * cell_m
        d, slope = _frame(gd, row, col)
        rr, cc = _footprint(gd, x, z, d, slope, cfg, cell_m)
        covered[rr, cc] = True
        covered[row, col] = True
        faces.append(_face(rng, variants, x, z, d, slope, "steep"))
    carriers = set(cfg.get("carry", []))
    for _, tid, x, z, _ in node_objs:
        if tid not in carriers:
            continue
        row, col = int(z // cell_m), int(x // cell_m)
        if covered[row, col]:
            continue
        d, slope = _frame(gd, row, col)
        faces.append(_face(rng, variants, x, z, d, slope, "carrier"))
        rr, cc = _footprint(gd, x, z, d, slope, cfg, cell_m)
        covered[rr, cc] = True
    return faces, steep, covered


def _face(rng, variants, x, z, d, slope, why):
    yaw = int(round(math.degrees(math.atan2(d[0], -d[1])))) % 360
    return (variants[int(rng.integers(len(variants)))], float(x), float(z), yaw, int(round(slope)), why)


def uncovered(steep, covered):
    """Number of steep texels without a face."""
    return int((steep & ~covered).sum())
