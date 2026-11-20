"""Stage 10: building lots and the extra level areas, flattened to their
mean height and blended back to the ground."""
import math

import numpy as np

from . import layout, roads, stages  # noqa: F401  (roads registers its stage before this one)
from .pipeline import exact_patch, stage


def all_lots(sk, generated=()):
    """Lots in flatten order: the sketch's lot list and the generated lots
    (building footprints with the lot margin and blend), then the extra lots
    (no margin, own blend)."""
    cfg = sk.get("lots", {})
    pois = {p["id"]: p for p in sk.get("pois", [])}
    out = []
    for lot in list(cfg.get("list", [])) + list(generated):
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


def mean_height(ctx, lot):
    """Mean of the pre-lot terrain over the lot's core samples (exact, also
    when the run's grid cuts the lot)."""
    x0, z0, x1, z1 = _core_box(lot)
    grid, h = exact_patch(ctx, x0, z0, x1, z1, "roads")
    s = grid.sample_m
    i0 = max(int(math.floor((x0 - grid.x0) / s)), 0)
    j0 = max(int(math.floor((z0 - grid.z0) / s)), 0)
    i1 = min(int(math.ceil((x1 - grid.x0) / s)) + 1, grid.nx)
    j1 = min(int(math.ceil((z1 - grid.z0) / s)) + 1, grid.nz)
    x, z = np.meshgrid(grid.x0 + np.arange(i0, i1) * s, grid.z0 + np.arange(j0, j1) * s)
    core = distance(x, z, lot) == 0.0
    return float(h[j0:j1, i0:i1][core].mean())


@stage("lots")
def _stage_lots(ctx):
    plan = getattr(ctx, "settlement", None) or {"lots": [], "handled": set()}
    generated, ctx.lot_pending = layout.generate(ctx.sketch, ctx.roads, plan["handled"])
    generated = generated + plan["lots"]
    lots = all_lots(ctx.sketch, generated)
    ctx.lot_way_overlaps = layout.way_overlaps(lots, ctx.roads)
    means = [mean_height(ctx, lot) for lot in lots]
    h = ctx.layers["height"]
    dist = [distance(ctx.x, ctx.z, lot) for lot in lots]
    for lot, m, d in zip(lots, means, dist):
        w = stages.smoothstep(0.0, lot["blend_m"], d)
        h = m * (1.0 - w) + h * w
        ctx.lots.append(dict(lot, y=m))
    for m, d in zip(means, dist):  # a neighbour's blend must not tilt a core
        h = np.where(d == 0.0, m, h)
    ctx.layers["height"] = h
