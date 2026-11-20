"""Lot list for single places and farmsteads (stage 10 input).

A building's footprint is w (local x) by d (local z); its front, the door
side, is local +z. yaw_deg turns it clockwise, so the front points along
(-sin yaw, cos yaw) in map coordinates."""
import math
import re

import numpy as np

_PREFIX = re.compile(r"^\w+:\s*")


def buildings_of(contents, archetypes):
    """Archetype ids named in a contents text, counts expanded, in order."""
    out = []
    for token in contents.split(";"):
        token = _PREFIX.sub("", token.strip())
        m = re.match(r"^(\d+)\s+(\S+)$", token)
        count, name = (int(m.group(1)), m.group(2)) if m else (1, token)
        if name not in archetypes and name.endswith("s") and name[:-1] in archetypes:
            name = name[:-1]
        if name in archetypes:
            out.extend([name] * count)
    return out


def yaw_facing(fx, fz):
    """yaw_deg that turns a building's front toward direction (fx, fz)."""
    return math.degrees(math.atan2(-fx, fz)) % 360.0


def _unit(vx, vz):
    n = math.hypot(vx, vz)
    return (vx / n, vz / n) if n > 0 else (0.0, 1.0)


def nearest_way(ways, x, z):
    """(distance, point, record) of the nearest way centre-line point."""
    best = None
    for rec in ways:
        p = rec["points"]
        d = np.hypot(p[:, 0] - x, p[:, 1] - z)
        k = int(np.argmin(d))
        if best is None or d[k] < best[0]:
            best = (float(d[k]), (float(p[k, 0]), float(p[k, 1])), rec)
    return best


def _gap(cfg):
    """Footprint spacing in a row: both margins plus one blend, so no lot's
    blend reaches a neighbour's flat core."""
    return 2.0 * cfg["margin_m"] + cfg["blend_m"]


def _lot(poi, n, arch, size, x, z, yaw):
    return {"id": f"{poi}_{n}", "poi": poi, "archetype": arch, "x": x, "z": z, "w": size["w"], "d": size["d"], "yaw_deg": yaw}


def single(sk, poi, names, ways):
    """First building at the place facing the nearest way (pulled back to
    the setback), the rest in a row behind it."""
    cfg, size = sk["lots"], sk["buildings"]
    gap, setback = _gap(cfg), cfg["setback_m"]
    x, z = poi["x"], poi["z"]
    main = size[names[0]]
    near = nearest_way(ways, x, z)
    fx, fz = (0.0, 1.0)
    if near:
        dist, (qx, qz), rec = near
        fx, fz = _unit(qx - x, qz - z)
        need = rec["core_m"] + setback + main["d"] / 2.0
        if dist < need:
            x, z = qx - fx * need, qz - fz * need
    yaw = yaw_facing(fx, fz)
    lots = [_lot(poi["id"], 0, names[0], main, x, z, yaw)]
    rest = names[1:]
    if rest:
        rx, rz = fz, -fx  # the building's local +x axis
        widths = [size[n]["w"] for n in rest]
        total = sum(widths) + gap * (len(rest) - 1)
        u = -total / 2.0
        for i, (name, w) in enumerate(zip(rest, widths), start=1):
            back = main["d"] / 2.0 + gap + size[name]["d"] / 2.0
            cu = u + w / 2.0
            lots.append(_lot(poi["id"], i, name, size[name], x - fx * back + rx * cu, z - fz * back + rz * cu, yaw))
            u += w + gap
    return lots


