"""Stage 14b: resource nodes (14 §4.2). Each node type lists placement
rules in the sketch's "nodes" block, each rule placing `count` nodes:

  area      on open ground (no way, lot or water; any slope) of the given
            biomes, optionally inside bumps, within a slope range, east of
            x_min, on a south-facing flank, or in river beds
  cut_face  along the back wall of a cut (quarry, mine bench)
  road_cut  on the steepest open ground beside a stretch of a way
  banks     on open ground next to water (rivers, the lake), optionally
            also in given biomes
  bends     in river beds on the inside of bends, sharpest first (then the
            straightest water, alternating sides)
  area with `steepest`: the steepest qualifying texels instead of random
  along     beside a way every `every_m` metres (yaw fixed); `fill_to`
            on an area rule tops a node type up to a total
Nodes keep MIN_GAP_M apart. Yaw: veins and seams face away from their
wall (downhill); the rest is random unless the rule fixes it.
"""
import math

import numpy as np

from . import objects, placement

MIN_GAP_M = 6.0
MAX_DARTS = 200


class _Gap:
    def __init__(self):
        self.cells = {}

    def free(self, x, z):
        c = MIN_GAP_M
        for cz in range(int(z // c) - 1, int(z // c) + 2):
            for cx in range(int(x // c) - 1, int(x // c) + 2):
                for ox, oz in self.cells.get((cx, cz), ()):
                    if math.hypot(x - ox, z - oz) < MIN_GAP_M:
                        return False
        return True

    def add(self, x, z):
        self.cells.setdefault((int(x // MIN_GAP_M), int(z // MIN_GAP_M)), []).append((x, z))


def _downhill_yaw(gd, x, z, cell_m):
    nx, nz = gd["normal"]
    row, col = int(z // cell_m), int(x // cell_m)
    return int(round(math.degrees(math.atan2(nx[row, col], -nz[row, col])))) % 360


def _bumps_mask(sk, gd, ids):
    out = np.zeros(gd["biome"].shape, dtype=bool)
    for b in sk["bumps"]:
        if b["id"] in ids:
            r = float(b.get("r_m") or b.get("r"))
            out |= np.hypot(gd["x"] - b["x"], gd["z"] - b["z"]) < r
    return out


def area_weight(ctx, gd, rule, beds, cell_m, lake=None):
    sk = ctx.sketch
    w = gd["open"] & np.isin(gd["biome"], [b for b, n in gd["names"].items() if n in rule.get("biomes", [])])
    if "bumps" in rule:
        w &= _bumps_mask(sk, gd, rule["bumps"])
    if "slope_min" in rule:
        w &= gd["slope"] >= float(rule["slope_min"])
    if "slope_max" in rule:
        w &= gd["slope"] < float(rule["slope_max"])
    if "x_min" in rule:
        w &= gd["x"] >= float(rule["x_min"])
    if rule.get("facing") == "south":  # downhill towards +z (map south)
        w &= gd["normal"][1] > 0.25
    if rule.get("river_beds"):
        w |= beds
    if rule.get("lake_banks") and lake is not None:
        w |= banks(gd, np.zeros_like(beds), lake, [], cell_m)
    return w


def banks(gd, beds, lake, biomes, cell_m):
    """Open texels touching water (4-neighbours)."""
    water = beds | lake
    near = water.copy()
    near[1:, :] |= water[:-1, :]
    near[:-1, :] |= water[1:, :]
    near[:, 1:] |= water[:, :-1]
    near[:, :-1] |= water[:, 1:]
    w = near & gd["open"]
    if biomes:
        w |= gd["open"] & np.isin(gd["biome"], [b for b, n in gd["names"].items() if n in biomes]) & near
    return w


def _lake_mask(sk, gd):
    from . import geometry

    lk = sk["lake"]
    return geometry.ellipse_rho(gd["x"], gd["z"], lk["x"], lk["z"], lk["a"], lk["b"]) < 1.0


def _darts(rng, gap, weight, n, cell_m):
    """Up to n points on texels with weight > 0, MIN_GAP_M apart."""
    pts = []
    sel = np.flatnonzero(weight.ravel())
    if sel.size == 0:
        return pts
    for _ in range(n * MAX_DARTS):
        c = int(sel[rng.integers(sel.size)])
        row, col = divmod(c, weight.shape[1])
        x, z = (col + rng.random()) * cell_m, (row + rng.random()) * cell_m
        if gap.free(x, z):
            gap.add(x, z)
            pts.append((x, z))
            if len(pts) == n:
                break
    return pts


def _cut_face(rng, gap, ctx, rule, n):
    cut = next(c for c in ctx.cuts if c["type"] == rule["cut"])
    dx, dz = cut["downhill"]
    if "back" in cut:
        bx, bz = cut["back"]
    else:
        bx, bz = cut["x"] - dx * cut["deep_m"] / 2, cut["z"] - dz * cut["deep_m"] / 2
    ux, uz = -dz, dx  # along the wall
    half = cut["long_m"] / 2 - MIN_GAP_M / 2
    out = []
    for i in range(n):
        t = -half + (2 * half) * (i + 0.5) / n
        x, z = bx + ux * t + dx * 1.0, bz + uz * t + dz * 1.0  # 1 m out from the wall
        gap.add(x, z)
        out.append((x, z, int(round(math.degrees(math.atan2(dx, -dz)))) % 360))
    return out


def _road(ctx, line_id):
    return next(r for r in ctx.roads if r["id"] == line_id)


def _road_cut(rng, gap, ctx, gd, rule, n, cell_m):
    from . import geometry

    road = _road(ctx, rule["line"])
    pts = np.asarray(road["points"], dtype=np.float64)
    a, b = np.asarray(rule["from"], float), np.asarray(rule["to"], float)
    ia = int(np.argmin(np.hypot(*(pts - a).T)))
    ib = int(np.argmin(np.hypot(*(pts - b).T)))
    stretch = pts[min(ia, ib) : max(ia, ib) + 1]
    d = geometry.polyline_distance(gd["grid"], stretch, road["core_m"] + 12.0)
    band = gd["open"] & (d > road["core_m"]) & (d < road["core_m"] + 12.0)
    order = np.argsort(-np.where(band, gd["slope"], -1.0).ravel())
    out = []
    for c in order:
        if len(out) == n or not band.ravel()[c]:
            break
        row, col = divmod(int(c), band.shape[1])
        x, z = (col + 0.5) * cell_m, (row + 0.5) * cell_m
        if gap.free(x, z):
            gap.add(x, z)
            out.append((x, z, _downhill_yaw(gd, x, z, cell_m)))
    return out


def _steepest(gap, gd, weight, n, cell_m):
    """The n steepest qualifying texels (centres), MIN_GAP_M apart, facing
    downhill."""
    order = np.argsort(-np.where(weight, gd["slope"], -1.0).ravel(), kind="stable")
    out = []
    for c in order:
        if len(out) == n or not weight.ravel()[c]:
            break
        row, col = divmod(int(c), weight.shape[1])
        x, z = (col + 0.5) * cell_m, (row + 0.5) * cell_m
        if gap.free(x, z):
            gap.add(x, z)
            out.append((x, z, _downhill_yaw(gd, x, z, cell_m)))
    return out


def _bends(rng, gap, ctx, rule, n):
    from . import roads

    cand = []
    for w in roads.water_data(ctx.sketch, ctx.seed, ctx.noise):
        if w["line"].get("kind") != rule.get("river_kind", "river"):
            continue
        p = np.asarray(w["pts"], dtype=np.float64)
        for i in range(1, len(p) - 1):
            u, v = p[i] - p[i - 1], p[i + 1] - p[i]
            turn = math.atan2(u[0] * v[1] - u[1] * v[0], u @ v)
            # inside of the bend; on straight water alternate sides
            side = math.copysign(1.0, turn) if abs(turn) > 1e-9 else (1.0 if i % 2 else -1.0)
            nrm = np.array([-u[1], u[0]]) / max(np.hypot(*u), 1e-9) * side
            q = p[i] + nrm * w["width"][i] * 0.3  # inside of the bend, in the bed
            cand.append((abs(turn), float(q[0]), float(q[1])))
    cand.sort(reverse=True)
    out = []
    for _, x, z in cand:
        if len(out) == n:
            break
        if gap.free(x, z):
            gap.add(x, z)
            out.append((x, z, int(rng.integers(0, 360))))
    return out


def _along(rng, gap, ctx, rule):
    road = _road(ctx, rule["line"])
    pts = np.asarray(road["points"], dtype=np.float64)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    total = float(seg.sum())
    lo, hi = rule["every_m"]
    s = float(rng.uniform(lo, hi))
    out = []
    side = 1.0
    while s < total:
        k = int(np.searchsorted(np.cumsum(seg), s))
        t = (s - (np.cumsum(seg)[k] - seg[k])) / seg[k]
        p = pts[k] + (pts[k + 1] - pts[k]) * t
        d = (pts[k + 1] - pts[k]) / seg[k]
        q = p + np.array([-d[1], d[0]]) * side * (road["core_m"] + float(rule.get("side_m", 2.0)))
        if gap.free(q[0], q[1]):
            gap.add(q[0], q[1])
            out.append((float(q[0]), float(q[1]), int(rule.get("yaw_deg", 0)) % 360))
        side = -side
        s += float(rng.uniform(lo, hi))
    return out


def place_nodes(ctx, gd, cell_m=placement.CELL_M):
    """Node objects (kind "node", type id, x, z, yaw) and the plan
    {(type id, rule index): (expected, placed)}."""
    sk = ctx.sketch
    rng = np.random.default_rng([int(ctx.seed), 142])
    gap = _Gap()
    beds = objects.river_beds(ctx, gd, cell_m)
    lake = _lake_mask(sk, gd)
    objs, plan, by_rule = [], {}, {}
    placed = {}
    # rules with fixed places first, so area rules keep their gap to them
    priority = {"cut_face": 0, "along": 1, "road_cut": 2, "bends": 3, "banks": 4, "area": 5}
    order = sorted(
        ((priority[rule["kind"]], i, k, spec["id"], rule) for i, spec in enumerate(sk.get("nodes", [])) for k, rule in enumerate(spec["rules"])),
        key=lambda t: t[:3],
    )
    for _, _, k, tid, rule in order:
        placed_here = placed.get(tid, 0)
        n = int(rule.get("count", 0))
        kind = rule["kind"]
        if kind == "area":
            if "fill_to" in rule:
                n = max(int(rule["fill_to"]) - placed_here, 0)
            w = area_weight(ctx, gd, rule, beds, cell_m, lake)
            if rule.get("steepest"):
                pts = _steepest(gap, gd, w, n, cell_m)
                by_rule[(tid, k)] = pts
                plan[(tid, k)] = (n, len(pts))
                placed[tid] = placed_here + len(pts)
                continue
            pts = [(x, z, _downhill_yaw(gd, x, z, cell_m) if rule.get("face_out") else int(rng.integers(0, 360))) for x, z in _darts(rng, gap, w, n, cell_m)]
        elif kind == "cut_face":
            pts = _cut_face(rng, gap, ctx, rule, n)
        elif kind == "road_cut":
            pts = _road_cut(rng, gap, ctx, gd, rule, n, cell_m)
        elif kind == "banks":
            w = banks(gd, beds, lake if rule.get("lake", True) else np.zeros_like(lake), rule.get("biomes", []), cell_m)
            if rule.get("biomes_only"):
                w &= np.isin(gd["biome"], [b for b, nm in gd["names"].items() if nm in rule["biomes_only"]])
            pts = [(x, z, int(rng.integers(0, 360))) for x, z in _darts(rng, gap, w, n, cell_m)]
        elif kind == "bends":
            pts = _bends(rng, gap, ctx, rule, n)
        elif kind == "along":
            pts = _along(rng, gap, ctx, rule)
            n = len(pts)
        else:
            raise ValueError(f"nodes: unknown rule kind {kind}")
        by_rule[(tid, k)] = pts
        plan[(tid, k)] = (n, len(pts))
        placed[tid] = placed_here + len(pts)
    # objects in sketch order: by node type, then by rule
    for spec in sk.get("nodes", []):
        for k in range(len(spec["rules"])):
            objs.extend(("node", spec["id"], x, z, yaw) for x, z, yaw in by_rule[(spec["id"], k)])
    return objs, plan
