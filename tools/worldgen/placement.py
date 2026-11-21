"""Stage 14a: trees (05 §4 stage 14). Densities per biome and species come
from the sketch's biome table (trees per hectare), rules from its
"placement" block, sizes and canopy radii from the tree table (one row per
model; a record's model byte is the row index).

Ground is judged on 4 m texels at their centres (derive.texel_samples):
no trees on ways, lot cores, water (sea, lake, river ribbons) or slopes
steeper than max_slope_deg. Each biome and species gets exactly
round(density x usable hectares) trees (a tree-limit band scales the
density by height), placed by dart throwing with a Poisson-disc radius of
tree_radius_factor x the larger canopy radius between trees of one species
and a trunk clearance between any two trees.
"""
import csv
import math

import numpy as np

from . import biome, derive, geometry, roads
from .grid import Grid

CELL_M = 4.0
SIZES = ("young", "mature", "old")
## Gap kept between any two trunks, metres (beyond their radii).
TRUNK_GAP_M = 1.0
## Darts thrown per wanted tree before a species gives up in a biome.
MAX_DARTS = 30


def tree_table(path):
    """Rows of the tree table in file order (the model index)."""
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["canopy_r_m"] = float(r["canopy_r_m"])
        r["trunk_r_m"] = float(r["trunk_r_m"])
    return rows


def ground(ctx, cell_m=CELL_M):
    """Per texel: biome id, height, usable (bool) and the density factor of
    a tree-limit band (1 outside any band)."""
    sk = ctx.sketch
    cfg = sk["placement"]
    idx, count = derive.texel_samples(ctx, cell_m)
    h = ctx.layers["height"][np.ix_(idx, idx)]
    g = Grid(cell_m / 2, cell_m / 2, cell_m, count, count)
    x, z = g.coords()
    bcell = float(sk["derive"].get("biome_cell_m", 16.0))
    k = int(round(bcell / cell_m))
    bio = np.repeat(np.repeat(derive.biome_ids(ctx, bcell), k, axis=0), k, axis=1)
    mask = derive.mask_rgba(ctx, cell_m)
    nx, nz = derive.normals(ctx, cell_m)
    slope = np.degrees(np.arccos(np.clip(np.sqrt(np.maximum(1.0 - nx * nx - nz * nz, 0.0)), -1, 1)))
    usable = (mask[..., 0] == 0) & (slope <= float(cfg["max_slope_deg"]))
    usable &= ~_lot_cores(ctx, g, x, z)
    usable &= ~_water(ctx, g, x, z, h)
    factor = np.ones_like(h)
    names = biome.names(sk)
    for b in sk["biomes"]:
        lim = b.get("tree_limits")
        if lim:
            sel = bio == b["id"]
            lo, hi = float(lim["full_below"]), float(lim["none_above"])
            factor[sel] = np.clip((hi - h[sel]) / (hi - lo), 0.0, 1.0)
    return {"grid": g, "x": x, "z": z, "biome": bio, "height": h, "usable": usable, "factor": factor, "names": names}


def _lot_cores(ctx, g, x, z):
    from . import lots

    out = np.zeros(x.shape, dtype=bool)
    for lot in ctx.lots:
        win = lots._window_on(g, x, z, lot)
        if win is not None:
            (rows, cols), d = win
            out[rows, cols] |= d == 0.0
    return out


def _water(ctx, g, x, z, h):
    sk = ctx.sketch
    wet = h < float(sk.get("sea_level_y", 0.0))
    lk = sk["lake"]
    wet |= geometry.ellipse_rho(x, z, lk["x"], lk["z"], lk["a"], lk["b"]) < 1.0
    for w in roads.water_data(sk, ctx.seed, ctx.noise):
        d, seg, t = geometry.polyline_nearest(g, w["pts"], float(w["width"].max()))
        near = seg >= 0
        half = (w["width"][seg[near]] * (1 - t[near]) + w["width"][seg[near] + 1] * t[near]) / 2.0
        inside = np.zeros(x.shape, dtype=bool)
        inside[near] = d[near] < half
        wet |= inside
    return wet


def species_densities(sk):
    """{biome id: {species: trees per ha}}; "mixed" stands for the species
    mix of the catch-all biome (the one with an empty rule), scaled to the
    given total."""
    catch = next((b for b in sk["biomes"] if not b.get("rule")), None)
    mix = dict(catch.get("trees", {})) if catch else {}
    total = sum(mix.values())
    out = {}
    for b in sk["biomes"]:
        dens = {}
        for sp, v in b.get("trees", {}).items():
            if sp == "mixed":
                for s2, v2 in mix.items():
                    dens[s2] = dens.get(s2, 0.0) + v * v2 / total
            else:
                dens[sp] = dens.get(sp, 0.0) + float(v)
        if dens:
            out[b["id"]] = dens
    return out


def expected_counts(sk, gd, cell_m=CELL_M):
    """{(biome id, species): trees} = round(density x usable hectares, with
    the tree-limit factor)."""
    ha = cell_m * cell_m / 10000.0
    out = {}
    for bid, dens in species_densities(sk).items():
        area = float((gd["factor"] * ((gd["biome"] == bid) & gd["usable"])).sum()) * ha
        for sp, v in dens.items():
            out[(bid, sp)] = int(round(v * area))
    return out


def _models(table):
    """{species: {size: model index}}"""
    out = {}
    for i, r in enumerate(table):
        out.setdefault(r["species"], {})[r["size"]] = i
    return out


