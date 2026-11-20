"""Stage 9: road and track profiles and the cross-section flatten."""
import math

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


def pin(prof, limit, ds, fixed, value):
    """Clips a profile into the slope-limited envelope of fixed samples, so
    those samples take `value` and the limits still hold everywhere."""
    if not np.any(fixed):
        return prof
    g = np.concatenate([[0.0], np.cumsum(np.asarray(limit) * np.asarray(ds))])
    gf, vf = g[fixed], np.asarray(value)[fixed]
    gap = np.abs(g[:, None] - gf[None, :])
    upper = np.min(vf[None, :] + gap, axis=1)
    lower = np.max(vf[None, :] - gap, axis=1)
    return np.clip(prof, lower, upper)


def platforms(sk, line, pts, prof):
    """(centre, height) of every turning platform on a road, and the mask of
    profile samples inside one; the height is the profile at the nearest
    sample to the platform centre."""
    hp = sk.get("hairpins") if line["kind"] == "road" else None
    fixed = np.zeros(len(pts), dtype=bool)
    value = np.zeros(len(pts))
    out = []
    for cx, cz in (hp or {}).get("points", []):
        d = np.hypot(pts[:, 0] - cx, pts[:, 1] - cz)
        height = float(prof[int(np.argmin(d))])
        inside = d < hp["radius_m"]
        fixed |= inside
        value[inside] = height
        out.append(((float(cx), float(cz)), height))
    return out, fixed, value


def intersections(a, b):
    """Crossings of polylines a and b: list of (i, ta, j, tb, x, z) with
    segment indices and positions along them."""
    a, b = np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)
    p, r = a[:-1, None, :], (a[1:] - a[:-1])[:, None, :]
    q, sv = b[None, :-1, :], (b[1:] - b[:-1])[None, :, :]
    den = r[..., 0] * sv[..., 1] - r[..., 1] * sv[..., 0]
    qp = q - p
    with np.errstate(divide="ignore", invalid="ignore"):
        ta = (qp[..., 0] * sv[..., 1] - qp[..., 1] * sv[..., 0]) / den
        tb = (qp[..., 0] * r[..., 1] - qp[..., 1] * r[..., 0]) / den
    hit = (den != 0) & (ta >= 0) & (ta < 1) & (tb >= 0) & (tb < 1)
    out = []
    for i, j in zip(*np.nonzero(hit)):
        x, z = a[i] + ta[i, j] * (a[i + 1] - a[i])
        out.append((int(i), float(ta[i, j]), int(j), float(tb[i, j]), float(x), float(z)))
    return out


def water_data(sk, seed, with_noise):
    """Water lines with bed and level per vertex (as the river stage computes them)."""
    out = []
    for wl in stages.water_lines(sk):
        terrain = stages.centre_profile(sk, seed, with_noise, wl["pts"])
        bed = stages.river_bed(sk, terrain, wl["depth"], wl["line"].get("start"))
        out.append(dict(wl, bed=bed, level=stages.water_level(bed, wl["depth"])))
    return out


def line_crossings(sk, line, pts, s, water):
    """Where a way crosses water: type, point, arc on the way, yaw (degrees,
    compass bearing of the way), and width, bed and level of the water."""
    cr = sk.get("crossings", {})
    out = []
    for w in water:
        for i, ta, j, tb, x, z in intersections(pts, w["pts"]):
            def at(v, j=j, tb=tb):
                return float(v[j] * (1.0 - tb) + v[j + 1] * tb)

            if line["kind"] == "road":
                kind = cr.get("road", "bridge")
            else:
                kind = cr.get("track_stream", "footbridge") if w["line"]["kind"] == "stream" else cr.get("track_river", "ford")
            dx, dz = pts[i + 1] - pts[i]
            out.append(
                {
                    "type": kind,
                    "way": line["id"],
                    "water": w["line"]["id"],
                    "x": x,
                    "z": z,
                    "arc": float(s[i] + ta * (s[i + 1] - s[i])),
                    "yaw_deg": float(math.degrees(math.atan2(dx, -dz)) % 360.0),
                    "width_m": at(w["width"]),
                    "bed": at(w["bed"]),
                    "level": at(w["level"]),
                    "water_pts": w["pts"],
                }
            )
    named = cr.get("named_bridge")
    bridges = [c for c in out if c["type"] == cr.get("road", "bridge")]
    if named and bridges:
        min(bridges, key=lambda c: math.hypot(c["x"] - named[0], c["z"] - named[1]))["type"] = "named"
    return out


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


