"""Terrain stages in run order. Every number comes from the sketch; the
functions are pure in (x, z) so a crop gives the same values as the full map."""
import numpy as np

from . import noise
from .pipeline import stage

# Seed offsets of the noise fields, so no two fields share a stream.
SEED_COAST_WEST = 101
SEED_COAST_SOUTH = 102


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
