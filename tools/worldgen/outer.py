"""Stage 12a: the outer ring (05 §4). A coarse height grid around the map
that closes the view from high ground: stages 1-3 and 5 evaluated outside
the map (the ramp and the bumps continue) plus the backdrop bumps of the
sketch's "outer" block. The grid also covers the map itself; the game skips
the cells inside it."""
import numpy as np

from . import files, stages


def axis(sk):
    """Map coordinates of the grid lines on one axis (cells + 1 samples)."""
    o = sk["outer"]
    return float(o["range"][0]) + np.arange(int(o["cells"]) + 1, dtype=np.float64) * float(o["cell_m"])


def heights(sk, seed=None):
    """Heights of every grid sample, rows north to south."""
    seed = sk["world_seed"] if seed is None else seed
    a = axis(sk)
    x, z = np.meshgrid(a, a)
    h = stages.macro(x, z, sk, seed, True)
    h = h + stages.scarp(x, z, sk["scarp"], sk["size_m"])
    return h + stages.bumps(x, z, sk["outer"]["bumps"])


def check_layout(sk):
    """Errors of the outer block: the range must be cells x cell_m long and
    the map edges must fall on grid lines."""
    o, errors = sk["outer"], []
    lo, hi = (float(v) for v in o["range"])
    if abs((hi - lo) - float(o["cells"]) * float(o["cell_m"])) > 1e-9:
        errors.append(f"outer: range {lo:g}..{hi:g} is not {o['cells']} cells of {o['cell_m']} m")
    for edge in (0.0, float(sk["size_m"])):
        if abs(((edge - lo) / float(o["cell_m"])) % 1.0) > 1e-9:
            errors.append(f"outer: map edge {edge:g} is not on a grid line")
    return errors


def outer_bytes(sk, seed=None):
    """outer.bin before compression: u16 heights in the world encoding."""
    return files.encode_height(heights(sk, seed), sk).tobytes()
