"""Stage 13: layers derived from the final height field, at texel centres
(a texel of c metres covers [c*i, c*(i+1)) and samples the map at its
centre, matching the shader UV (xz + 4096) / 8192)."""
import numpy as np

from . import biome
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