def _size_plan(rng, n, mix, available, stunted):
    """n sizes with the exact mix over the sizes the species has."""
    if stunted:
        return ["young"] * n
    sizes = [s for s in SIZES if s in available]
    weights = np.array([mix[s] for s in sizes], dtype=np.float64)
    weights /= weights.sum()
    counts = np.floor(weights * n + 0.5).astype(int)
    while counts.sum() > n:
        counts[np.argmax(counts)] -= 1
    while counts.sum() < n:
        counts[np.argmax(weights)] += 1
    plan = [s for s, c in zip(sizes, counts) for _ in range(c)]
    rng.shuffle(plan)
    return plan


class _Index:
    """Spatial hash of placed trees (x, z, species, canopy r, trunk r)."""

    def __init__(self, cell):
        self.cell = cell
        self.cells = {}

    def near(self, x, z, r):
        c = self.cell
        for cz in range(int((z - r) // c), int((z + r) // c) + 1):
            for cx in range(int((x - r) // c), int((x + r) // c) + 1):
                yield from self.cells.get((cx, cz), ())

    def add(self, item):
        key = (int(item[0] // self.cell), int(item[1] // self.cell))
        self.cells.setdefault(key, []).append(item)


def place_trees(ctx, table, gd=None, cell_m=CELL_M):
    """Tree records as arrays: model, x, z (map metres), yaw (0-255),
    scale (0-255), biome. Deterministic for the run's seed."""
    sk = ctx.sketch
    cfg = sk["placement"]
    gd = gd if gd is not None else ground(ctx, cell_m)
    rng = np.random.default_rng([int(ctx.seed), 14])
    models = _models(table)
    factor_k = float(cfg["tree_radius_factor"])
    max_canopy = max(r["canopy_r_m"] for r in table)
    max_trunk = max(r["trunk_r_m"] for r in table)
    index = _Index(cell=8.0)
    reach = max(factor_k * max_canopy, 2 * max_trunk + TRUNK_GAP_M)
    out = {"model": [], "x": [], "z": [], "biome": []}
    stunted = {b["id"] for b in sk["biomes"] if b.get("stunted")}
    expect = expected_counts(sk, gd, cell_m)
    flat_ok = (gd["usable"] & (gd["factor"] > 0)).ravel()
    for (bid, sp), n in sorted(expect.items()):
        if n <= 0 or sp not in models:
            continue
        sel = np.flatnonzero(flat_ok & (gd["biome"].ravel() == bid))
        if sel.size == 0:
            continue
        p = gd["factor"].ravel()[sel]
        p = p / p.sum()
        plan = _size_plan(rng, n, cfg["size_mix"], models[sp], bid in stunted)
        placed = 0
        darts = 0
        while placed < n and darts < n * MAX_DARTS:
            batch = min(4096, (n - placed) * 2 + 16)
            cells = rng.choice(sel, size=batch, p=p)
            jitter = rng.random((batch, 2)) * cell_m
            for c, (jx, jz) in zip(cells, jitter):
                darts += 1
                row, col = divmod(int(c), gd["x"].shape[1])
                x = gd["x"][row, col] - cell_m / 2 + jx
                z = gd["z"][row, col] - cell_m / 2 + jz
                model = models[sp][plan[placed]]
                cr, tr = table[model]["canopy_r_m"], table[model]["trunk_r_m"]
                ok = True
                for ox, oz, osp, ocr, otr in index.near(x, z, reach):
                    d = math.hypot(x - ox, z - oz)
                    if d < tr + otr + TRUNK_GAP_M or (osp == sp and d < factor_k * max(cr, ocr)):
                        ok = False
                        break
                if not ok:
                    continue
                index.add((x, z, sp, cr, tr))
                out["model"].append(model)
                out["x"].append(x)
                out["z"].append(z)
                out["biome"].append(bid)
                placed += 1
                if placed == n:
                    break
    rec = {k: np.asarray(v) for k, v in out.items()}
    rec["planted"] = rec["model"].copy()  # before dead wood replaces some
    _dead_wood(rng, rec, table, sk, cfg)
    count = rec["model"].size
    rec["yaw"] = rng.integers(0, 256, count, dtype=np.uint8)
    rec["scale"] = rng.integers(0, 256, count, dtype=np.uint8)
    return rec


def _dead_wood(rng, rec, table, sk, cfg):
    """Turns snag and fallen_log fractions of the forest biomes' trees into
    those models (they keep their place)."""
    ids = {r["id"]: i for i, r in enumerate(table)}
    names = biome.names(sk)
    forest = [bid for bid, n in names.items() if n in cfg.get("forest_biomes", [])]
    pool = np.flatnonzero(np.isin(rec["biome"], forest)) if forest else np.array([], dtype=int)
    rng.shuffle(pool)
    n_snag = int(round(cfg["snag"] * pool.size))
    n_log = int(round(cfg["fallen_log"] * pool.size))
    rec["model"][pool[:n_snag]] = ids["snag"]
    rec["model"][pool[n_snag : n_snag + n_log]] = ids["fallen_log"]


def count_report(rec, expect, table):
    """[(biome id, species, expected, placed)] by the planted model (snags
    and fallen logs keep the species they replaced)."""
    species = np.array([r["species"] for r in table])
    planted = species[rec["planted"]] if rec["planted"].size else np.array([], dtype=str)
    out = []
    for (bid, sp), want in sorted(expect.items()):
        have = int(((rec["biome"] == bid) & (planted == sp)).sum())
        out.append((bid, sp, want, have))
    return out
