"""Settlement layouts: plots along the Road and side streets (stage 9-10).

A plot has a frontage along a way and a depth away from it. Its building
is centred on the frontage with its front edge `setback_m` behind the way's
flat edge, facing the way; a garden building (shed) stands at the back."""
import math

import numpy as np

from . import geometry, layout, roads, stages

CLASS_ORDER = ("shop", "garage", "house", "warehouse")


def _road(sk):
    line = next(ln for ln in sk["lines"] if ln["kind"] == "road")
    pts, s = roads.resample_arc(geometry.catmull_rom(line["points"]))
    return line, pts, s


def _left(tx, tz):
    return tz, -tx


class RoadArm:
    """Positions along the Road from arc s0 in direction +1 or -1."""

    def __init__(self, pts, s, s0, direction, core, way):
        self.pts, self.s, self.s0, self.dir, self.core, self.way = pts, s, s0, direction, core, way

    def length(self):
        return self.s[-1] - self.s0 if self.dir > 0 else self.s0

    def at(self, q):
        sq = self.s0 + self.dir * q
        x = float(np.interp(sq, self.s, self.pts[:, 0]))
        z = float(np.interp(sq, self.s, self.pts[:, 1]))
        a, b = sq - 1.0, sq + 1.0
        tx = np.interp(b, self.s, self.pts[:, 0]) - np.interp(a, self.s, self.pts[:, 0])
        tz = np.interp(b, self.s, self.pts[:, 1]) - np.interp(a, self.s, self.pts[:, 1])
        n = math.hypot(tx, tz)
        return x, z, self.dir * tx / n, self.dir * tz / n


class StraightArm:
    def __init__(self, x, z, ax, az, core, way):
        self.x, self.z, self.ax, self.az, self.core, self.way = x, z, ax, az, core, way

    def at(self, q):
        return self.x + self.ax * q, self.z + self.az * q, self.ax, self.az


def ordered(sk, names):
    """(plot buildings in class order, garden buildings)."""
    cls = sk["lots"]["plot_class"]
    garden = [n for n in names if n == sk["lots"]["garden"]]
    main = sorted((n for n in names if n in cls), key=lambda n: CLASS_ORDER.index(cls[n]))
    return main, garden


def place(sk, poi, arm, side, q0, name):
    """Lot of a building on a plot starting q0 along an arm, and its plot."""
    cfg, size = sk["lots"], sk["buildings"]
    front_m, depth_m = cfg["sizes_m"][cfg["plot_class"][name]]
    x, z, tx, tz = arm.at(q0 + front_m / 2.0)
    lx, lz = _left(tx, tz)
    nx, nz = side * lx, side * lz
    d = size[name]["d"]
    off = arm.core + cfg["setback_m"] + d / 2.0
    lot = {"poi": poi["id"], "archetype": name, "way": arm.way, "x": x + nx * off, "z": z + nz * off, "w": size[name]["w"], "d": d, "yaw_deg": layout.yaw_facing(-nx, -nz)}
    plot = {"x": x, "z": z, "n": (nx, nz), "core": arm.core, "depth": depth_m, "yaw_deg": lot["yaw_deg"], "way": arm.way}
    return lot, plot


def garden_lot(sk, poi, plot, name):
    size, margin = sk["buildings"][name], sk["lots"]["margin_m"]
    off = plot["core"] + plot["depth"] - margin - size["d"] / 2.0
    nx, nz = plot["n"]
    return {"poi": poi["id"], "archetype": name, "way": plot["way"], "x": plot["x"] + nx * off, "z": plot["z"] + nz * off, "w": size["w"], "d": size["d"], "yaw_deg": plot["yaw_deg"]}


def _finish(sk, poi, placed, garden):
    lots = [lot for lot, _ in placed]
    houses = [plot for (lot, plot) in placed if sk["lots"]["plot_class"][lot["archetype"]] == "house"]
    lots += [garden_lot(sk, poi, plot, name) for plot, name in zip(houses, garden)]
    for i, lot in enumerate(lots):
        lot["id"] = f"{poi['id']}_{i}"
    return lots


