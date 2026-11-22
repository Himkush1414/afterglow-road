"""The walkable grid of T-05-5 (05 §14): every height sample is a cell; two
4-neighbours are joined when the slope between them is below the walkable
limit and neither is under water deeper than the wading limit. Bridge
decks are walking surfaces over their channels."""
import math

import numpy as np

from . import cuts, geometry, roads, stages  # noqa: F401  (cuts registers the stages before this one)
from .pipeline import stage


def water_depth(ctx):
    """Depth of standing or running water over every sample (0 on land):
    sea below its level, the lake inside its outline, rivers and streams
    near their centre lines below their surface."""
    sk, g, h = ctx.sketch, ctx.grid, ctx.layers["height"]
    surface = np.where(h < float(sk.get("sea_level_y", 0.0)), float(sk.get("sea_level_y", 0.0)), -np.inf)
    lk = sk["lake"]
    inside = geometry.ellipse_rho(ctx.x, ctx.z, lk["x"], lk["z"], lk["a"], lk["b"]) < 1.0
    surface = np.where(inside, np.maximum(surface, float(lk["level"])), surface)
    for w in roads.water_data(sk, ctx.seed, ctx.noise):
        d, seg, t = geometry.polyline_nearest(g, w["pts"], float(w["width"].max()))
        near = seg >= 0
        k, tt = seg[near], t[near]
        level = w["level"][k] * (1.0 - tt) + w["level"][k + 1] * tt
        width = w["width"][k] * (1.0 - tt) + w["width"][k + 1] * tt
        lv = np.where(d[near] < width, level, -np.inf)
        surface[near] = np.maximum(surface[near], lv)
    return np.maximum(surface - h, 0.0)


def bridge_decks(ctx):
    """(mask, height) of the samples on bridge and footbridge decks: within
    the way's core of its centre line along the span, at the way profile."""
    g = ctx.grid
    mask = np.zeros((g.nz, g.nx), dtype=bool)
    deck = np.zeros((g.nz, g.nx))
    recs = {r["id"]: r for r in ctx.roads}
    for c in ctx.crossings:
        if "span_m" not in c or c["way"] not in recs:
            continue
        rec = recs[c["way"]]
        s = rec["arc"]
        on = np.abs(s - c["arc"]) <= c["span_m"] / 2.0 + g.sample_m
        if on.sum() < 2:
            continue
        pts, arc, prof = rec["points"][on], s[on], rec["profile"][on]
        d, seg, t = geometry.polyline_nearest(g, pts, rec["core_m"])
        near = (seg >= 0) & (d <= rec["core_m"])
        k, tt = seg[near], t[near]
        a = arc[k] * (1.0 - tt) + arc[k + 1] * tt
        span = np.abs(a - c["arc"]) <= c["span_m"] / 2.0
        rows, cols = np.nonzero(near)
        mask[rows[span], cols[span]] = True
        deck[rows[span], cols[span]] = (prof[k] * (1.0 - tt) + prof[k + 1] * tt)[span]
    return mask, deck


def walk_surface(ctx):
    """(surface height, water depth, deck mask) with bridge decks laid over
    the field."""
    depth = water_depth(ctx)
    on, deck = bridge_decks(ctx)
    surface = np.where(on, deck, ctx.layers["height"])
    return surface, np.where(on, 0.0, depth), on


def edges(surface, depth, sample_m, slope_deg, depth_m):
    """(east, south) passable-edge masks: east[j, i] joins (j, i)-(j, i+1),
    south[j, i] joins (j, i)-(j+1, i)."""
    rise = math.tan(math.radians(slope_deg)) * sample_m
    dry = depth < depth_m
    east = (np.abs(np.diff(surface, axis=1)) < rise) & dry[:, :-1] & dry[:, 1:]
    south = (np.abs(np.diff(surface, axis=0)) < rise) & dry[:-1, :] & dry[1:, :]
    return east, south


def components(east, south):
    """Label of every cell: the smallest flat index in its connected
    component (min-label propagation with root hooking and pointer jumping)."""
    nz, nx = east.shape[0], south.shape[1]
    lab = np.arange(nz * nx, dtype=np.int64).reshape(nz, nx)
    big = np.iinfo(np.int64).max
    while True:
        m = lab.copy()
        np.minimum(m[:, :-1], np.where(east, lab[:, 1:], big), out=m[:, :-1])
        np.minimum(m[:, 1:], np.where(east, lab[:, :-1], big), out=m[:, 1:])
        np.minimum(m[:-1, :], np.where(south, lab[1:, :], big), out=m[:-1, :])
        np.minimum(m[1:, :], np.where(south, lab[:-1, :], big), out=m[1:, :])
        if np.array_equal(m, lab):
            return lab
        flat, mf = lab.ravel(), m.ravel()
        np.minimum.at(flat, flat.copy(), mf)  # hook each root under the smallest label seen beside its members
        np.minimum(flat, mf, out=flat)
        while True:
            nxt = flat[flat]
            if np.array_equal(nxt, flat):
                break
            flat[:] = nxt


