"""Stage 14b: static objects of the regions (rows [sid, x, y, z, yaw] plus
any extra transform values the kind needs, e.g. a cliff's pitch) (05 §4 stage 14, 14 §4-5):
forage spots and loose pickups here, resource nodes in nodes.py; written
to regions/<rx>_<rz>.json with a hash index.

Area rules work on the 4 m texels of placement.ground(): a count is
round(area / m2 per item) (or per hectare), and points are drawn uniformly
over the qualifying ground. Object ids (`sid`) are (region index << 20) |
local index, region index = rz * regions per side + rx.
"""
import hashlib
import json
import math
import os

import numpy as np

from . import files, geometry, placement

REGION_M = 512.0
## Region file version (04 §2 region JSON).
REGION_FILE_VERSION = 1


def area_points(rng, weight, count, cell_m):
    """`count` map points spread uniformly over texels with the given
    weights (share of the texel that qualifies)."""
    flat = weight.ravel()
    sel = np.flatnonzero(flat > 0)
    if count <= 0 or sel.size == 0:
        return np.zeros(0), np.zeros(0)
    p = flat[sel] / flat[sel].sum()
    cells = rng.choice(sel, size=count, p=p)
    rows, cols = np.divmod(cells, weight.shape[1])
    j = rng.random((count, 2)) * cell_m
    return cols * cell_m + j[:, 0], rows * cell_m + j[:, 1]


def _area_ha(weight, cell_m):
    return float(weight.sum()) * cell_m * cell_m / 10000.0


def _biome_mask(gd, names):
    ids = [b for b, n in gd["names"].items() if n in names]
    return np.isin(gd["biome"], ids)


def river_beds(ctx, gd, cell_m=placement.CELL_M):
    """Texels whose centre lies inside a river or stream ribbon."""
    from . import roads

    g = gd["grid"]
    out = np.zeros(gd["biome"].shape, dtype=bool)
    for w in roads.water_data(ctx.sketch, ctx.seed, ctx.noise):
        d, seg, t = geometry.polyline_nearest(g, w["pts"], float(w["width"].max()))
        near = seg >= 0
        half = (w["width"][seg[near]] * (1 - t[near]) + w["width"][seg[near] + 1] * t[near]) / 2.0
        inside = np.zeros(out.shape, dtype=bool)
        inside[near] = d[near] < half
        out |= inside
    return out


def plan_areas(ctx, gd, cover, cell_m=placement.CELL_M):
    """{name: (weight raster, count)} of every area rule (forage spots and
    pickups): the expected counts the check compares against."""
    cfg = ctx.sketch["placement"]
    fg, pk = cfg["forage"], cfg["pickups"]
    usable = gd["usable"].astype(np.float64)
    beds = river_beds(ctx, gd, cell_m).astype(np.float64)
    hills = _biome_mask(gd, pk["hill_biomes"])
    beach = _biome_mask(gd, pk["beach_biomes"])
    forest = _biome_mask(gd, cfg["forest_biomes"])
    edge = placement.edge_band(ctx.sketch, cfg, gd, cell_m).astype(np.float64)
    m2 = pk["m2_per_item"]
    rules = {
        "stick": (usable * cover / 255.0, 1.0 / m2["stick_under_trees"]),
        "stone": (usable * ~hills + 0.0, 1.0 / m2["stone"]),
        "stone_dense": (np.maximum(usable * hills, beds), 1.0 / m2["stone_river_beds_hills"]),
        "flint": (np.maximum(usable * beach, beds), 1.0 / m2["flint_river_beds_beaches"]),
        "berry_bush": (edge, fg["berry_edge_per_ha"] / 10000.0),
        "mushroom_patch": (usable * forest, fg["mushroom_forest_per_ha"] / 10000.0),
        "reed_bed_marsh": (usable * _biome_mask(gd, fg["marsh_biomes"]), fg["marsh_reed_per_ha"] / 10000.0),
    }
    out = {}
    for name, (w, per_m2) in rules.items():
        out[name] = (w, int(round(float(w.sum()) * cell_m * cell_m * per_m2)))
    return out


## Object kind and type id of each area rule.
AREA_KINDS = {
    "stick": ("pickup", "stick"),
    "stone": ("pickup", "stone"),
    "stone_dense": ("pickup", "stone"),
    "flint": ("pickup", "flint"),
    "berry_bush": ("forage", "berry_bush"),
    "mushroom_patch": ("forage", "mushroom_patch"),
    "reed_bed_marsh": ("forage", "reed_bed"),
}