def row(sk, seed, with_noise, poi, names):
    """One row on the higher side of the Road, from the place towards the
    longer remaining Road."""
    line, pts, s = _road(sk)
    s0 = float(s[int(np.argmin(np.hypot(pts[:, 0] - poi["x"], pts[:, 1] - poi["z"])))])
    arm = RoadArm(pts, s, s0, 1 if s[-1] - s0 >= s0 else -1, roads.half_width(sk, line), line["id"])
    x, z, tx, tz = arm.at(50.0)
    lx, lz = _left(tx, tz)
    probe = np.array([[x + lx * 40, z + lz * 40], [x - lx * 40, z - lz * 40]])
    h = stages.centre_profile(sk, seed, with_noise, probe)
    side = 1 if h[0] >= h[1] else -1
    main, garden = ordered(sk, names)
    placed, q = [], 0.0
    for name in main:
        placed.append(place(sk, poi, arm, side, q, name))
        q += sk["lots"]["sizes_m"][sk["lots"]["plot_class"][name]][0]
    return _finish(sk, poi, placed, garden), []


def cross(sk, poi, names):
    """One straight street across the Road at the place; plots round-robin
    to the arm-side whose next plot is nearest the crossing."""
    cfg = sk["lots"]
    line, pts, s = _road(sk)
    k = int(np.argmin(np.hypot(pts[:, 0] - poi["x"], pts[:, 1] - poi["z"])))
    s0 = float(s[k])
    road_core = roads.half_width(sk, line)
    street_core = cfg["side_street_m"] / 2.0
    main, garden = ordered(sk, names)
    deepest = max(cfg["sizes_m"][cfg["plot_class"][n]][1] for n in main)
    street_id = f"street_{poi['id']}"
    ox, oz, tx, tz = RoadArm(pts, s, s0, 1, road_core, line["id"]).at(0.0)
    nx, nz = _left(tx, tz)
    arms = []  # [arm, side, cursor, street sign or 0]
    for direction in (1, -1):
        arms += [[RoadArm(pts, s, s0, direction, road_core, line["id"]), side, street_core, 0] for side in (1, -1)]
    for sign in (1, -1):
        arm = StraightArm(ox, oz, sign * nx, sign * nz, street_core, street_id)
        arms += [[arm, side, road_core + deepest, sign] for side in (1, -1)]
    placed = []
    for name in main:
        arm = min(arms, key=lambda a: a[2])  # first of the nearest
        placed.append(place(sk, poi, arm[0], arm[1], arm[2], name))
        arm[2] += cfg["sizes_m"][cfg["plot_class"][name]][0]
    reach = {sign: max(a[2] for a in arms if a[3] == sign) for sign in (1, -1)}
    street = {
        "id": street_id,
        "kind": "street",
        "width_m": float(cfg["side_street_m"]),
        "points": [[ox - nx * reach[-1], oz - nz * reach[-1]], [ox + nx * reach[1], oz + nz * reach[1]]],
    }
    return _finish(sk, poi, placed, garden), [street]


def _normals(pts):
    t = np.gradient(pts, axis=0)
    t /= np.hypot(t[:, 0], t[:, 1])[:, None]
    return np.stack([t[:, 1], -t[:, 0]], axis=1)  # left of the travel direction


