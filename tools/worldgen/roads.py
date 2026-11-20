"""Stage 9: road and track profiles and the cross-section flatten."""
import numpy as np

from . import geometry, stages
from .pipeline import stage

PROFILE_STEP_M = 2.0  # arc spacing of the profile samples
WAY_KINDS = ("track", "road")  # flatten order: the road wins at junctions


def resample_arc(pts, step=PROFILE_STEP_M):
    """Points every `step` metres of arc along a polyline (last point kept);
    returns (points, arc lengths)."""
    pts = np.asarray(pts, dtype=np.float64)
    s = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(pts, axis=0).T))])
    t = np.arange(0.0, s[-1], step)
    if s[-1] - t[-1] > 1e-9:
        t = np.append(t, s[-1])
    return np.stack([np.interp(t, s, pts[:, 0]), np.interp(t, s, pts[:, 1])], axis=1), t


def smooth(h, window_m, step=PROFILE_STEP_M):
    """Box mean over window_m of arc; the ends are padded with the end values."""
    n = int(round(window_m / step / 2.0))
    if n < 1 or len(h) < 2:
        return np.array(h, dtype=np.float64)
    padded = np.pad(np.asarray(h, dtype=np.float64), (n, n), mode="edge")
    return np.convolve(padded, np.ones(2 * n + 1) / (2 * n + 1), mode="valid")


def clamp_grade(h, limit, ds):
    """Mean of a forward and a backward pass that each keep |dh| <= limit*ds
    per interval (limit and ds per interval, arrays of len(h) - 1)."""
    h = np.asarray(h, dtype=np.float64)
    step = np.asarray(limit, dtype=np.float64) * np.asarray(ds, dtype=np.float64)
    f, b = h.copy(), h.copy()
    for i in range(1, len(h)):
        f[i] = min(max(f[i], f[i - 1] - step[i - 1]), f[i - 1] + step[i - 1])
    for i in range(len(h) - 2, -1, -1):
        b[i] = min(max(b[i], b[i + 1] - step[i]), b[i + 1] + step[i])
    return 0.5 * (f + b)


def grade_limits(sk, line, pts):
    """Grade limit per interval: tracks one value; the road a low limit up to
    the vertex nearest the split point and a high one after it."""
    n = len(pts) - 1
    if line["kind"] == "track":
        return np.full(n, float(sk["tracks"]["max_grade"]))
    rg = sk["road_grade"]
    k = int(np.argmin(np.hypot(pts[:, 0] - rg["split_at"][0], pts[:, 1] - rg["split_at"][1])))
    g = np.full(n, float(rg["high"]))
    g[:k] = float(rg["low"])
    return g


def profile(sk, seed, with_noise, line):
    """(points, arc, height) of a way: stage 1-6 terrain on the centre line,
    smoothed, then clamped to its grade limits."""
    pts, s = resample_arc(geometry.catmull_rom(line["points"]))
    h = stages.centre_profile(sk, seed, with_noise, pts)
    h = smooth(h, sk["routing"]["profile_smooth_m"])
    return pts, s, clamp_grade(h, grade_limits(sk, line, pts), np.diff(s))


def half_width(sk, line):
    """Half of the flat cross-section: the way plus its shoulders."""
    return line["width_m"] / 2.0 + float(line.get("shoulder_m", 0.0))


def flatten(h, grid, pts, prof, core, blend):
    """Sets the terrain to the profile within `core` of the centre line and
    blends back to the terrain over `blend` (cut and fill)."""
    d, seg, t = geometry.polyline_nearest(grid, pts, core + blend)
    near = seg >= 0
    if not near.any():
        return h
    k, tt = seg[near], t[near]
    p = prof[k] * (1.0 - tt) + prof[k + 1] * tt
    w = stages.smoothstep(core, core + blend, d[near])
    out = h.copy()
    out[near] = p * (1.0 - w) + h[near] * w
    return out


def ways(sk):
    return [ln for kind in WAY_KINDS for ln in sk.get("lines", []) if ln["kind"] == kind]


@stage("roads")
def _stage_roads(ctx):
    sk = ctx.sketch
    for line in ways(sk):
        pts, s, prof = profile(sk, ctx.seed, ctx.noise, line)
        ctx.layers["height"] = flatten(
            ctx.layers["height"], ctx.grid, pts, prof, half_width(sk, line), sk["routing"]["blend_m"]
        )
        terrain = stages.centre_profile(sk, ctx.seed, ctx.noise, pts)
        ctx.roads.append(
            {
                "id": line["id"],
                "type": line["kind"],
                "width_m": float(line["width_m"]),
                "points": pts,
                "arc": s,
                "profile": prof,
                "max_cut_fill_m": float(np.abs(prof - terrain).max()),
            }
        )
