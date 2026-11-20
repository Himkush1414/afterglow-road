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


def load_stages():
    """Imports the stage modules in run order (importing registers them)."""
    from . import roads, stages  # noqa: F401  (stages registers first: roads imports it)


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


def layer_bytes(array, dtype):
    """Little-endian bytes of a layer in the given dtype, row-major."""
    return np.ascontiguousarray(array, dtype=np.dtype(dtype).newbyteorder("<")).tobytes()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


__all__ = ["Context", "Grid", "STAGES", "layer_bytes", "run", "sha256", "stage"]
