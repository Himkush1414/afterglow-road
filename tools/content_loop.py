#!/usr/bin/env python3
"""Content loop check (T-27-1): reads a content tree and checks the rules the
core loop rests on. Every id, rule and number comes from the content itself
(`data/tuning.json` group `loop` and the system groups it names), so this
file holds no game data.

  python3 tools/content_loop.py <content dir>

Rules:
  snare     one snare set alone covers a share of the reference day's hunger
            inside [share_min, share_max];
  travel    the shortest way along `world/roads.json` between two places of
            `world/pois.json`, at a jog, takes more than gh_min and less than
            gh_max game hours;
  beacon    what must be carried up for the beacon fits in trips_max loads;
  recover   every listed capability can be made again from renewable or
            abundant sources, and the listed ones from renewable sources.
Prints one line per rule and LOOP CHECK: PASS / FAIL / SKIPPED; exit 1 on
FAIL. SKIPPED (exit 0) when the tuning has no `loop` group.
"""
import heapq
import json
import math
import pathlib
import sys


def load(root):
    data = root / "data"

    def read(name, key):
        with (data / name).open(encoding="utf-8") as f:
            return json.load(f)[key]

    with (data / "tuning.json").open(encoding="utf-8") as f:
        tuning = json.load(f)
    items_doc = json.loads((data / "items.json").read_text(encoding="utf-8"))
    return {
        "tuning": tuning,
        "items": {i["id"]: i for i in items_doc["items"]},
        "units": {u["id"]: u for u in items_doc.get("units", [])},
        "recipes": read("recipes.json", "recipes"),
        "pieces": {p["id"]: p for p in read("build_pieces.json", "pieces")},
        "nodes": read("nodes.json", "nodes"),
        "trees": {t["id"]: t for t in read("trees.json", "trees")},
        "animals": {a["id"]: a for a in read("animals.json", "animals")},
        "root": root,
    }


def effect(c, item_id):
    e = (c["items"].get(item_id) or c["units"].get(item_id) or {}).get("effect") or {}
    return e


def daily_hunger(c):
    v, day = c["tuning"]["vitals"], c["tuning"]["loop"]["reference_day_gh"]
    calm = day["awake"] - day["working"] - day["sprinting"]
    active = calm + day["working"] * v["drain_working_mult"] + day["sprinting"] * v["drain_sprinting_mult"]
    return v["hunger_per_gh"] * (active + day["asleep"] * v["drain_asleep_mult"])


def hours_per_day(animal):
    n = 0
    for h in animal["active_hours"]:
        span = (h["to"] - h["from"]) % 24
        n += span if span else 24
    return n


def snare_share(c):
    s = c["tuning"]["loop"]["snare"]
    a = c["animals"][s["animal"]]
    qty = sum(d["qty"] * d["chance"] for d in a["drops"] if d["item"] == s["drop"])
    catches = hours_per_day(a) * c["tuning"]["gathering"]["snare_chance"]
    return catches * qty * effect(c, s["food"])["hunger"] / daily_hunger(c)


def way_graph(ways, join_m):
    """Vertices (x, z) and adjacency {i: [(j, metres)]}: consecutive points of
    a way, and each way's end joined to the nearest vertex of another way
    within join_m."""
    pts, adj, spans = [], {}, []
    for w in ways:
        first = len(pts)
        for p in w["points"]:
            adj[len(pts)] = []
            pts.append((float(p[0]), float(p[1])))
        for i in range(first, len(pts) - 1):
            d = math.dist(pts[i], pts[i + 1])
            adj[i].append((i + 1, d))
            adj[i + 1].append((i, d))
        spans.append((first, len(pts)))
    for a, b in spans:
        for end in (a, b - 1):
            best = None
            for c0, c1 in spans:
                if (c0, c1) == (a, b):
                    continue
                for j in range(c0, c1):
                    d = math.dist(pts[end], pts[j])
                    if d <= join_m and (best is None or d < best[1]):
                        best = (j, d)
            if best:
                adj[end].append(best)
                adj[best[0]].append((end, best[1]))
    return pts, adj


def shortest(pts, adj, start, goal):
    """Metres along the graph between the vertices nearest to two points,
    plus the straight steps from the points to those vertices."""
    s = min(range(len(pts)), key=lambda i: math.dist(pts[i], start))
    g = min(range(len(pts)), key=lambda i: math.dist(pts[i], goal))
    dist, todo = {s: 0.0}, [(0.0, s)]
    while todo:
        d, i = heapq.heappop(todo)
        if i == g:
            return d + math.dist(pts[s], start) + math.dist(pts[g], goal)
        if d > dist[i]:
            continue
        for j, w in adj[i]:
            if d + w < dist.get(j, math.inf):
                dist[j] = d + w
                heapq.heappush(todo, (d + w, j))
    return math.inf


def travel(c):
    t = c["tuning"]["loop"]["travel"]
    world = c["root"] / "world"
    ways = json.loads((world / "roads.json").read_text(encoding="ascii"))["ways"]
    pois = {p["id"]: p for p in json.loads((world / "pois.json").read_text(encoding="ascii"))["pois"]}
    pts, adj = way_graph(ways, t["join_m"])
    a, b = pois[t["from"]], pois[t["to"]]
    metres = shortest(pts, adj, (a["x"], a["z"]), (b["x"], b["z"]))
    gh = metres / c["tuning"]["movement"]["jog_ms"] / c["tuning"]["clock"]["gmin_real_s"] / 60.0
    return metres, gh


