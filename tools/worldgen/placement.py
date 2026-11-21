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
import json
import math

import numpy as np

from . import biome, derive, geometry, roads
from .grid import Grid

CELL_M = 4.0
## Tree chunk files (04 §2): 128 m chunks, 7-byte records.
CHUNK_M = 128.0
RECORD_BYTES = 7
POS_UNITS_PER_M = 512.0
SIZES = ("young", "mature", "old")
## Gap kept between any two trunks, metres (beyond their radii).
TRUNK_GAP_M = 1.0
## Darts thrown per wanted tree before a species gives up in a biome.
MAX_DARTS = 30


def tree_table(path):
    """Rows of the tree table in file order (the model index): the game's
    trees.json ({"trees": [...]}) or the CSV it is made from."""
    if path.endswith(".json"):
        with open(path, encoding="utf-8") as f:
            rows = json.load(f)["trees"]
    else:
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
    vista = np.zeros(x.shape, dtype=bool)
    if "vista" in sk:  # its own rule (_vista): only young trees beyond the grass part
        inside, along = in_vista(sk, x, z)
        vista = inside & usable & (along >= vista_strip(sk)[4])
        usable &= ~inside
    factor = np.ones_like(h)
    names = biome.names(sk)
    for b in sk["biomes"]:
        lim = b.get("tree_limits")
        if lim:
            sel = bio == b["id"]
            lo, hi = float(lim["full_below"]), float(lim["none_above"])
            factor[sel] = np.clip((hi - h[sel]) / (hi - lo), 0.0, 1.0)
    return {"grid": g, "x": x, "z": z, "biome": bio, "height": h, "usable": usable, "factor": factor, "names": names, "vista": vista}


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
    out = {"model": [], "x": [], "z": [], "biome": [], "rule": []}
    stunted = {b["id"] for b in sk["biomes"] if b.get("stunted")}
    expect = expected_counts(sk, gd, cell_m)
    has_vista = "vista" in sk
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
                if has_vista and in_vista(sk, x, z)[0]:
                    continue
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
                out["rule"].append("density")
                placed += 1
                if placed == n:
                    break
    fit = _Fitter(index, reach, factor_k, table, gd, cell_m, sk)
    _vista(rng, out, fit, models, sk, gd, cell_m)
    _hazel_edges(rng, out, fit, models, sk, cfg, gd, cell_m)
    _hedgerows(rng, out, fit, models, sk, cfg, gd)
    _antenna_snags(rng, out, fit, table, sk, cfg)
    rec = {k: np.asarray(v) for k, v in out.items()}
    rec["planted"] = rec["model"].copy()  # before dead wood replaces some
    _dead_wood(rng, rec, table, sk, cfg)
    count = rec["model"].size
    rec["yaw"] = rng.integers(0, 256, count, dtype=np.uint8)
    rec["scale"] = rng.integers(0, 256, count, dtype=np.uint8)
    return rec


