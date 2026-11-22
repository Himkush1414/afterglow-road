#!/usr/bin/env bash
# Test for tools/content_loop.py with a made-up content tree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT
python3 - "${here}/../../tools" "${sandbox}" <<'PY'
import copy, json, os, pathlib, sys
sys.path.insert(0, sys.argv[1])
import content_loop

root = pathlib.Path(sys.argv[2])
def item(i, w=1.0, tool=None, hunger=None):
    return {"id": i, "weight_kg": w, "tool": {"class": tool} if tool else None, "effect": {"hunger": hunger} if hunger else None}
def slot(*opts):
    return [{"item": o, "qty": q} for o, q in opts]
def recipe(i, out, station="hand", inputs=(), tools=(), qty=1, by=()):
    return {"id": i, "output": out, "qty": qty, "station": station, "tool_class": list(tools), "inputs": [slot(x) for x in inputs], "byproducts": [{"item": b, "qty": 1} for b in by]}
BASE = {
    "items.json": {"items": [item("twig", 0.1), item("rock", 1.0), item("blade", 0.3, "cut"), item("meat", 0.5), item("stew", 0.5, hunger=40), item("ore", 2.0), item("bar", 2.0), item("ash", 0.1)], "units": [{"id": "water", "effect": None}, {"id": "mix", "effect": None}]},
    "recipes.json": {"recipes": [recipe("r_blade", "blade", inputs=[("rock", 1), ("twig", 1)]), recipe("r_stew", "stew", "fire", [("meat", 1)]), recipe("r_bar", "bar", "oven", [("ore", 1)]), recipe("r_mix", "mix", "fire", [("rock", 1), ("water", 1)], qty=2)]},
    "build_pieces.json": {"pieces": [{"id": "fire", "cost": [slot(("rock", 3))], "tool_class": ""}, {"id": "oven", "cost": [slot(("rock", 5))], "tool_class": "cut"}, {"id": "tower", "cost": [slot(("mix", 4)), slot(("bar", 2))], "tool_class": ""}]},
    "nodes.json": {"nodes": [{"id": "lode", "drops": [{"item": "ore", "qty": 1, "chance": 1}], "world_count": 500, "respawn_gdays": 0}]},
    "trees.json": {"trees": [{"id": "dead", "logs": 2, "extra_drops": [], "harvest_no_fell": None}]},
    "animals.json": {"animals": [{"id": "hopper", "active_hours": [{"from": 22, "to": 4}], "drops": [{"item": "meat", "qty": 2, "chance": 1}]}]},
    "tuning.json": {
        "clock": {"gmin_real_s": 2.0}, "vitals": {"hunger_per_gh": 3.0, "drain_working_mult": 1.0, "drain_sprinting_mult": 1.0, "drain_asleep_mult": 1.0},
        "gathering": {"snare_chance": 0.1}, "movement": {"jog_ms": 4.0}, "inventory": {"backpack_kg": 10},
        "loop": {
            "reference_day_gh": {"awake": 16, "asleep": 8, "working": 0, "sprinting": 0},
            "snare": {"animal": "hopper", "drop": "meat", "food": "stew", "share_min": 0.5, "share_max": 1.0},
            "travel": {"from": "home", "to": "top", "gh_min": 30, "gh_max": 60, "join_m": 5},
            "beacon": {"piece": "tower", "concrete_recipe": "r_mix", "at_summit": [{"item": "bar", "qty": 1}], "summit_trees": [], "on_hand": ["water"], "carried_alone": [], "trips_max": 1},
            "recover": {"base": ["twig", "rock", "water"], "abundant_min_count": 100, "station_needs": [{"station": "oven", "any_of": ["ash"]}], "station_gives": [{"station": "fire", "items": ["ash"]}],
                        "essential": [{"id": "blade", "kind": "item"}, {"id": "fire", "kind": "piece"}, {"id": "bar", "kind": "item"}], "renewable": ["blade"]},
        },
    },
}
# A road of 30 km in 1 km steps and a track joining it 3 m away from its 10 km point.
ROADS = {"ways": [{"id": "r", "points": [[float(i * 1000), 0.0] for i in range(31)]}, {"id": "t", "points": [[10000.0, 3.0], [10000.0, 500.0]]}]}
POIS = {"pois": [{"id": "home", "x": 10000.0, "z": 500.0}, {"id": "top", "x": 30000.0, "z": 0.0}]}

def write(data):
    for d in ("data", "world"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for name, doc in data.items():
        (root / "data" / name).write_text(json.dumps(doc))
    (root / "world" / "roads.json").write_text(json.dumps(ROADS))
    (root / "world" / "pois.json").write_text(json.dumps(POIS))
    return content_loop.check(root)

failures = 0
def expect(name, cond, lines):
    global failures
    print(("  ok    " if cond else "  FAIL  ") + name)
    if not cond:
        print("\n".join(lines)); failures += 1

lines, bad = write(BASE)
expect("made-up content passes", bad == 0, lines)
expect("snare share: 6 h x 0.1 x 2 x 40 / 72 = 67%", "67%" in lines[0], lines)
expect("travel: 497 m track + 3 m join + 20 km road = 42.7 gh", "20,500 m = 42.7 gh" in lines[1], lines)
expect("beacon: 2 batches (2 rock) + 1 bar to bring = 4 kg", "4 kg" in lines[2], lines)
expect("ore is abundant, so the bar is", any("bar" in l and "abundant" in l for l in lines), lines)

def variant(path, value):
    d = copy.deepcopy(BASE)
    node = d
    for k in path[:-1]:
        node = node[k]
    node[path[-1]] = value
    return write(d)

lines, bad = variant(("tuning.json", "gathering", "snare_chance"), 0.01)
expect("too few catches fail", bad == 1 and "FAIL" in lines[0], lines)
lines, bad = variant(("tuning.json", "movement", "jog_ms"), 1.0)
expect("a slow climb fails", bad == 1 and "FAIL" in lines[1], lines)
lines, bad = variant(("tuning.json", "inventory", "backpack_kg"), 3)
expect("a load over the backpack fails", bad == 1 and "FAIL" in lines[2], lines)
lines, bad = variant(("tuning.json", "loop", "recover", "station_gives"), [])
expect("without ash the oven bar is lost", bad == 1 and any("bar" in l and "none" in l and "FAIL" in l for l in lines), lines)
lines, bad = variant(("tuning.json", "loop", "recover", "renewable"), ["blade", "bar"])
expect("a must-be-renewable item from a finite source fails", bad == 1 and any("bar" in l and "FAIL" in l for l in lines), lines)
d = copy.deepcopy(BASE); del d["tuning.json"]["loop"]
expect("no loop group is skipped", write(d)[1] is None, [])
sys.exit(1 if failures else 0)
PY
echo "all passed"