def cell_slope(surface, sample_m):
    """Slope of every cell in degrees from central differences (one-sided
    on the map border)."""
    dz, dx = np.gradient(surface, sample_m)
    return np.degrees(np.arctan(np.hypot(dx, dz)))


def walkable(east, south, slope, slope_deg):
    """Cells whose own slope is below the limit and that have at least one
    passable edge (a cell walled in on all four sides is a spike or a sink)."""
    w = np.zeros((east.shape[0], south.shape[1]), dtype=bool)
    w[:, :-1] |= east
    w[:, 1:] |= east
    w[:-1, :] |= south
    w[1:, :] |= south
    return w & (slope < slope_deg)


def cell_of(grid, x, z):
    """(row, column) of the sample nearest to a map point."""
    return int(round((z - grid.z0) / grid.sample_m)), int(round((x - grid.x0) / grid.sample_m))


def is_full_map(ctx):
    g, sk = ctx.grid, ctx.sketch
    n = int(round(sk["size_m"] / g.sample_m)) + 1
    return (g.x0, g.z0, g.nx, g.nz) == (0.0, 0.0, n, n)


class Walk:
    """The walkable grid of a run: surface, depth, edges, labels, and the
    component of the start place."""

    def __init__(self, ctx):
        ck, g = ctx.sketch["checks"], ctx.grid
        self.surface, self.depth, self.deck = walk_surface(ctx)
        self.east, self.south = edges(self.surface, self.depth, g.sample_m, float(ck["walk_slope_deg"]), float(ck["walk_depth_m"]))
        self.labels = components(self.east, self.south)
        self.walkable = walkable(self.east, self.south, cell_slope(self.surface, g.sample_m), float(ck["walk_slope_deg"]))
        start = next(p for p in ctx.sketch["pois"] if p["id"] == ck["start_poi"])
        self.main = self.labels == self.labels[cell_of(g, start["x"], start["z"])]
        sk = ctx.sketch
        self.band = stages.scarp_band(ctx.x, ctx.z, sk["scarp"], sk["size_m"])

    def pockets(self):
        """Walkable cells outside the boundary band that the start place
        cannot reach."""
        return self.walkable & ~self.main & ~self.band


_SHIFTS = ((0, 1), (0, -1), (1, 0), (-1, 0))


def _shift(a, dj, di, fill):
    """a moved so that out[j, i] = a[j + dj, i + di] (fill outside)."""
    out = np.full_like(a, fill)
    nz, nx = a.shape
    out[max(-dj, 0) : nz - max(dj, 0), max(-di, 0) : nx - max(di, 0)] = a[max(dj, 0) : nz + min(dj, 0) or None, max(di, 0) : nx + min(di, 0) or None]
    return out


def fill(h, pocket, reached):
    """Gives every pocket cell the height of its closest-in-height reached
    4-neighbour, growing inward from the reached ground one ring at a time.
    Returns (new height, cells changed, cells left without a neighbour)."""
    h = h.copy()
    done, todo = reached.copy(), pocket.copy()
    changed = 0
    while todo.any():
        best = np.full(h.shape, np.inf)
        value = h.copy()
        for dj, di in _SHIFTS:
            nb_done = _shift(done, dj, di, False)
            nb_h = _shift(h, dj, di, 0.0)
            diff = np.where(todo & nb_done, np.abs(nb_h - h), np.inf)
            take = diff < best
            best = np.where(take, diff, best)
            value = np.where(take, nb_h, value)
        ring = np.isfinite(best)
        if not ring.any():
            break
        changed += int((ring & (value != h)).sum())
        h = np.where(ring, value, h)
        done |= ring
        todo &= ~ring
    return h, changed, int(todo.sum())


def dilate(mask, cells):
    """mask grown by `cells` 4-neighbour steps."""
    out = mask.copy()
    for _ in range(cells):
        grown = out.copy()
        for dj, di in _SHIFTS:
            grown |= _shift(out, dj, di, False)
        out = grown
    return out


@stage("pockets")
def _stage_pockets(ctx):
    """Fills the walkable pockets the start place cannot reach (05 §14
    T-05-5): a pocket beside reached ground takes the heights of its reached
    neighbours; a pocket walled in all round (a pit) is filled together with
    its walls out to a ring that doubles each round. Needs the whole map
    (the start place and the ways); on a crop it changes nothing."""
    ctx.pocket_fill = {"rounds": 0, "cells": 0, "left": 0, "max_change_m": 0.0}
    if not is_full_map(ctx) or "checks" not in ctx.sketch:
        return
    original = ctx.layers["height"]
    ring = 1
    for _ in range(int(ctx.sketch["checks"].get("pocket_rounds", 8))):
        w = Walk(ctx)
        pocket = w.pockets()
        if not pocket.any():
            ctx.pocket_fill["left"] = 0
            break
        reached = w.main & w.walkable
        h, changed, left = fill(ctx.layers["height"], pocket, reached)
        if left:
            stuck = pocket & ~reach_grown(pocket, reached)
            region = (pocket | dilate(stuck, ring)) & ~reached & ~w.band
            h, more, left = fill(h, region, reached)
            changed += more
            ring *= 2
        ctx.pocket_fill["rounds"] += 1
        ctx.pocket_fill["cells"] += changed
        ctx.pocket_fill["left"] = left
        ctx.layers["height"] = h
    ctx.pocket_fill["max_change_m"] = float(np.abs(ctx.layers["height"] - original).max())