def profile(sk, seed, with_noise, line, water=()):
    """(points, arc, height) of a way: stage 1-6 terrain on the centre line,
    smoothed, clamped to its grade limits, pinned level on turning platforms
    and down to the ford height where a track fords a river."""
    pts, s = resample_arc(geometry.catmull_rom(line["points"]))
    h = stages.centre_profile(sk, seed, with_noise, pts)
    h = smooth(h, sk["routing"]["profile_smooth_m"])
    limit, ds = grade_limits(sk, line, pts), np.diff(s)
    h = clamp_grade(h, limit, ds)
    _, fixed, value = platforms(sk, line, pts, h)
    ford = sk.get("crossings", {}).get("track_river", "ford")
    for c in line_crossings(sk, line, pts, s, water):
        if c["type"] == ford:
            inside = np.abs(s - c["arc"]) <= c["width_m"] / 2.0
            fixed |= inside
            value[inside] = c["level"] - float(sk["crossings"]["ford_max_depth_m"])
    return pts, s, pin(h, limit, ds, fixed, value)


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


def flatten_disc(h, x, z, centre, radius, blend, height):
    """Level disc at `height`, blended back to the terrain over `blend`."""
    w = stages.smoothstep(radius, radius + blend, np.hypot(x - centre[0], z - centre[1]))
    return height * (1.0 - w) + h * w


def open_channels(before, after, grid, crossings, prof, s, core, blend, bank_deg):
    """Under bridges the flatten may cut but not fill: within the span strip
    along the water line near each bridged crossing keep the lower height."""
    out = after
    x, z = grid.coords()
    tan_b = math.tan(math.radians(bank_deg))
    for c in crossings:
        deck = float(np.interp(c["arc"], s, prof))
        half = c["width_m"] / 2.0 + max(deck - c["bed"], 0.0) / tan_b
        c["deck_y"], c["span_m"] = deck, 2.0 * half
        near = np.hypot(x - c["x"], z - c["z"]) < half + core + blend
        if not near.any():
            continue
        strip = near & (geometry.polyline_distance(grid, c["water_pts"], half) < half)
        out = np.where(strip, np.minimum(before, after), out)
    return out


@stage("roads")
def _stage_roads(ctx):
    sk = ctx.sketch
    water = water_data(sk, ctx.seed, ctx.noise)
    ford = sk.get("crossings", {}).get("track_river", "ford")
    for line in ways(sk):
        pts, s, prof = profile(sk, ctx.seed, ctx.noise, line, water)
        before = ctx.layers["height"]
        core, blend = half_width(sk, line), sk["routing"]["blend_m"]
        after = flatten(before, ctx.grid, pts, prof, core, blend)
        xs = line_crossings(sk, line, pts, s, water)
        bridged = [c for c in xs if c["type"] != ford]
        ctx.layers["height"] = open_channels(before, after, ctx.grid, bridged, prof, s, core, blend, sk["rivers"]["bank_deg"])
        for c in xs:
            c.pop("water_pts")
            c.setdefault("deck_y", float(np.interp(c["arc"], s, prof)))
            c["clearance_m"] = c["deck_y"] - c["level"]
            ctx.crossings.append(c)
        hp = sk.get("hairpins", {})
        for centre, height in platforms(sk, line, pts, prof)[0]:
            ctx.layers["height"] = flatten_disc(
                ctx.layers["height"], ctx.x, ctx.z, centre, hp["radius_m"], hp["blend_m"], height
            )
            ctx.platforms.append({"centre": list(centre), "radius_m": float(hp["radius_m"]), "height": height})
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
