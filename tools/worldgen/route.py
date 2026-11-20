"""Track routing (stage 9): A* on a coarse grid under a grade limit, from
each place that needs a track to the nearest point of the road."""
import heapq
import json
import math

import numpy as np

from . import geometry
from .grid import Grid
from .pipeline import run

MOVES = [(dz, dx) for dx in (-2, -1, 0, 1, 2) for dz in (-2, -1, 0, 1, 2) if (dx, dz) != (0, 0) and math.gcd(abs(dx), abs(dz)) == 1]
_TERRAIN = {}


def terrain(sk, seed, with_noise, cell):
    """Stages 1-6 on the full map at `cell` spacing (cached per input)."""
    key = (seed, with_noise, cell, json.dumps(sk, sort_keys=True, default=str))
    if key not in _TERRAIN:
        g = Grid.full(sk["size_m"], cell)
        _TERRAIN.clear()
        _TERRAIN[key] = (g, run(sk, g, seed, until="lake", noise=with_noise).layers["height"])
    return _TERRAIN[key]


def astar(h, cell, start, goal, target_pts, gmax, turn_cost_m):
    """Cheapest cell path (list of (row, col)) from start to any goal cell, or
    None. A move is allowed when |dh| / length <= gmax; cost = length +
    (1 - cos turn)^2 * turn_cost_m; heuristic = distance to the nearest target."""
    nz, nx = h.shape
    tx, tz = np.asarray(target_pts, dtype=np.float64).T

    def heur(r, c):
        return float(np.min(np.hypot(tx - c * cell, tz - r * cell)))

    best = {}
    came = {}
    openq = [(heur(*start), 0.0, start, -1)]
    while openq:
        _, g, cur, mv = heapq.heappop(openq)
        if best.get((cur, mv), math.inf) < g:
            continue
        if goal[cur]:
            path, state = [cur], (cur, mv)
            while state in came:
                state = came[state]
                path.append(state[0])
            return path[::-1]
        r, c = cur
        for k, (dz, dx) in enumerate(MOVES):
            r2, c2 = r + dz, c + dx
            if not (0 <= r2 < nz and 0 <= c2 < nx):
                continue
            length = math.hypot(dx, dz) * cell
            if abs(h[r2, c2] - h[r, c]) > gmax * length:
                continue
            if max(abs(dx), abs(dz)) == 2:
                # a two-cell move passes between two cells: check both halves
                # against their mean, so it cannot jump a one-cell step
                mr, mc = r + dz / 2.0, c + dx / 2.0
                mid = 0.5 * (h[math.floor(mr), math.floor(mc)] + h[math.ceil(mr), math.ceil(mc)])
                if max(abs(mid - h[r, c]), abs(h[r2, c2] - mid)) > gmax * length / 2.0:
                    continue
            turn = 0.0
            if mv >= 0:
                pz, px = MOVES[mv]
                cosang = (dx * px + dz * pz) / (math.hypot(dx, dz) * math.hypot(px, pz))
                turn = (1.0 - cosang) ** 2 * turn_cost_m
            g2 = g + length + turn
            state = ((r2, c2), k)
            if g2 < best.get(state, math.inf):
                best[state] = g2
                came[state] = (cur, mv)
                heapq.heappush(openq, (g2 + heur(r2, c2), g2, (r2, c2), k))
    return None


def simplify(pts, eps):
    """Ramer-Douglas-Peucker."""
    pts = [tuple(p) for p in pts]
    if len(pts) < 3:
        return pts
    (ax, az), (bx, bz) = pts[0], pts[-1]
    length = math.hypot(bx - ax, bz - az) or 1e-9
    dist = [abs((bx - ax) * (az - pz) - (ax - px) * (bz - az)) / length for px, pz in pts[1:-1]]
    k = int(np.argmax(dist)) + 1
    if dist[k - 1] <= eps:
        return [pts[0], pts[-1]]
    return simplify(pts[: k + 1], eps)[:-1] + simplify(pts[k:], eps)


def routed_tracks(sk, seed, with_noise):
    """(track lines, ids of places without a route under the limit)."""
    tr, rt = sk.get("tracks", {}), sk.get("routing", {})
    words = tr.get("route_to", [])
    road = [geometry.catmull_rom(ln["points"]) for ln in sk.get("lines", []) if ln["kind"] == "road"]
    if not words or not road:
        return [], []
    road_pts = np.vstack(road)
    ends = [ln["points"][-1] for ln in sk["lines"] if ln["kind"] == "track"]
    cell = float(rt["cell_m"])
    g, h = terrain(sk, seed, with_noise, cell)
    goal = np.zeros(h.shape, dtype=bool)
    for line in road:
        goal |= geometry.polyline_distance(g, line, cell) < cell
    lines, failed = [], []
    for p in sk.get("pois", []):
        if not any(w in p["id"] for w in words):
            continue
        if any(math.hypot(p["x"] - ex, p["z"] - ez) < cell for ex, ez in ends):
            continue
        start = (int(round(p["z"] / cell)), int(round(p["x"] / cell)))
        path = astar(h, cell, start, goal, road_pts, float(tr["max_grade"]), float(rt["turn_cost_m"]))
        if path is None:
            failed.append(p["id"])
            continue
        pts = [(c * cell, r * cell) for r, c in reversed(path)]
        k = int(np.argmin(np.hypot(road_pts[:, 0] - pts[0][0], road_pts[:, 1] - pts[0][1])))
        pts[0] = (float(road_pts[k, 0]), float(road_pts[k, 1]))
        pts[-1] = (float(p["x"]), float(p["z"]))
        lines.append(
            {
                "id": "track_" + p["id"],
                "kind": "track",
                "width_m": float(tr["width_m"]),
                "routed": True,
                "points": [list(q) for q in simplify(pts, cell)],
            }
        )
    return lines, failed
