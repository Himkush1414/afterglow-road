"""Acceptance checks on the final height field (05 §14). Limits and the
places they refer to come from the sketch's "checks" block."""
import math

import numpy as np

from . import roads, stages
from .pipeline import bilinear


def river_incision(ctx):
    """Per water line: the deepest point of the final field along its centre
    line below the uncarved terrain (stages 1-6), and where it is."""
    rows = []
    for wl in stages.water_lines(ctx.sketch):
        pts = wl["pts"]
        uncarved = stages.centre_profile(ctx.sketch, ctx.seed, ctx.noise, pts)
        depth = uncarved - bilinear(ctx.grid, ctx.layers["height"], pts[:, 0], pts[:, 1])
        k = int(np.argmax(depth))
        rows.append({"id": wl["line"]["id"], "depth": float(depth[k]), "at": (round(float(pts[k, 0])), round(float(pts[k, 1])))})
    return rows


def mouths(ctx, ids):
    """Final height at the last centre point of each named water line."""
    pts = {wl["line"]["id"]: wl["pts"][-1] for wl in stages.water_lines(ctx.sketch)}
    return [{"id": i, "y": float(bilinear(ctx.grid, ctx.layers["height"], pts[i][0], pts[i][1]))} for i in ids]


def highest(ctx):
    """(height, x, z) of the highest sample outside the boundary band of
    stage 5 (the scarp is an edge wall, not a place to stand)."""
    sk = ctx.sketch
    h = np.where(stages.scarp_band(ctx.x, ctx.z, sk["scarp"], sk["size_m"]), -np.inf, ctx.layers["height"])
    j, i = np.unravel_index(int(np.argmax(h)), h.shape)
    return float(h[j, i]), float(ctx.x[j, i]), float(ctx.z[j, i])


def max_encodable(sk):
    enc = sk["height_encoding"]
    return 65535 * float(enc["scale"]) - float(enc["offset_m"])


def report(ctx):
    """(lines, failures) of the final-field part of T-05-10: way grades,
    river incision, sea mouths, the highest point."""
    sk, ck = ctx.sketch, ctx.sketch["checks"]
    lines, bad = [], 0

    def row(text, ok):
        nonlocal bad
        bad += not ok
        lines.append(f"  {text}{'' if ok else '  FAIL'}")

    for r in roads.grade_report(ctx):
        row(f"grade {r['id']:<28} {r['type']:<6} limit {r['limit']:4.0%} worst {r['worst']:6.2%} at {r['at']}", r["ok"])
    for pid in ctx.route_failures:
        row(f"no track route under the limit to {pid}", False)
    limit = float(ck["river_incision_max_m"])
    for r in river_incision(ctx):
        row(f"incision {r['id']:<20} {r['depth']:6.2f} m at {r['at']} (limit {limit:g} m)", r["depth"] <= limit)
    sea = float(sk.get("sea_level_y", 0.0))
    for m in mouths(ctx, ck["sea_mouths"]):
        row(f"mouth {m['id']:<23} terrain {m['y']:7.2f} m (sea {sea:g} m)", m["y"] < sea)
    top, x, z = highest(ctx)
    peak = next(p for p in sk["pois"] if p["id"] == ck["peak_poi"])
    d = math.hypot(x - peak["x"], z - peak["z"])
    row(f"highest point {top:.2f} m at ({x:g},{z:g}), {d:.1f} m from the peak place (limit {ck['peak_within_m']:g} m)", d <= float(ck["peak_within_m"]))
    room = max_encodable(sk) - top
    row(f"headroom below the largest encodable height {room:.2f} m (limit {ck['peak_headroom_m']:g} m)", room >= float(ck["peak_headroom_m"]))
    return lines, bad