def reed_shore(rng, sk):
    """Reed beds along `reed_lake_shore` of the lake outline (the plain
    ellipse), in `reed_stretches` stretches, one every `reed_every_m`, 1 m
    inside the water."""
    fg = sk["placement"]["forage"]
    lk = sk["lake"]
    a, b = float(lk["a"]), float(lk["b"])
    perimeter = math.pi * (3 * (a + b) - math.sqrt((3 * a + b) * (a + 3 * b)))
    every = float(fg["reed_every_m"])
    n_total = int(round(perimeter / every))
    want = int(round(n_total * float(fg["reed_lake_shore"])))
    stretches = int(fg["reed_stretches"])
    per = [want // stretches + (1 if i < want % stretches else 0) for i in range(stretches)]
    starts = np.sort(rng.choice(n_total, size=stretches, replace=False))
    taken = np.zeros(n_total, dtype=bool)
    for s, n in zip(starts, per):
        k, placed = int(s), 0
        while placed < n:
            if not taken[k % n_total]:
                taken[k % n_total] = True
                placed += 1
            k += 1
    t = np.flatnonzero(taken) * 2 * math.pi / n_total
    ex, ez = a * np.cos(t), b * np.sin(t)
    nrm = np.hypot(ex / a / a, ez / b / b)
    x = lk["x"] + ex - (ex / a / a) / nrm * 1.0
    z = lk["z"] + ez - (ez / b / b) / nrm * 1.0
    return x, z, want


def area_objects(ctx, gd, cover, cell_m=placement.CELL_M):
    """Objects of the area rules plus the lake-shore reeds: list of
    (kind, type id, x, z, yaw degrees), and the plan {rule: count}."""
    rng = np.random.default_rng([int(ctx.seed), 141])
    areas = plan_areas(ctx, gd, cover, cell_m)
    objs = []
    counts = {}
    for name, (w, n) in areas.items():
        x, z = area_points(rng, w, n, cell_m)
        kind, tid = AREA_KINDS[name]
        yaw = rng.integers(0, 360, x.size)
        objs.extend((kind, tid, float(a), float(b), int(c)) for a, b, c in zip(x, z, yaw))
        counts[name] = (n, x.size)
    x, z, want = reed_shore(rng, ctx.sketch)
    yaw = rng.integers(0, 360, x.size)
    objs.extend(("forage", "reed_bed", float(a), float(b), int(c)) for a, b, c in zip(x, z, yaw))
    counts["reed_bed_shore"] = (want, x.size)
    return objs, counts


def region_documents(objs, sk, heights):
    """{(rx, rz): document} grouping objects by region; per kind and type id
    rows [sid, x, y, z, yaw] in map metres (y on the collision triangles)."""
    per_side = int(math.ceil(sk["size_m"] / REGION_M))
    xs = np.array([o[2] for o in objs])
    zs = np.array([o[3] for o in objs])
    ys = files.height_tri(heights, float(sk["sample_m"]), xs, zs) if objs else np.zeros(0)
    docs = {}
    for o, y in zip(objs, ys):
        kind, tid, x, z, yaw = o[:5]
        extra = list(o[5:])  # e.g. a cliff face's pitch
        x, z = round(x, 2), round(z, 2)  # the region follows the stored position
        r = (min(max(int(x // REGION_M), 0), per_side - 1), min(max(int(z // REGION_M), 0), per_side - 1))
        d = docs.setdefault(r, {"version": REGION_FILE_VERSION, "region": list(r), "objects": {}})
        rows = d["objects"].setdefault(kind, {}).setdefault(tid, [])
        rows.append([0, x, round(float(y), 2), z, yaw] + extra)
    for (rx, rz), d in docs.items():
        local = 0
        for kind in sorted(d["objects"]):
            for tid in sorted(d["objects"][kind]):
                for row in d["objects"][kind][tid]:
                    row[0] = ((rz * per_side + rx) << 20) | local
                    local += 1
    return docs


def write_region_files(docs, out_dir):
    """regions/<rx>_<rz>.json per non-empty region and regions/index.json
    (per file SHA-256 and object count); returns the index bytes."""
    d = os.path.join(out_dir, "regions")
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):
        if name.endswith(".json") and name != "index.json":
            os.remove(os.path.join(d, name))
    entries = {}
    for (rx, rz), doc in sorted(docs.items()):
        name = f"{rx}_{rz}.json"
        text = (json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
        count = sum(len(rows) for kinds in doc["objects"].values() for rows in kinds.values())
        entries[name] = {"count": count, "sha256": files.write(os.path.join(d, name), text)}
    index = (json.dumps({"files": entries}, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
    files.write(os.path.join(d, "index.json"), index)
    return index


def check_region_files(out_dir):
    """Errors of regions/ against its index."""
    d = os.path.join(out_dir, "regions")
    try:
        with open(os.path.join(d, "index.json"), encoding="ascii") as f:
            index = json.load(f)
    except (OSError, ValueError) as e:
        return [f"regions/index.json: {e}"]
    errors = []
    on_disk = {n for n in os.listdir(d) if n.endswith(".json") and n != "index.json"}
    if on_disk != set(index["files"]):
        errors.append("regions/: files differ from the index")
    for name, e in index["files"].items():
        try:
            with open(os.path.join(d, name), "rb") as f:
                data = f.read()
        except OSError as ex:
            errors.append(f"regions/{name}: {ex}")
            continue
        if hashlib.sha256(data).hexdigest() != e["sha256"]:
            errors.append(f"regions/{name}: SHA-256 differs from the index")
    return errors
