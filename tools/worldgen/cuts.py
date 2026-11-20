"""Stages 11-12: benches and trenches cut into slopes."""
import math

import numpy as np

from . import lots, stages  # noqa: F401  (lots registers its stage before these)
from .pipeline import bilinear, exact_patch, stage

GRADIENT_STEP_M = 10.0  # inside the noise-free core around a place


def downhill(sk, seed, with_noise, x, z):
    """Unit downhill direction of the stage 1-6 terrain at a point."""
    e = GRADIENT_STEP_M
    pts = np.array([[x + e, z], [x - e, z], [x, z + e], [x, z - e]])
    h = stages.centre_profile(sk, seed, with_noise, pts)
    gx, gz = (h[0] - h[1]) / (2 * e), (h[2] - h[3]) / (2 * e)
    n = math.hypot(gx, gz)
    return (-gx / n, -gz / n) if n > 0 else (0.0, 1.0)


def box_coords(x, z, cx, cz, ax, az):
    """Coordinates along (ax, az) and across it, relative to (cx, cz)."""
    dx, dz = x - cx, z - cz
    return dx * ax + dz * az, -dx * az + dz * ax


def rect_distance(along, across, half_along, half_across):
    return np.hypot(np.maximum(np.abs(along) - half_along, 0.0), np.maximum(np.abs(across) - half_across, 0.0))


@stage("mine")
def _stage_mine(ctx):
    """Bench along the contour at the place, floor = its lowest corner, cut
    only; then a straight trench uphill from the middle of its back edge."""
    sk, cfg = ctx.sketch, ctx.sketch.get("mine")
    poi = next((p for p in sk.get("pois", []) if cfg and p["id"] == cfg["poi"]), None)
    if poi is None:
        return
    dx, dz = downhill(sk, ctx.seed, ctx.noise, poi["x"], poi["z"])
    long_m, deep_m = cfg["bench_m"]
    ux, uz = -dz, dx  # along the contour
    corners = [(poi["x"] + su * ux * long_m / 2 + sd * dx * deep_m / 2, poi["z"] + su * uz * long_m / 2 + sd * dz * deep_m / 2) for su in (-1, 1) for sd in (-1, 1)]
    cx, cz = zip(*corners)
    grid, h0 = exact_patch(ctx, min(cx), min(cz), max(cx), max(cz), "lots")
    floor = float(np.min(bilinear(grid, h0, np.array(cx), np.array(cz))))
    h = ctx.layers["height"]
    along, across = box_coords(ctx.x, ctx.z, poi["x"], poi["z"], ux, uz)
    blend = sk["lots"]["blend_m"]
    w = stages.smoothstep(0.0, blend, rect_distance(along, across, long_m / 2, deep_m / 2))
    h = np.minimum(h, floor) * (1.0 - w) + h * w
    t = cfg["trench_m"]
    sx, sz = poi["x"] - dx * deep_m / 2, poi["z"] - dz * deep_m / 2  # middle of the uphill edge
    ta, tc = box_coords(ctx.x, ctx.z, sx - dx * t["l"] / 2, sz - dz * t["l"] / 2, -dx, -dz)
    inside = (np.abs(ta) <= t["l"] / 2) & (np.abs(tc) <= t["w"] / 2)
    h = np.where(inside, np.minimum(h, np.maximum(floor, h - t["depth_max"])), h)
    ctx.layers["height"] = h
    yaw = math.degrees(math.atan2(-dx, dz)) % 360.0
    ctx.cuts.append({"type": "bench", "poi": poi["id"], "x": poi["x"], "z": poi["z"], "long_m": long_m, "deep_m": deep_m, "floor_y": floor, "downhill": [dx, dz], "yaw_deg": yaw})
    ctx.cuts.append({"type": "trench", "poi": poi["id"], "start": [sx, sz], "dir": [-dx, -dz], "l_m": t["l"], "w_m": t["w"], "floor_y": floor})


def _core_corners(lot):
    a = math.radians(lot.get("yaw_deg", 0.0))
    ux, uz, vx, vz = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
    hw, hd = lot["w"] / 2 + lot["margin_m"], lot["d"] / 2 + lot["margin_m"]
    return [(lot["x"] + su * hw * ux + sv * hd * vx, lot["z"] + su * hw * uz + sv * hd * vz) for su in (-1, 1) for sv in (-1, 1)]


@stage("quarry")
def _stage_quarry(ctx):
    """Bench uphill of the place's lots, floor = ground at the middle of its
    back edge minus the face height, levelled (cut and fill); where the ground
    stands above the floor it meets it within the face samples, else it
    blends over the lot blend."""
    sk, cfg = ctx.sketch, ctx.sketch.get("quarry")
    poi = next((p for p in sk.get("pois", []) if cfg and p["id"] == cfg["poi"]), None)
    if poi is None:
        return
    dx, dz = downhill(sk, ctx.seed, ctx.noise, poi["x"], poi["z"])
    upx, upz = -dx, -dz
    blend = sk["lots"]["blend_m"]
    reach = 0.0
    for lot in ctx.lots:
        if lot.get("poi") == poi["id"] and "w" in lot:
            for cx, cz in _core_corners(lot):
                reach = max(reach, (cx - poi["x"]) * upx + (cz - poi["z"]) * upz)
    long_m, deep_m = cfg["bench_m"]
    front = reach + blend
    mx, mz = poi["x"] + upx * (front + deep_m / 2), poi["z"] + upz * (front + deep_m / 2)
    bx, bz = poi["x"] + upx * (front + deep_m), poi["z"] + upz * (front + deep_m)
    grid, h0 = exact_patch(ctx, bx - 1, bz - 1, bx + 1, bz + 1, "mine")
    floor = float(bilinear(grid, h0, bx, bz)) - cfg["face_m"]
    h = ctx.layers["height"]
    along, across = box_coords(ctx.x, ctx.z, mx, mz, -dz, dx)
    d = rect_distance(along, across, long_m / 2, deep_m / 2)
    ramp = np.where(h > floor, cfg["face_samples"] * ctx.grid.sample_m, blend)
    w = stages.smoothstep(0.0, ramp, d)
    ctx.layers["height"] = floor * (1.0 - w) + h * w
    yaw = math.degrees(math.atan2(-dx, dz)) % 360.0
    ctx.cuts.append({"type": "quarry", "poi": poi["id"], "x": mx, "z": mz, "long_m": long_m, "deep_m": deep_m, "floor_y": floor, "back": [bx, bz], "downhill": [dx, dz], "yaw_deg": yaw})
