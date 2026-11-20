"""Stage 13: layers derived from the final height field, at texel centres
(a texel of c metres covers [c*i, c*(i+1)) and samples the map at its
centre, matching the shader UV (xz + 4096) / 8192)."""
import numpy as np

from . import biome, geometry, stages
from .grid import Grid


def _require_full_map(ctx):
    g, sk = ctx.grid, ctx.sketch
    n = int(round(sk["size_m"] / g.sample_m)) + 1
    if (g.x0, g.z0, g.nx, g.nz) != (0.0, 0.0, n, n):
        raise ValueError("derived layers need a full-map run")


def texel_samples(ctx, cell_m):
    """Row and column sample indices of the texel centres for a texel size."""
    _require_full_map(ctx)
    s = ctx.grid.sample_m
    count = int(round(ctx.sketch["size_m"] / cell_m))
    step, first = int(round(cell_m / s)), int(round(cell_m / 2 / s))
    idx = first + step * np.arange(count)
    return idx, count


def normals(ctx, cell_m=4.0):
    """(n_x, n_z) per texel: normalize(-dh/dx, 1, -dh/dz) by central
    differences over one sample each way."""
    h, s = ctx.layers["height"], ctx.grid.sample_m
    idx, _ = texel_samples(ctx, cell_m)
    r, c = np.meshgrid(idx, idx, indexing="ij")
    dx = (h[r, c + 1] - h[r, c - 1]) / (2 * s)
    dz = (h[r + 1, c] - h[r - 1, c]) / (2 * s)
    inv = 1.0 / np.sqrt(dx * dx + 1.0 + dz * dz)
    return -dx * inv, -dz * inv


def normal_bytes(ctx, cell_m=4.0):
    """Two bytes per texel, x then z: round((n * 0.5 + 0.5) * 255)."""
    nx, nz = normals(ctx, cell_m)
    enc = np.stack([nx, nz], axis=-1) * 0.5 + 0.5
    return np.floor(enc * 255.0 + 0.5).astype(np.uint8).tobytes()


def biome_ids(ctx, cell_m=16.0):
    """Biome id per texel by the sketch rules on the final field."""
    idx, count = texel_samples(ctx, cell_m)
    h = ctx.layers["height"][np.ix_(idx, idx)]
    g = Grid(cell_m / 2, cell_m / 2, cell_m, count, count)
    return biome.classify(ctx.sketch, g, h, ctx.seed, ctx.noise)


def biome_bytes(ctx, cell_m=16.0):
    ids = biome_ids(ctx, cell_m)
    if ids.min() < 0 or ids.max() > 255:
        raise ValueError("a texel has no biome or an id beyond a byte")
    return ids.astype(np.uint8).tobytes()


def mask_rgba(ctx, cell_m=4.0):
    """RGBA8 per texel (rows, cols, 4): R way surface (255 inside a way's flat
    cross-section, never inside a lot core), G wetness (255 in the wet biome,
    else falling to 0 over `wet_distance_m` from water), B rock (255 where
    the slope exceeds `rock_slope_deg`), A tree cover (0 until placement)."""
    from . import lots, roads  # both import the stage modules

    sk, cfg = ctx.sketch, ctx.sketch["derive"]
    idx, count = texel_samples(ctx, cell_m)
    g = Grid(cell_m / 2, cell_m / 2, cell_m, count, count)
    x, z = g.coords()
    out = np.zeros((count, count, 4), dtype=np.uint8)
    way = np.zeros((count, count), dtype=bool)
    for rec in ctx.roads:
        way |= geometry.polyline_distance(g, rec["points"], rec["core_m"]) < rec["core_m"]
    for lot in ctx.lots:
        win = lots._window_on(g, x, z, lot)
        if win is not None:
            (rows, cols), d = win
            way[rows, cols] &= d != 0.0
    out[..., 0] = np.where(way, 255, 0)
    reach = float(cfg["wet_distance_m"])
    wet = np.full((count, count), reach)
    for w in roads.water_data(sk, ctx.seed, ctx.noise):
        d, seg, t = geometry.polyline_nearest(g, w["pts"], reach + w["width"].max())
        near = seg >= 0
        half = (w["width"][seg[near]] * (1 - t[near]) + w["width"][seg[near] + 1] * t[near]) / 2.0
        wet[near] = np.minimum(wet[near], np.maximum(d[near] - half, 0.0))
    lk = sk["lake"]
    inside = geometry.ellipse_rho(x, z, lk["x"], lk["z"], lk["a"], lk["b"]) < 1.0
    edge = geometry.ellipse_edge_distance(x, z, lk["x"], lk["z"], lk["a"], lk["b"])
    wet = np.minimum(wet, np.where(inside, 0.0, edge))
    gval = 255.0 * (1.0 - stages.smoothstep(0.0, reach, wet))
    names = biome.names(sk)
    wet_ids = [i for i, n in names.items() if n == cfg["wet_biome"]]
    bcell = float(cfg.get("biome_cell_m", 16.0))
    k = int(round(bcell / cell_m))  # each biome texel covers k x k mask texels
    bio = np.repeat(np.repeat(biome_ids(ctx, bcell), k, axis=0), k, axis=1)
    gval = np.where(np.isin(bio, wet_ids), 255.0, gval)
    out[..., 1] = np.floor(gval + 0.5).astype(np.uint8)
    nx, nz = normals(ctx, cell_m)
    ny = np.sqrt(np.maximum(1.0 - nx * nx - nz * nz, 0.0))
    out[..., 2] = np.where(np.degrees(np.arccos(np.clip(ny, -1, 1))) > cfg["rock_slope_deg"], 255, 0)
    return out


def mask_bytes(ctx, cell_m=4.0):
    return mask_rgba(ctx, cell_m).tobytes()


def minmax_levels(ctx, encoded):
    """Per level L (lods[0]..lods[1]) the (min, max) arrays of the encoded
    heights over every node of node_m * 2^L metres, rows north to south,
    each over its samples including its far edge."""
    _require_full_map(ctx)
    cfg = ctx.sketch["derive"]
    lo_l, hi_l = cfg["minmax_lods"]
    n = int(round(cfg["minmax_node_m"] / ctx.grid.sample_m))  # samples per level-0 node edge
    h = np.asarray(encoded)
    count = (h.shape[0] - 1) // n

    def reduce(fn):
        body = fn(h[: count * n].reshape(count, n, -1), axis=1)
        rows = fn(np.stack([body, h[n :: n][:count]]), axis=0)  # add each node's far row
        body = fn(rows[:, : count * n].reshape(count, count, n), axis=2)
        return fn(np.stack([body, rows[:, n :: n][:, :count]]), axis=0)  # and far column

    mins, maxs = reduce(np.min), reduce(np.max)
    out = []
    for level in range(hi_l + 1):
        if level >= lo_l:
            out.append((mins, maxs))
        if level < hi_l:
            k = mins.shape[0] // 2
            mins = mins.reshape(k, 2, k, 2).min(axis=(1, 3))
            maxs = maxs.reshape(k, 2, k, 2).max(axis=(1, 3))
    return out


def minmax_bytes(ctx, encoded):
    """Levels in order; per node (row-major) min u16 then max u16."""
    parts = []
    for mins, maxs in minmax_levels(ctx, encoded):
        parts.append(np.stack([mins, maxs], axis=-1).astype("<u2").tobytes())
    return b"".join(parts)
