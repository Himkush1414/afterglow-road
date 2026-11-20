"""Centre lines and distance fields on a sample grid (map coordinates)."""
import math

import numpy as np


def catmull_rom(points, step=8.0):
    """Uniform Catmull-Rom spline through the points (end points doubled),
    resampled about every `step` metres. Returns an (n, 2) array that starts
    and ends on the first and last point and passes through every point."""
    p = [tuple(map(float, q)) for q in points]
    if len(p) < 2:
        return np.array(p, dtype=np.float64).reshape(-1, 2)
    ext = [p[0]] + p + [p[-1]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = (np.array(ext[k]) for k in (i - 1, i, i + 1, i + 2))
        n = max(2, int(math.dist(p1, p2) / step))
        t = (np.arange(n, dtype=np.float64) / n)[:, None]
        out.append(
            0.5
            * (
                2 * p1
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t**3
            )
        )
    out.append(np.array([p[-1]]))
    return np.vstack(out)


def _axes(grid):
    xs = grid.x0 + np.arange(grid.nx, dtype=np.float64) * grid.sample_m
    zs = grid.z0 + np.arange(grid.nz, dtype=np.float64) * grid.sample_m
    return xs, zs


def polyline_distance(grid, poly, max_d):
    """Distance from every grid sample to the polyline, capped at max_d.
    Only samples within max_d of a segment's box are visited."""
    xs, zs = _axes(grid)
    out = np.full((grid.nz, grid.nx), float(max_d))
    poly = np.asarray(poly, dtype=np.float64)
    for (ax, az), (bx, bz) in zip(poly[:-1], poly[1:]):
        i0 = np.searchsorted(xs, min(ax, bx) - max_d)
        i1 = np.searchsorted(xs, max(ax, bx) + max_d, side="right")
        j0 = np.searchsorted(zs, min(az, bz) - max_d)
        j1 = np.searchsorted(zs, max(az, bz) + max_d, side="right")
        if i0 >= i1 or j0 >= j1:
            continue
        px, pz = xs[None, i0:i1], zs[j0:j1, None]
        dx, dz = bx - ax, bz - az
        ll = dx * dx + dz * dz
        t = np.clip(((px - ax) * dx + (pz - az) * dz) / ll, 0.0, 1.0) if ll > 0 else 0.0
        d = np.hypot(px - (ax + t * dx), pz - (az + t * dz))
        np.minimum(out[j0:j1, i0:i1], d, out=out[j0:j1, i0:i1])
    return out


def strip_distance(x, z, start, bearing_deg, length, width):
    """Distance to a straight strip that starts at `start` and runs `length`
    metres on a compass bearing (0 = north = -z, 90 = east); 0 inside."""
    b = math.radians(bearing_deg)
    ux, uz = math.sin(b), -math.cos(b)
    rx, rz = x - start[0], z - start[1]
    along = rx * ux + rz * uz
    across = np.abs(rx * -uz + rz * ux)
    da = np.maximum(np.maximum(-along, along - length), 0.0)
    dc = np.maximum(across - width / 2.0, 0.0)
    return np.hypot(da, dc)


def disc_distance(x, z, cx, cz, r):
    """Distance to a disc; 0 inside."""
    return np.maximum(np.hypot(x - cx, z - cz) - r, 0.0)
