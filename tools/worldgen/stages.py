"""Terrain stages in run order. Every number comes from the sketch; the
functions are pure in (x, z) so a crop gives the same values as the full map."""
import math

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

from . import geometry, noise
from .grid import Grid
from .pipeline import stage

# Seed offsets of the noise fields, so no two fields share a stream.
SEED_COAST_WEST = 101
SEED_COAST_SOUTH = 102
SEED_FBM = 201
SEED_RIDGED = 301

# Noise amplitudes are evaluated on this map-aligned grid, then blurred and
# interpolated, so a crop gets exactly the values of the full map.
AMP_CELL_M = 8.0
RIDGED_OCTAVES = 4


def smoothstep(e0, e1, v):
    """0 at e0, 1 at e1, cubic between (e0 > e1 gives the falling edge)."""
    t = np.clip((v - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def ramp(x, z, r):
    """Stage 1: h0 + kx*x + kz*(z_ref - z)."""
    return r["h0"] + r["kx"] * x + r["kz"] * (r["z_ref"] - z)


def bump(x, z, b):
    """One compact bump: h*(1 - (d/r)^2)^2 for d < r, else exactly 0."""
    q = ((x - b["x"]) ** 2 + (z - b["z"]) ** 2) / (b["r"] * b["r"])
    return b["h"] * np.where(q < 1.0, (1.0 - q) ** 2, 0.0)


def bumps(x, z, items):
    total = np.zeros(np.broadcast(x, z).shape)
    for b in items:
        total = total + bump(x, z, b)
    return total


@stage("ramp")
def _stage_ramp(ctx):
    ctx.layers["height"] += ramp(ctx.x, ctx.z, ctx.sketch["ramp"])


@stage("bumps")
def _stage_bumps(ctx):
    ctx.layers["height"] += bumps(ctx.x, ctx.z, ctx.sketch["bumps"])


def coast_distance(x, z, c, seed, with_noise):
    """Distance inland from the nearer coast (west line x_c(z), south line
    z_c(x)); negative at sea."""
    w, s = c["west"], c["south"]
    xc = w["base"] + (w["amp"] * noise.value1(z, w["wavelength"], seed + SEED_COAST_WEST) if with_noise else 0.0)
    zc = s["base"] + (s["amp"] * noise.value1(x, s["wavelength"], seed + SEED_COAST_SOUTH) if with_noise else 0.0)
    return np.minimum(x - xc, zc - z)


def coast(h, d, c):
    """Stage 3: blends land down to the shore height over blend_m inland and
    slopes the sea floor down seaward, never below sea_min_h."""
    k = smoothstep(0.0, c["blend_m"], d)
    land = h * k + c["shore_h"] * (1.0 - k)
    sea = np.maximum(c["shore_h"] + c["sea_slope"] * d, c["sea_min_h"])
    return np.where(d >= 0.0, land, sea)


@stage("coast")
def _stage_coast(ctx):
    c = ctx.sketch["coast"]
    d = coast_distance(ctx.x, ctx.z, c, ctx.seed, ctx.noise)
    ctx.layers["height"] = coast(ctx.layers["height"], d, c)


def macro(x, z, sk, seed, with_noise):
    """Stages 1-3 as one pure function (used where a stage needs the terrain
    outside its own grid)."""
    h = ramp(x, z, sk["ramp"]) + bumps(x, z, sk["bumps"])
    return coast(h, coast_distance(x, z, sk["coast"], seed, with_noise), sk["coast"])


def _box(a, w, axis):
    """Mean over w samples centred on each sample (valid part only); the same
    summation order for every output, so crops match bit for bit."""
    return sliding_window_view(a, w, axis=axis).mean(axis=-1)


def amplitude_maps(sk, grid, seed):
    """Blended fBm and ridged amplitudes (metres) at the grid samples."""
    from . import biome  # biome imports this module

    n = sk["noise"]
    cs = AMP_CELL_M
    half = int(math.ceil(n["blend_m"] / 2.0 / cs))
    w = 2 * half + 1
    pad = half + 2  # one more cell for the slope, one for interpolation
    i0 = int(math.floor(grid.x0 / cs)) - pad
    j0 = int(math.floor(grid.z0 / cs)) - pad
    i1 = int(math.ceil((grid.x0 + (grid.nx - 1) * grid.sample_m) / cs)) + pad
    j1 = int(math.ceil((grid.z0 + (grid.nz - 1) * grid.sample_m) / cs)) + pad
    cg = Grid(i0 * cs, j0 * cs, cs, i1 - i0 + 1, j1 - j0 + 1)
    cx, cz = cg.coords()
    ids = biome.classify(sk, cg, macro(cx, cz, sk, seed, True), seed, True)
    by_name = biome.names(sk)
    out = []
    for table in (n["amplitude"], n["ridged"]["amplitude"]):
        a = np.zeros(ids.shape)
        for bid, name in by_name.items():
            a[ids == bid] = float(table.get(name, 0.0))
        a = _box(_box(a, w, 0), w, 1)  # cell (j, i) of a = coarse cell (j + half, i + half)
        ox, oz = cg.x0 + half * cs, cg.z0 + half * cs
        x, z = grid.coords()
        fx, fz = (x - ox) / cs, (z - oz) / cs
        ix, iz = np.floor(fx).astype(np.int64), np.floor(fz).astype(np.int64)
        tx, tz = fx - ix, fz - iz
        v = (a[iz, ix] * (1 - tx) + a[iz, ix + 1] * tx) * (1 - tz) + (a[iz + 1, ix] * (1 - tx) + a[iz + 1, ix + 1] * tx) * tz
        out.append(v)
    return out


def corridor_distance(sk, grid):
    """Distance to the nearest corridor (centre lines, lots, the vista strip,
    the edge bands), capped at the mask's outer distance; 0 inside."""
    c = sk["corridor"]
    cap = float(c["d1"])
    x, z = grid.coords()
    d = np.full(x.shape, cap)
    for line in sk.get("lines", []):
        d = np.minimum(d, geometry.polyline_distance(grid, geometry.catmull_rom(line["points"]), cap))
    radii = c.get("poi_r_m", {})
    for p in sk.get("pois", []):
        r = radii.get(p["id"], radii.get("default"))
        if r is not None:
            d = np.minimum(d, geometry.disc_distance(x, z, p["x"], p["z"], r))
    for disc in c.get("discs", []):
        d = np.minimum(d, geometry.disc_distance(x, z, disc["x"], disc["z"], disc["r"]))
    v = sk.get("vista")
    if v:
        d = np.minimum(d, geometry.strip_distance(x, z, v["from"], v["bearing_deg"], v["length_m"], v["width_m"]))
    sc = sk.get("scarp")
    if sc:
        size = sk["size_m"]
        edge = {"north": z, "south": size - z, "west": x, "east": size - x}
        for e in sc["edges"]:
            d = np.minimum(d, np.maximum(edge[e] - sc["band_m"], 0.0))
        nearest = np.minimum.reduce(list(edge.values()))
        d = np.minimum(d, np.maximum(nearest - sc["noise_free_m"], 0.0))
    return d


@stage("noise")
def _stage_noise(ctx):
    """Stage 4: biome-weighted fBm plus ridged noise, masked to zero along
    the corridors and tapered away from them."""
    if not ctx.noise:
        return
    sk, n = ctx.sketch, ctx.sketch["noise"]
    a_fbm, a_ridged = amplitude_maps(sk, ctx.grid, ctx.seed)
    c = sk["corridor"]
    mask = smoothstep(c["d0"], c["d1"], corridor_distance(sk, ctx.grid))
    f = noise.fbm(ctx.x, ctx.z, n["wavelength"], ctx.seed + SEED_FBM, n["octaves"], n["gain"], n["lacunarity"])
    add = a_fbm * f
    if np.any(a_ridged > 0.0):
        r = n["ridged"]
        add = add + a_ridged * noise.ridged(
            ctx.x, ctx.z, r["wavelength"], ctx.seed + SEED_RIDGED, RIDGED_OCTAVES, n["gain"], n["lacunarity"]
        )
    add *= mask
    ctx.layers["noise"] = add
    ctx.layers["height"] += add


def scarp(x, z, sc, size_m):
    """Stage 5: height_m * smoothstep(band_m, full_at_m, d_edge), d_edge being
    the distance to the nearest of the listed map edges."""
    edge = {"north": z, "south": size_m - z, "west": x, "east": size_m - x}
    d = np.minimum.reduce([np.broadcast_to(edge[e], np.broadcast(x, z).shape) for e in sc["edges"]])
    return sc["height_m"] * smoothstep(sc["band_m"], sc["full_at_m"], d)


@stage("scarp")
def _stage_scarp(ctx):
    ctx.layers["height"] += scarp(ctx.x, ctx.z, ctx.sketch["scarp"], ctx.sketch["size_m"])
