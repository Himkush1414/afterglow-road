"""Terrain stages in run order. Every number comes from the sketch; the
functions are pure in (x, z) so a crop gives the same values as the full map."""
import numpy as np

from .pipeline import stage


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