class _Fitter:
    """Places single trees with the same spacing rules as the main pass."""

    def __init__(self, index, reach, factor_k, table, gd, cell_m, sk=None):
        self.index, self.reach, self.k, self.table, self.gd, self.cell = index, reach, factor_k, table, gd, cell_m
        self.sk = sk

    def usable(self, x, z):
        col, row = int(x // self.cell), int(z // self.cell)
        g = self.gd
        if not (0 <= row < g["usable"].shape[0] and 0 <= col < g["usable"].shape[1]):
            return False, -1
        return bool(g["usable"][row, col]), int(g["biome"][row, col])

    def fits(self, x, z, model, vista=False):
        """Spacing holds, and the point is outside the vista strip unless
        `vista` (only the vista rule plants there)."""
        if not vista and self.sk is not None and "vista" in self.sk and in_vista(self.sk, x, z)[0]:
            return False
        r = self.table[model]
        sp, cr, tr = r["species"], r["canopy_r_m"], r["trunk_r_m"]
        for ox, oz, osp, ocr, otr in self.index.near(x, z, self.reach):
            d = math.hypot(x - ox, z - oz)
            if d < tr + otr + TRUNK_GAP_M or (osp == sp and d < self.k * max(cr, ocr)):
                return False
        return True

    def add(self, out, x, z, model, bid, rule):
        r = self.table[model]
        self.index.add((x, z, r["species"], r["canopy_r_m"], r["trunk_r_m"]))
        for key, v in (("model", model), ("x", x), ("z", z), ("biome", bid), ("rule", rule)):
            out[key].append(v)


def vista_strip(sk):
    """(origin, unit direction, width, length, grass length, young cap) of
    the vista strip; bearing measured clockwise from north (map -z)."""
    v = sk["vista"]
    a = math.radians(float(v["bearing_deg"]))
    return np.asarray(v["from"], dtype=np.float64), np.array([math.sin(a), -math.cos(a)]), float(v["width_m"]), float(v["length_m"]), float(v.get("grass_m", 0.0)), float(v.get("young_max_per_ha", 0.0))


def in_vista(sk, x, z):
    """(inside the strip, metres along it) for map points."""
    o, d, w, length, _, _ = vista_strip(sk)
    px, pz = np.asarray(x) - o[0], np.asarray(z) - o[1]
    along = px * d[0] + pz * d[1]
    across = -px * d[1] + pz * d[0]
    return (along >= 0) & (along <= length) & (np.abs(across) <= w / 2), along


def _vista(rng, out, fit, models, sk, gd, cell_m):
    """Young trees only in the strip beyond its grass part, young_max_per_ha
    of them, species drawn by the local biome's densities."""
    if "vista" not in sk:
        return
    cap = vista_strip(sk)[5]
    cells = np.flatnonzero(gd["vista"].ravel())
    n = int(round(cap * cells.size * cell_m * cell_m / 10000.0))
    dens = species_densities(sk)
    cols = gd["x"].shape[1]
    placed, darts = 0, 0
    while placed < n and darts < n * MAX_DARTS:
        c = int(cells[rng.integers(cells.size)])
        row, col = divmod(c, cols)
        bid = int(gd["biome"][row, col])
        mix = {sp: v for sp, v in dens.get(bid, {}).items() if sp in models and "young" in models[sp]}
        darts += 1
        if not mix:
            continue
        names = sorted(mix)
        p = np.array([mix[k] for k in names])
        sp = names[int(rng.choice(len(names), p=p / p.sum()))]
        x = col * cell_m + rng.random() * cell_m
        z = row * cell_m + rng.random() * cell_m
        model = models[sp]["young"]
        inside, along = in_vista(sk, x, z)
        if inside and along >= vista_strip(sk)[4] and fit.fits(x, z, model, vista=True):
            fit.add(out, x, z, model, bid, "vista")
            placed += 1


def edge_band(sk, cfg, gd, cell_m):
    """Texels of forest biomes within edge_band_m of non-forest ground."""
    names = gd["names"]
    forest = np.isin(gd["biome"], [b for b, n in names.items() if n in cfg.get("forest_biomes", [])])
    k = max(1, int(round(float(cfg.get("edge_band_m", 0.0)) / cell_m)))
    open_ground = ~forest
    near = open_ground.copy()
    for _ in range(k):  # grow the open ground k texels (4-neighbour steps)
        grown = near.copy()
        grown[1:, :] |= near[:-1, :]
        grown[:-1, :] |= near[1:, :]
        grown[:, 1:] |= near[:, :-1]
        grown[:, :-1] |= near[:, 1:]
        near = grown
    return forest & near & gd["usable"]


def _hazel_edges(rng, out, fit, models, sk, cfg, gd, cell_m):
    per_ha = float(cfg.get("hazel_edge_per_ha", 0.0))
    if per_ha <= 0 or "hazel" not in models:
        return
    band = np.flatnonzero(edge_band(sk, cfg, gd, cell_m).ravel())
    n = int(round(per_ha * band.size * cell_m * cell_m / 10000.0))
    model = models["hazel"]["shrub"]
    placed, darts = 0, 0
    cols = gd["x"].shape[1]
    while placed < n and darts < n * MAX_DARTS:
        c = int(band[rng.integers(band.size)])
        row, col = divmod(c, cols)
        x = col * cell_m + rng.random() * cell_m
        z = row * cell_m + rng.random() * cell_m
        darts += 1
        if fit.fits(x, z, model):
            fit.add(out, x, z, model, int(gd["biome"][row, col]), "hazel")
            placed += 1


def hedgerow_points(sk, cfg, gd):
    """Points every hedgerow_every_m along the outline of the farmland
    rectangles (their union), on usable farmland."""
    step = float(cfg.get("hedgerow_every_m", 0.0))
    out = []
    if step <= 0:
        return out
    for b in sk["biomes"]:
        rects = b.get("rule", {}).get("rects")
        if not rects or not b.get("trees"):
            continue
        for x0, z0, x1, z1 in rects:
            for (ax, az), (bx, bz) in (((x0, z0), (x1, z0)), ((x1, z0), (x1, z1)), ((x1, z1), (x0, z1)), ((x0, z1), (x0, z0))):
                n = int(math.hypot(bx - ax, bz - az) // step)
                for i in range(n):
                    x, z = ax + (bx - ax) * i / n, az + (bz - az) * i / n
                    inner = any(r[0] < x < r[2] and r[1] < z < r[3] for r in rects)
                    if not inner:
                        out.append((x, z, b["id"]))
    return out


def _hedgerows(rng, out, fit, models, sk, cfg, gd):
    species = [s for s in cfg.get("hedgerow_species", []) if s in models]
    if not species:
        return
    mix = cfg["size_mix"]
    k = 0
    for x, z, bid in hedgerow_points(sk, cfg, gd):
        ok, here = fit.usable(x, z)
        if not ok or here != bid:
            continue
        sp = species[k % len(species)]
        k += 1
        sizes = [s for s in SIZES if s in models[sp]]
        size = rng.choice(sizes, p=np.array([mix[s] for s in sizes]) / sum(mix[s] for s in sizes))
        model = models[sp][str(size)]
        if fit.fits(x, z, model):
            fit.add(out, x, z, model, bid, "hedgerow")


def _antenna_snags(rng, out, fit, table, sk, cfg):
    a = cfg.get("antenna_snags")
    if not a:
        return
    poi = next(p for p in sk.get("pois", []) if p["id"] == a["from_poi"])
    model = next(i for i, r in enumerate(table) if r["id"] == "snag")
    r0, r1 = a["r_m"]
    placed = 0
    for _ in range(int(a["count"]) * MAX_DARTS * 10):
        ang = rng.random() * 2 * math.pi
        dist = math.sqrt(rng.uniform(r0 * r0, r1 * r1))
        x, z = poi["x"] + math.cos(ang) * dist, poi["z"] + math.sin(ang) * dist
        ok, bid = fit.usable(x, z)
        if ok and fit.fits(x, z, model):
            fit.add(out, x, z, model, bid, "antenna")
            placed += 1
            if placed == int(a["count"]):
                return
    raise ValueError(f"antenna snags: only {placed} of {a['count']} fit")


def _dead_wood(rng, rec, table, sk, cfg):
    """Turns snag and fallen_log fractions of the forest biomes' trees into
    those models (they keep their place)."""
    ids = {r["id"]: i for i, r in enumerate(table)}
    names = biome.names(sk)
    forest = [bid for bid, n in names.items() if n in cfg.get("forest_biomes", [])]
    density = rec["rule"] == "density"
    pool = np.flatnonzero(np.isin(rec["biome"], forest) & density) if forest else np.array([], dtype=int)
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
        have = int(((rec["biome"] == bid) & (planted == sp) & (rec["rule"] == "density")).sum())
        out.append((bid, sp, want, have))
    return out


def chunk_records(rec, chunk_m=CHUNK_M):
    """{(cx, cz): bytes} of the non-empty chunks; per tree: model u8, x u16,
    z u16 (1/512 m inside the chunk), yaw u8, scale u8, in record order."""
    cx = np.floor(rec["x"] / chunk_m).astype(int)
    cz = np.floor(rec["z"] / chunk_m).astype(int)
    lx = np.clip(np.floor((rec["x"] - cx * chunk_m) * POS_UNITS_PER_M + 0.5), 0, 65535).astype("<u2")
    lz = np.clip(np.floor((rec["z"] - cz * chunk_m) * POS_UNITS_PER_M + 0.5), 0, 65535).astype("<u2")
    rows = np.zeros(rec["model"].size, dtype=[("m", "u1"), ("x", "<u2"), ("z", "<u2"), ("yaw", "u1"), ("s", "u1")])
    rows["m"], rows["x"], rows["z"], rows["yaw"], rows["s"] = rec["model"], lx, lz, rec["yaw"], rec["scale"]
    out = {}
    key = cz * 100000 + cx
    order = np.argsort(key, kind="stable")
    keys = key[order]
    starts = np.flatnonzero(np.r_[True, keys[1:] != keys[:-1]])
    ends = np.r_[starts[1:], keys.size]
    for a, b in zip(starts, ends):
        i = order[a]
        out[(int(cx[i]), int(cz[i]))] = rows[order[a:b]].tobytes()
    return out


def decode_chunk(raw):
    """Records of one chunk file (decompressed) as a structured array."""
    return np.frombuffer(raw, dtype=[("m", "u1"), ("x", "<u2"), ("z", "<u2"), ("yaw", "u1"), ("s", "u1")])


def write_tree_files(rec, out_dir, chunk_m=CHUNK_M):
    """Writes trees/<cx>_<cz>.bin (ZSTD) for every non-empty chunk and
    trees/index.json (chunk size, record size, per file its SHA-256 and
    tree count). Returns the index text's bytes; old chunk files go."""
    import os

    from . import files

    d = os.path.join(out_dir, "trees")
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):
        if name.endswith(".bin"):
            os.remove(os.path.join(d, name))
    entries = {}
    for (cx, cz), raw in sorted(chunk_records(rec, chunk_m).items()):
        name = f"{cx}_{cz}.bin"
        entries[name] = {"count": len(raw) // RECORD_BYTES, "sha256": files.write(os.path.join(d, name), files.compress(raw))}
    doc = {"chunk_m": chunk_m, "record_bytes": RECORD_BYTES, "files": entries}
    text = (json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
    files.write(os.path.join(d, "index.json"), text)
    return text


def check_tree_files(out_dir):
    """Errors of trees/ against its index (hashes, record sizes)."""
    import hashlib
    import os

    from . import files

    d = os.path.join(out_dir, "trees")
    errors = []
    try:
        with open(os.path.join(d, "index.json"), encoding="ascii") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        return [f"trees/index.json: {e}"]
    on_disk = {n for n in os.listdir(d) if n.endswith(".bin")}
    if on_disk != set(doc["files"]):
        errors.append(f"trees/: files {sorted(on_disk ^ set(doc['files']))[:5]} differ from the index")
    for name, e in doc["files"].items():
        try:
            with open(os.path.join(d, name), "rb") as f:
                data = f.read()
        except OSError as ex:
            errors.append(f"trees/{name}: {ex}")
            continue
        if hashlib.sha256(data).hexdigest() != e["sha256"]:
            errors.append(f"trees/{name}: SHA-256 differs from the index")
        elif len(files.decompress(data)) != e["count"] * doc["record_bytes"]:
            errors.append(f"trees/{name}: size differs from its count")
    return errors


def canopy_raster(rec, table, size_m, sample_m=2.0):
    """Boolean raster on sample_m cells (rows north to south): a cell is
    covered when its centre lies within a tree's canopy radius."""
    n = int(round(size_m / sample_m))
    out = np.zeros((n, n), dtype=bool)
    radius = np.array([float(r["canopy_r_m"]) for r in table])
    for model in np.unique(rec["model"]):
        r = radius[model]
        if r <= 0:
            continue
        sel = rec["model"] == model
        x, z = rec["x"][sel], rec["z"][sel]
        i0 = np.floor(x / sample_m).astype(int)
        j0 = np.floor(z / sample_m).astype(int)
        k = int(math.ceil(r / sample_m)) + 1
        for dj in range(-k, k + 1):
            for di in range(-k, k + 1):
                i, j = i0 + di, j0 + dj
                inside = ((i + 0.5) * sample_m - x) ** 2 + ((j + 0.5) * sample_m - z) ** 2 <= r * r
                inside &= (i >= 0) & (j >= 0) & (i < n) & (j < n)
                out[j[inside], i[inside]] = True
    return out


def tree_cover(rec, table, size_m, cell_m=CELL_M, sample_m=2.0):
    """Mask channel A (04 §2): the covered share of each cell_m texel, 0-255."""
    cover = canopy_raster(rec, table, size_m, sample_m).astype(np.float64)
    k = int(round(cell_m / sample_m))
    n = cover.shape[0] // k
    share = cover[: n * k, : n * k].reshape(n, k, n, k).mean(axis=(1, 3))
    return np.floor(share * 255.0 + 0.5).astype(np.uint8)
