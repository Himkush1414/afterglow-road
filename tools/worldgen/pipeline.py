"""Stage registry, run context and output hashing."""
import hashlib

import numpy as np

from .grid import Grid

STAGES = []


def stage(name):
    """Registers a function f(ctx) as the next stage, in definition order."""

    def wrap(fn):
        if any(n == name for n, _ in STAGES):
            raise ValueError(f"stage {name} registered twice")
        STAGES.append((name, fn))
        return fn

    return wrap


class Context:
    """Inputs and layers of one run. Stages read ctx.sketch and ctx.seed,
    and write numpy arrays into ctx.layers (all shaped like the grid).
    With noise=False every noise term is zero (the smooth macro terrain)."""

    def __init__(self, sketch, grid, seed, noise=True):
        self.sketch = sketch
        self.grid = grid
        self.seed = int(seed)
        self.noise = bool(noise)
        self.x, self.z = grid.coords()
        self.layers = {"height": np.zeros((grid.nz, grid.nx), dtype=np.float64)}
        self.water = {}  # water bodies for water.json, filled by the water stages
        self.roads = []  # way records for roads.json, filled by the road stage
        self.platforms = []  # levelled turning platforms on the roads
        self.crossings = []  # bridges, footbridges and fords
        self.route_failures = []  # places without a track route under the grade limit
        self.lots = []  # flattened lots with their height
        self.lot_pending = []  # places whose buildings wait for a settlement layout
        self.lot_way_overlaps = []  # (lot, way) pairs whose footprint meets a way
        self.cuts = []  # benches and trenches cut into the ground


def load_stages():
    """Imports the stage modules in run order (importing registers them)."""
    from . import roads, stages  # noqa: F401  (stages registers first: roads imports it)
    from . import lots  # noqa: F401  (after the roads)
    from . import cuts  # noqa: F401  (after the lots)


def run(sketch, grid, seed, stages=None, until=None, noise=True):
    """Runs the stages in order (all registered ones by default) and stops
    after the stage named `until` if given. Returns the context."""
    if stages is None:
        load_stages()
    ctx = Context(sketch, grid, seed, noise)
    for name, fn in stages if stages is not None else STAGES:
        fn(ctx)
        if name == until:
            break
    return ctx


def exact_patch(ctx, x0, z0, x1, z1, until):
    """(grid, height) covering the box [x0, x1] x [z0, z1] with the values the
    full map has after stage `until`: the run's own grid and layer when the
    box plus the erosion reach lies inside it, else a map-aligned sub-run
    around the box. The caller must call this before changing the layer."""
    import math

    g, sk = ctx.grid, ctx.sketch
    s = g.sample_m
    reach = sk.get("erosion", {}).get("iterations", 0) * s
    gx1, gz1 = g.x0 + (g.nx - 1) * s, g.z0 + (g.nz - 1) * s
    if x0 - reach >= g.x0 and z0 - reach >= g.z0 and x1 + reach <= gx1 and z1 + reach <= gz1:
        return g, ctx.layers["height"]
    sx0 = math.floor((x0 - reach) / s) * s
    sz0 = math.floor((z0 - reach) / s) * s
    nx = int(math.ceil((x1 + reach - sx0) / s)) + 1
    nz = int(math.ceil((z1 + reach - sz0) / s)) + 1
    sub = Grid(sx0, sz0, s, nx, nz)
    return sub, run(sk, sub, ctx.seed, until=until, noise=ctx.noise).layers["height"]


def bilinear(grid, h, x, z):
    """Height of a layer at map points (inside the grid)."""
    fx = (np.asarray(x, dtype=np.float64) - grid.x0) / grid.sample_m
    fz = (np.asarray(z, dtype=np.float64) - grid.z0) / grid.sample_m
    i = np.clip(np.floor(fx).astype(int), 0, grid.nx - 2)
    j = np.clip(np.floor(fz).astype(int), 0, grid.nz - 2)
    tx, tz = fx - i, fz - j
    return (h[j, i] * (1 - tx) + h[j, i + 1] * tx) * (1 - tz) + (h[j + 1, i] * (1 - tx) + h[j + 1, i + 1] * tx) * tz


def layer_bytes(array, dtype):
    """Little-endian bytes of a layer in the given dtype, row-major."""
    return np.ascontiguousarray(array, dtype=np.dtype(dtype).newbyteorder("<")).tobytes()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


__all__ = ["Context", "Grid", "STAGES", "bilinear", "exact_patch", "layer_bytes", "run", "sha256", "stage"]
