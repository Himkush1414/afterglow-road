"""Biome map from the sketch's ordered rules (first match wins).

A rule is a dict; every key in it must hold (AND), `any` holds if one of
its sub-rules does, and an empty rule always holds. Keys:
  height_below v, height_above v, height_between [a, b]   terrain height
  slope_above_deg v, slope_below_deg v                     terrain slope
  near_sea_m v          less than v inland from the coast (or at sea)
  not_water             outside the lake and the river/stream beds
  near_lake_edge_m v    within v of the lake outline
  near_water_m v        within v of a river/stream centre line or the lake
  near_point {x, z, m}  within m of a point
  near_pois {id: m}     within m of any of these named places
  bumps_above {ids, m}  the named bumps add more than m together
  rects [[x0, z0, x1, z1], ...]   inside one of the rectangles
"""
import numpy as np

from . import geometry, stages

WATER_KINDS = ("river", "stream")


class Inputs:
    """Everything the rules read, on one grid. h is the terrain height."""

    def __init__(self, sketch, grid, h, seed, with_noise):
        self.sketch, self.grid, self.h = sketch, grid, h
        self.x, self.z = grid.coords()
        self.seed, self.with_noise = seed, with_noise
        self._cache = {}

    def get(self, name, fn):
        if name not in self._cache:
            self._cache[name] = fn()
        return self._cache[name]

    def slope_deg(self):
        def f():
            gz, gx = np.gradient(self.h, self.grid.sample_m)
            return np.degrees(np.arctan(np.hypot(gx, gz)))

        return self.get("slope", f)

    def coast_d(self):
        c = self.sketch["coast"]
        return self.get("coast", lambda: stages.coast_distance(self.x, self.z, c, self.seed, self.with_noise))

    def lake_rho(self):
        """Normalised elliptic radius of the lake (1 on the outline)."""
        lk = self.sketch["lake"]
        return self.get("rho", lambda: geometry.ellipse_rho(self.x, self.z, lk["x"], lk["z"], lk["a"], lk["b"]))

    def lake_edge_d(self):
        lk = self.sketch["lake"]
        return self.get(
            "lake_edge", lambda: geometry.ellipse_edge_distance(self.x, self.z, lk["x"], lk["z"], lk["a"], lk["b"])
        )

    def water_line_d(self, cap):
        def f():
            d = np.full(self.h.shape, float(cap))
            for line in self.sketch.get("lines", []):
                if line["kind"] in WATER_KINDS:
                    poly = geometry.catmull_rom(line["points"])
                    d = np.minimum(d, geometry.polyline_distance(self.grid, poly, cap))
            return d

        return self.get(("water", cap), f)

    def in_water(self):
        def f():
            half = max(
                (max(ln["width_m"]) / 2.0 for ln in self.sketch.get("lines", []) if ln["kind"] in WATER_KINDS),
                default=0.0,
            )
            return (self.lake_rho() < 1.0) | (self.water_line_d(max(half, 1.0)) < half)

        return self.get("in_water", f)


def _holds(rule, ip):
    m = np.ones(ip.h.shape, dtype=bool)
    for key, v in rule.items():
        if key == "any":
            k = np.zeros(ip.h.shape, dtype=bool)
            for sub in v:
                k |= _holds(sub, ip)
        elif key == "height_below":
            k = ip.h < v
        elif key == "height_above":
            k = ip.h > v
        elif key == "height_between":
            k = (ip.h >= v[0]) & (ip.h < v[1])
        elif key == "slope_above_deg":
            k = ip.slope_deg() > v
        elif key == "slope_below_deg":
            k = ip.slope_deg() < v
        elif key == "near_sea_m":
            k = ip.coast_d() < v
        elif key == "not_water":
            k = ~ip.in_water() if v else np.ones(ip.h.shape, dtype=bool)
        elif key == "near_lake_edge_m":
            k = ip.lake_edge_d() < v
        elif key == "near_water_m":
            k = (ip.water_line_d(v) < v) | (ip.lake_edge_d() < v) | (ip.lake_rho() < 1.0)
        elif key == "near_point":
            k = np.hypot(ip.x - v["x"], ip.z - v["z"]) < v["m"]
        elif key == "near_pois":
            k = np.zeros(ip.h.shape, dtype=bool)
            for p in ip.sketch["pois"]:
                if p["id"] in v:
                    k |= np.hypot(ip.x - p["x"], ip.z - p["z"]) < v[p["id"]]
        elif key == "bumps_above":
            items = [b for b in ip.sketch["bumps"] if b["id"] in v["ids"]]
            k = stages.bumps(ip.x, ip.z, items) > v["m"]
        elif key == "rects":
            k = np.zeros(ip.h.shape, dtype=bool)
            for x0, z0, x1, z1 in v:
                k |= (ip.x >= x0) & (ip.x <= x1) & (ip.z >= z0) & (ip.z <= z1)
        else:
            raise ValueError(f"unknown biome rule key {key!r}")
        m &= k
    return m


def classify(sketch, grid, h, seed, with_noise=True):
    """Biome id (int16) per sample; -1 where no rule matched."""
    ip = Inputs(sketch, grid, h, seed, with_noise)
    out = np.full(h.shape, -1, dtype=np.int16)
    for b in sketch["biomes"]:
        free = out < 0
        if not free.any():
            break
        out[free & _holds(b["rule"], ip)] = b["id"]
    return out


def names(sketch):
    """Biome id -> name."""
    return {b["id"]: b["name"] for b in sketch["biomes"]}