def reach_grown(pocket, reached):
    """Pocket cells joined to reached ground through other pocket cells."""
    out = np.zeros(pocket.shape, dtype=bool)
    front = reached.copy()
    while True:
        grown = np.zeros(pocket.shape, dtype=bool)
        for dj, di in _SHIFTS:
            grown |= _shift(front, dj, di, False)
        new = grown & pocket & ~out
        if not new.any():
            return out
        out |= new
        front = new


def footprint(ctx, p, deck=None):
    """Cells of a place: the flat cores of its lots, or the 3 x 3 samples
    around its point when it has none (only the deck cells among them when
    the point is on a bridge deck)."""
    from . import lots

    out = np.zeros(ctx.layers["height"].shape, dtype=bool)
    for lot in ctx.lots:
        if lot.get("poi") == p["id"]:
            win = lots._window_on(ctx.grid, ctx.x, ctx.z, lot)
            if win is not None:
                (rows, cols), d = win
                out[rows, cols] |= d == 0.0
    if not out.any():
        j, i = cell_of(ctx.grid, p["x"], p["z"])
        out[max(j - 1, 0) : j + 2, max(i - 1, 0) : i + 2] = True
        if deck is not None and deck[j, i]:
            out &= deck
    return out


def footprint_slope(surface, cells, sample_m):
    """Steepest slope in degrees between two neighbouring footprint cells."""
    e = np.abs(np.diff(surface, axis=1))[cells[:, :-1] & cells[:, 1:]]
    s = np.abs(np.diff(surface, axis=0))[cells[:-1, :] & cells[1:, :]]
    rise = max(e.max(initial=0.0), s.max(initial=0.0))
    return math.degrees(math.atan(rise / sample_m))


def report(ctx, walk=None):
    """(lines, failures) of T-05-5 on the run's field."""
    sk, ck, g = ctx.sketch, ctx.sketch["checks"], ctx.grid
    w = walk or Walk(ctx)
    lines, bad = [], 0

    def row(text, ok):
        nonlocal bad
        bad += not ok
        lines.append(f"  {text}{'' if ok else '  FAIL'}")

    lk = sk["lake"]
    limit = float(ck["poi_slope_deg"])
    for p in sk["pois"]:
        if geometry.ellipse_rho(p["x"], p["z"], lk["x"], lk["z"], lk["a"], lk["b"]) < 1.0:
            shore = geometry.ellipse_edge_distance(ctx.x, ctx.z, lk["x"], lk["z"], lk["a"], lk["b"]) < float(lk["shore_blend_m"])
            ok = bool((shore & w.main & w.walkable).any())
            row(f"place {p['id']:<22} on the lake: shore reachable {ok}", ok)
            continue
        cells = footprint(ctx, p, w.deck)
        dry = bool((w.depth[cells] == 0.0).all() and (w.surface[cells] >= float(sk.get("sea_level_y", 0.0))).all())
        slope = footprint_slope(w.surface, cells, g.sample_m)
        reached = bool(w.main[cell_of(g, p["x"], p["z"])])
        ok = dry and slope < limit and reached
        row(f"place {p['id']:<22} land {dry!s:<5} slope {slope:5.2f} deg (limit {limit:g}) reachable {reached}", ok)
    size, band = float(sk["size_m"]), float(ck["outer_band_m"])
    edge = {"north": ctx.z, "south": size - ctx.z, "west": ctx.x, "east": size - ctx.x}
    outer = np.zeros(ctx.x.shape, dtype=bool)
    for e in ck["outer_band_edges"]:
        outer |= edge[e] < band
    n_outer = int((outer & w.main).sum())
    row(f"outer {band:g} m band ({', '.join(ck['outer_band_edges'])}): {n_outer} reachable cells", n_outer == 0)
    pocket = w.pockets()
    n = int(len(np.unique(w.labels[pocket])))
    row(f"walkable pockets outside the boundary band: {n} ({int(pocket.sum())} cells)", n == 0)
    return lines, bad


def pois_document(ctx):
    """The place file (04 §2): every place of the table with its final
    height: the ground, a bridge deck, or the water surface where it lies in
    water."""
    surface, depth, _ = walk_surface(ctx)
    top = surface + depth
    out = []
    for p in ctx.sketch["pois"]:
        j, i = cell_of(ctx.grid, p["x"], p["z"])
        out.append({"id": p["id"], "x": p["x"], "z": p["z"], "y": round(float(top[j, i]), 3), "region": p.get("region", "")})
    return {"pois": out}