def beacon(c):
    """(kg to carry, loads, missing logs) for the beacon."""
    b = c["tuning"]["loop"]["beacon"]
    need = {}
    for slot in c["pieces"][b["piece"]]["cost"]:
        need[slot[0]["item"]] = need.get(slot[0]["item"], 0) + slot[0]["qty"]
    rec = next(r for r in c["recipes"] if r["id"] == b["concrete_recipe"])
    batches = math.ceil(need.pop(rec["output"], 0) / rec["qty"])
    for slot in rec["inputs"]:
        need[slot[0]["item"]] = need.get(slot[0]["item"], 0) + slot[0]["qty"] * batches
    have = {e["item"]: e["qty"] for e in b["at_summit"]}
    for e in b["summit_trees"]:
        have["log"] = have.get("log", 0) + e["count"] * c["trees"][e["tree"]]["logs"]
    kg, short = 0.0, {}
    for item, n in need.items():
        bring = max(0, n - have.get(item, 0))
        if item in b["on_hand"] or not bring:
            continue
        if item in b["carried_alone"]:
            short[item] = bring
            continue
        kg += bring * c["items"][item]["weight_kg"]
    return kg, math.ceil(kg / c["tuning"]["inventory"]["backpack_kg"]), short


def sources(c):
    """(renewable, abundant) item ids."""
    r = c["tuning"]["loop"]["recover"]
    renew = set(r["base"])
    for n in c["nodes"]:
        if n["respawn_gdays"]:
            renew |= {d["item"] for d in n["drops"]}
    for t in c["trees"].values():
        renew |= {d["item"] for d in t["extra_drops"]}
        if t["harvest_no_fell"]:
            renew.add(t["harvest_no_fell"]["item"])
    for a in c["animals"].values():
        renew |= {d["item"] for d in a["drops"]}
    abundant = set()
    for n in c["nodes"]:
        if not n["respawn_gdays"] and (n["world_count"] or 0) >= r["abundant_min_count"]:
            abundant |= {d["item"] for d in n["drops"]}
    return renew, abundant - renew


def closure(c, base):
    """(items, stations) that can be made from the base items."""
    r = c["tuning"]["loop"]["recover"]
    needs = {e["station"]: set(e["any_of"]) for e in r["station_needs"]}
    gives = {e["station"]: e["items"] for e in r["station_gives"]}
    tools = {}
    for i in c["items"].values():
        if i["tool"]:
            tools.setdefault(i["tool"]["class"], set()).add(i["id"])

    def can_pay(slots, have):
        return all(any(o["item"] in have for o in slot) for slot in slots)

    def has_tool(classes, have):
        return not classes or any(tools.get(t, set()) & have for t in classes)

    have, stations = set(base), {"hand"}
    changed = True
    while changed:
        changed = False
        for pid, p in c["pieces"].items():
            if pid not in stations and can_pay(p["cost"], have) and has_tool([p["tool_class"]] if p["tool_class"] else [], have):
                stations.add(pid)
                changed = True
        for rec in c["recipes"]:
            if rec["output"] in have or rec["station"] not in stations:
                continue
            if not can_pay(rec["inputs"], have) or not has_tool(rec["tool_class"], have):
                continue
            if rec["station"] in needs and not needs[rec["station"]] & have:
                continue
            have.add(rec["output"])
            have |= {b["item"] for b in rec["byproducts"]}
            changed = True
        for st, out in gives.items():
            if st in stations and not set(out) <= have:
                have |= set(out)
                changed = True
    return have, stations


def recover(c):
    """[(id, class)] for every essential entry: renewable, abundant or none."""
    r = c["tuning"]["loop"]["recover"]
    renew, abundant = sources(c)
    have_r, st_r = closure(c, renew)
    have_a, st_a = closure(c, renew | abundant)
    out = []
    for e in r["essential"]:
        pool_r, pool_a = (have_r, have_a) if e["kind"] == "item" else (st_r, st_a)
        out.append((e["id"], "renewable" if e["id"] in pool_r else "abundant" if e["id"] in pool_a else "none"))
    return out


def check(root):
    """(lines, failures); failures is None when the loop is not configured."""
    c = load(root)
    if "loop" not in c["tuning"]:
        return ["  no loop group in tuning.json"], None
    lp = c["tuning"]["loop"]
    lines, bad = [], 0

    def row(text, ok):
        nonlocal bad
        bad += not ok
        lines.append(f"  {text}{'' if ok else '  FAIL'}")

    s = lp["snare"]
    share = snare_share(c)
    row(f"snare: one snare alone covers {share:.0%} of a day's hunger ({daily_hunger(c):.1f}; band {s['share_min']:.0%}-{s['share_max']:.0%})", s["share_min"] <= share <= s["share_max"])
    t = lp["travel"]
    metres, gh = travel(c)
    row(f"travel: {t['from']} -> {t['to']} {metres:,.0f} m = {gh:.1f} gh at a jog (band {t['gh_min']}-{t['gh_max']})", t["gh_min"] < gh < t["gh_max"])
    kg, loads, short = beacon(c)
    row(f"beacon: {kg:.0f} kg to carry = {loads} load(s) (limit {lp['beacon']['trips_max']}); not covered at the summit: {short or 'nothing'}", loads <= lp["beacon"]["trips_max"] and not short)
    must = set(lp["recover"]["renewable"])
    for pid, cls in recover(c):
        ok = cls == "renewable" if pid in must else cls != "none"
        row(f"recover: {pid:<18} {cls}", ok)
    return lines, bad


def main():
    if len(sys.argv) != 2:
        print("usage: content_loop.py <content dir>", file=sys.stderr)
        return 2
    lines, bad = check(pathlib.Path(sys.argv[1]))
    for line in lines:
        print(line)
    if bad is None:
        print("LOOP CHECK: SKIPPED (not configured)")
        return 0
    print(f"LOOP CHECK: {'FAIL' if bad else 'PASS'} ({bad} failures)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