def farmstead(sk, poi, names, ways):
    """Farmhouse on the far side of a square yard at the track's end, barn on
    the left, the other buildings in a row on the right; fronts face the yard."""
    cfg, size = sk["lots"], sk["buildings"]
    gap, half = _gap(cfg), cfg["yard_m"] / 2.0
    x, z = poi["x"], poi["z"]
    tracks = [r for r in ways if r["type"] == "track" and math.hypot(r["points"][-1][0] - x, r["points"][-1][1] - z) < 1.0]
    if tracks:
        p = tracks[0]["points"]
        tx, tz = _unit(p[-1][0] - p[-5][0], p[-1][1] - p[-5][1])
    else:
        tx, tz = 0.0, -1.0
    lx, lz = tz, -tx  # left of the arrival direction
    key = cfg["farmstead"]["key"]
    rest = list(names)
    house = [rest.pop(rest.index(key))] if key in rest else []
    left = cfg["farmstead"]["left"]
    barn = [rest.pop(rest.index(left))] if left in rest else []
    lots, n = [], 0
    for name in house:
        off = half + size[name]["d"] / 2.0
        lots.append(_lot(poi["id"], n, name, size[name], x + tx * off, z + tz * off, yaw_facing(-tx, -tz)))
        n += 1
    for name in barn:
        off = half + size[name]["d"] / 2.0
        lots.append(_lot(poi["id"], n, name, size[name], x + lx * off, z + lz * off, yaw_facing(-lx, -lz)))
        n += 1
    widths = [size[r]["w"] for r in rest]
    total = sum(widths) + gap * max(len(rest) - 1, 0)
    u = -total / 2.0
    for name, w in zip(rest, widths):
        off = half + size[name]["d"] / 2.0
        cu = u + w / 2.0
        lots.append(_lot(poi["id"], n, name, size[name], x - lx * off + tx * cu, z - lz * off + tz * cu, yaw_facing(lx, lz)))
        n += 1
        u += w + gap
    return lots


def fixed(sk, poi, items):
    size = sk["buildings"]
    return [
        _lot(poi["id"], i, it["archetype"], size[it["archetype"]], poi["x"] + it["dx"], poi["z"] + it["dz"], float(it.get("yaw_deg", 0.0)))
        for i, it in enumerate(items)
    ]


def generate(sk, ways):
    """(lots, ids of places left for the settlement layouts)."""
    cfg = sk.get("lots", {})
    size = sk.get("buildings", {})
    settled = set(cfg.get("settlements", []))
    fixed_layouts = cfg.get("fixed", {})
    lots, pending = [], []
    for poi in sk.get("pois", []):
        names = buildings_of(poi.get("contents", ""), size)
        if poi["id"] in fixed_layouts:
            lots += fixed(sk, poi, fixed_layouts[poi["id"]])
        elif not names:
            continue
        elif poi["id"] in settled:
            pending.append(poi["id"])
        elif cfg.get("farmstead", {}).get("key") in names:
            lots += farmstead(sk, poi, names, ways)
        else:
            lots += single(sk, poi, names, ways)
    return lots, pending


def way_overlaps(lots, ways, step=1.0):
    """(lot id, way id) for every lot whose footprint comes within a way's
    flat cross-section."""
    out = []
    for lot in lots:
        a = math.radians(lot.get("yaw_deg", 0.0))
        ux, uz, vx, vz = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        if "r" in lot:
            continue
        us = np.arange(-lot["w"] / 2.0, lot["w"] / 2.0 + 1e-9, step)
        vs = np.arange(-lot["d"] / 2.0, lot["d"] / 2.0 + 1e-9, step)
        u, v = np.meshgrid(us, vs)
        px, pz = (lot["x"] + u * ux + v * vx).ravel(), (lot["z"] + u * uz + v * vz).ravel()
        for rec in ways:
            p = rec["points"]
            if np.hypot(p[:, 0] - lot["x"], p[:, 1] - lot["z"]).min() > math.hypot(lot["w"], lot["d"]) + rec["core_m"]:
                continue
            d = np.min(np.hypot(px[:, None] - p[None, :, 0], pz[:, None] - p[None, :, 1]), axis=1)
            if d.min() < rec["core_m"]:
                out.append((lot["id"], rec["id"]))
    return out