def grid(sk, poi, names):
    """Blocks in Road coordinates around the place: rows along the Road,
    columns across it, 5 m streets between and around them."""
    cfg = sk["lots"]
    g = cfg["grid"]
    rows, cols = g["blocks"]
    across_m, along_m = g["block_m"]
    st = cfg["side_street_m"]
    street_core = st / 2.0
    line, pts, s = _road(sk)
    rc = roads.half_width(sk, line)
    sc = float(s[int(np.argmin(np.hypot(pts[:, 0] - poi["x"], pts[:, 1] - poi["z"])))])
    total = rows * along_m + (rows + 1) * st
    first = sc - total / 2.0
    edges = [first + st + k * (along_m + st) for k in range(rows)]  # row start (after its cross street)
    sel = (s >= first - 2.0) & (s <= first + total + 2.0)
    rp, rs, rn = pts[sel], s[sel], _normals(pts)[sel]
    per_side = cols // 2
    streets, offsets = [], {}
    for side in (1, -1):
        for c in range(per_side):
            n = rc + (c + 1) * across_m + c * st + street_core
            spts = rp + rn * (side * n)
            sarc = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(spts, axis=0).T))])
            sid = f"street_{poi['id']}_{'l' if side > 0 else 'r'}{c + 1}"
            offsets[(side, c)] = (sid, spts, sarc)
            streets.append({"id": sid, "kind": "street", "width_m": float(st), "points": spts[::4].tolist() + [spts[-1].tolist()]})
    n_max = rc + per_side * (across_m + st)
    for k in range(rows + 1):
        cs = first + street_core + k * (along_m + st)
        x, z = np.interp(cs, rs, rp[:, 0]), np.interp(cs, rs, rp[:, 1])
        nx, nz = np.interp(cs, rs, rn[:, 0]), np.interp(cs, rs, rn[:, 1])
        streets.append({"id": f"street_{poi['id']}_c{k}", "kind": "street", "width_m": float(st), "points": [[x - nx * n_max, z - nz * n_max], [x + nx * n_max, z + nz * n_max]]})
    faces = []  # [arm, side, cursor, end, fronts_road, pair key]
    for k, a in enumerate(edges):
        for side in (1, -1):
            for c in range(per_side):
                if c == 0:
                    inner = (RoadArm(pts, s, a, 1, rc, line["id"]), side, 0.0, along_m, True)
                else:
                    sid, spts, sarc = offsets[(side, c - 1)]
                    q0 = float(np.interp(a, rs, sarc))
                    inner = (RoadArm(spts, sarc, q0, 1, street_core, sid), side, 0.0, float(np.interp(a + along_m, rs, sarc)) - q0, False)
                sid, spts, sarc = offsets[(side, c)]
                q0 = float(np.interp(a, rs, sarc))
                outer = (RoadArm(spts, sarc, q0, 1, street_core, sid), -side, 0.0, float(np.interp(a + along_m, rs, sarc)) - q0, False)
                for f in (inner, outer):
                    faces.append(list(f) + [(k, side, c), 0.0])
    main, garden = ordered(sk, names)
    placed, unplaced = [], []
    for name in main:
        front_m, depth_m = cfg["sizes_m"][cfg["plot_class"][name]]
        best = None
        for f in faces:
            other = max((g2[6] for g2 in faces if g2[5] == f[5] and g2 is not f), default=0.0)
            if f[2] + front_m > f[3] + 1e-9 or other + max(depth_m, f[6]) > across_m + 1e-9:
                continue
            x, z, _, _ = f[0].at(f[2] + front_m / 2.0)
            key = (0 if f[4] else 1, math.hypot(x - poi["x"], z - poi["z"]))
            if best is None or key < best[0]:
                best = (key, f)
        if best is None:
            unplaced.append(name)
            continue
        f = best[1]
        placed.append(place(sk, poi, f[0], f[1], f[2], name))
        f[2] += front_m
        f[6] = max(f[6], depth_m)
    return _finish(sk, poi, placed, garden), streets, unplaced


def plan(sk, seed, with_noise):
    """{"lots": [...], "streets": [...], "handled": {place ids}} for every
    settlement whose layout is implemented."""
    cfg = sk.get("lots", {})
    pois = {p["id"]: p for p in sk.get("pois", [])}
    size = sk.get("buildings", {})
    out = {"lots": [], "streets": [], "handled": set(), "unplaced": []}
    for key in ("shore_row", "street_cross", "grid"):
        if key not in cfg or cfg[key]["poi"] not in pois:
            continue
        poi = pois[cfg[key]["poi"]]
        names = layout.buildings_of(poi.get("contents", ""), size)
        if key == "shore_row":
            lots, streets = row(sk, seed, with_noise, poi, names)
        elif key == "street_cross":
            lots, streets = cross(sk, poi, names)
        else:
            lots, streets, unplaced = grid(sk, poi, names)
            out["unplaced"] += [(poi["id"], n) for n in unplaced]
        out["lots"] += lots
        out["streets"] += streets
        out["handled"].add(poi["id"])
    return out
