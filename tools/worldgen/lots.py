"""Stage 10: building lots and the extra level areas, flattened to their
mean height and blended back to the ground."""
import math

import numpy as np

from . import roads, stages  # noqa: F401  (roads registers its stage before this one)
from .grid import Grid
from .pipeline import run, stage


def all_lots(sk):
    """Lots in flatten order: the sketch's lot list (building footprints with
    the lot margin and blend), then the extra lots (no margin, own blend)."""
    cfg = sk.get("lots", {})
    pois = {p["id"]: p for p in sk.get("pois", [])}
    out = []
    for lot in cfg.get("list", []):
        out.append(dict({"margin_m": cfg["margin_m"], "blend_m": cfg["blend_m"], "yaw_deg": 0.0}, **lot))
    for lot in cfg.get("extra", []):
        lot = dict({"margin_m": 0.0, "yaw_deg": 0.0}, **lot)
        if "poi" in lot:
            lot.setdefault("x", pois[lot["poi"]]["x"])
            lot.setdefault("z", pois[lot["poi"]]["z"])
        out.append(lot)
    return out


def distance(x, z, lot):
    """Distance to the lot's flat core (0 inside): a disc of radius r, or the
    footprint w x d grown by the margin and turned by yaw_deg (clockwise)."""
    dx, dz = x - lot["x"], z - lot["z"]
    if "r" in lot:
        return np.maximum(np.hypot(dx, dz) - lot["r"] - lot["margin_m"], 0.0)
    a = math.radians(lot["yaw_deg"])
    u = dx * math.cos(a) + dz * math.sin(a)
    v = -dx * math.sin(a) + dz * math.cos(a)
    du = np.maximum(np.abs(u) - lot["w"] / 2.0 - lot["margin_m"], 0.0)
    dv = np.maximum(np.abs(v) - lot["d"] / 2.0 - lot["margin_m"], 0.0)
    return np.hypot(du, dv)


def _core_box(lot):
    if "r" in lot:
        e = lot["r"] + lot["margin_m"]
    else:
        e = math.hypot(lot["w"] / 2.0 + lot["margin_m"], lot["d"] / 2.0 + lot["margin_m"])
    return lot["x"] - e, lot["z"] - e, lot["x"] + e, lot["z"] + e


def mean_height(ctx, lot, before):
    """Mean of the pre-lot terrain over the lot's core samples. Taken from the
    run's own grid when the core plus the erosion reach lies inside it, else
    from a map-aligned sub-run around the lot (same samples, same mean)."""
    g, sk = ctx.grid, ctx.sketch
    s = g.sample_m
    reach = sk.get("erosion", {}).get("iterations", 0) * s
    x0, z0, x1, z1 = _core_box(lot)
    gx1, gz1 = g.x0 + (g.nx - 1) * s, g.z0 + (g.nz - 1) * s
    if x0 - reach >= g.x0 and z0 - reach >= g.z0 and x1 + reach <= gx1 and z1 + reach <= gz1:
        grid, h = g, before
    else:
        sx0 = math.floor((x0 - reach) / s) * s
        sz0 = math.floor((z0 - reach) / s) * s
        nx = int(math.ceil((x1 + reach - sx0) / s)) + 1
        nz = int(math.ceil((z1 + reach - sz0) / s)) + 1
        grid = Grid(sx0, sz0, s, nx, nz)
        h = run(sk, grid, ctx.seed, until="roads", noise=ctx.noise).layers["height"]
    i0 = max(int(math.floor((x0 - grid.x0) / s)), 0)
    j0 = max(int(math.floor((z0 - grid.z0) / s)), 0)
    i1 = min(int(math.ceil((x1 - grid.x0) / s)) + 1, grid.nx)
    j1 = min(int(math.ceil((z1 - grid.z0) / s)) + 1, grid.nz)
    xs = grid.x0 + np.arange(i0, i1) * s
    zs = grid.z0 + np.arange(j0, j1) * s
    x, z = np.meshgrid(xs, zs)
    core = distance(x, z, lot) == 0.0
    return float(h[j0:j1, i0:i1][core].mean())


@stage("lots")
def _stage_lots(ctx):
    before = ctx.layers["height"].copy()
    lots = all_lots(ctx.sketch)
    means = [mean_height(ctx, lot, before) for lot in lots]
    h = ctx.layers["height"]
    for lot, m in zip(lots, means):
        w = stages.smoothstep(0.0, lot["blend_m"], distance(ctx.x, ctx.z, lot))
        h = m * (1.0 - w) + h * w
        ctx.lots.append(dict(lot, y=m))
    ctx.layers["height"] = h
