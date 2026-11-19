#!/usr/bin/env python3
"""Convert content tables (CSV) into the game's JSON data files.

Usage: csv_to_content.py <csv dir> <output data dir>

Writes materials.json, items.json (with the pseudo-items of units.csv as
`units`), build_pieces.json, recipes.json, trees.json, nodes.json and loot.json; other files in the output folder are
left alone. Columns map 1:1 to JSON fields except where a rule below says
otherwise. Exit code 1 with one line per problem when a table is invalid.
"""
import csv
import re
import json
import pathlib
import sys

TOOL_CLASSES = "tool_classes.csv"
EFFECT_TEXT = {"kind", "slot"}


class Problems(Exception):
    pass


def read(csv_dir, name, required=True):
    path = csv_dir / name
    if not path.exists():
        if required:
            raise Problems([f"{name}: file not found"])
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def number(value, where, problems):
    try:
        v = float(value)
    except ValueError:
        problems.append(f"{where}: '{value}' is not a number")
        return 0
    return int(v) if v.is_integer() else v


def materials(rows, problems):
    out = []
    for i, r in enumerate(rows, 2):
        m = {"id": r["id"]}
        for key, value in r.items():
            if key == "id":
                continue
            where = f"materials.csv:{i} {key}"
            if key == "flammable":
                if value not in ("0", "1"):
                    problems.append(f"{where}: expected 0 or 1")
                m[key] = value == "1"
            elif key in ("footstep", "impact_sound", "hit_particles"):
                m[key] = value
            else:
                m[key] = number(value, where, problems)
        out.append(m)
    return {"materials": out}


def held_pose(r, tool):
    # Rule of Q-32: the pose follows the tool class, category and hold.
    if tool and tool["class"] == "light":
        return "torch"
    if r["category"] == "container":
        return "container"
    if tool:
        return "tool_2h" if r["hold"] == "2h" else "tool_1h"
    if r["hold"] == "carry":
        return "carry_shoulder"
    if r["hold"] == "2h":
        return "carry_front"
    return "small_1h"


def placed_pieces(pieces):
    """item id -> piece id, for pieces whose whole cost is one such item."""
    out = {}
    for p in pieces:
        parts = p.get("cost", "").split(":")
        if len(parts) == 2 and parts[1] == "1" and "|" not in p["cost"]:
            out[parts[0]] = p["id"]
    return out


def items(rows, effects, tool_classes, pieces, units, problems):
    by_effect = {e["id"]: e for e in effects}
    swing = {t["class"]: t for t in tool_classes}
    placed = placed_pieces(pieces)
    out = []
    for i, r in enumerate(rows, 2):
        where = f"items.csv:{i}"
        tool = None
        if r["tool_class"]:
            t = swing.get(r["tool_class"], {})
            tool = {
                "class": r["tool_class"],
                "tier": number(r["tier"] or "0", f"{where} tier", problems),
                "power": number(r["power"] or "0", f"{where} power", problems),
                "durability": number(r["durability"] or "0", f"{where} durability", problems),
                "swing_s": number(t.get("swing_s") or "0", f"{TOOL_CLASSES} swing_s", problems),
                "stamina": number(t.get("stamina") or "0", f"{TOOL_CLASSES} stamina", problems),
            }
        fuel = None
        if r["fuel_class"]:
            fuel = {"gmin": number(r["fuel_gmin"], f"{where} fuel_gmin", problems), "class": r["fuel_class"]}
        effect = None
        if r["id"] in by_effect:
            effect = {}
            for key, value in by_effect[r["id"]].items():
                if key == "id" or value == "":
                    continue
                effect[key] = value if key in EFFECT_TEXT else number(value, f"item_effects.csv {r['id']} {key}", problems)
        place = None
        if r["category"] == "placeable" and r["id"] in placed:
            place = {"piece": placed[r["id"]]}
        out.append(
            {
                "id": r["id"],
                "name_key": f"item.{r['id']}",
                "category": r["category"],
                "stack": number(r["stack"], f"{where} stack", problems),
                "weight_kg": number(r["weight_kg"], f"{where} weight_kg", problems),
                "material": r["material"],
                "hold": r["hold"],
                "tool": tool,
                "fuel": fuel,
                "effect": effect,
                "place": place,
                "world_scene": "",
                "icon": "",
                "held_pose": held_pose(r, tool),
            }
        )
    # Pseudo-items (fluids and units, 04 §1.2) are listed in units.csv.
    item_ids = {r["id"] for r in rows}
    unit_list = []
    for u in units:
        e = by_effect.get(u["id"])
        effect = None
        if e:
            effect = {k: v if k in EFFECT_TEXT else number(v, f"item_effects.csv {u['id']} {k}", problems) for k, v in e.items() if k != "id" and v != ""}
        unit_list.append({"id": u["id"], "effect": effect})
    known = item_ids | {u["id"] for u in units}
    problems.extend(f"item_effects.csv: '{x}' is neither an item nor a unit" for x in sorted(set(by_effect) - known))
    return {"items": out, "units": unit_list}


def cost(text, where, problems):
    """'a:1|b/c:2|d:1/e:4' -> [[{item, qty}], [{b,2},{c,2}], [{d,1},{e,4}]] (04 §1.2)."""
    slots = []
    for slot in text.split("|"):
        options = []
        trailing = slot.rsplit(":", 1)[1] if ":" in slot else None
        for opt in slot.split("/"):
            item, _, qty = opt.partition(":")
            qty = qty or trailing
            if not item or qty is None:
                problems.append(f"{where}: '{slot}' needs item:qty")
                continue
            options.append({"item": item, "qty": number(qty, where, problems)})
        slots.append(options)
    return slots


BYPRODUCT = re.compile(r"also gives (\w+):(\d+)")


def recipes(rows, problems):
    out = []
    for i, r in enumerate(rows, 2):
        where = f"recipes.csv:{i}"
        out.append(
            {
                "id": r["id"],
                "output": r["output"],
                "qty": number(r["qty"], f"{where} qty", problems),
                "station": r["station"],
                "tool_class": [t for t in r["tool_class"].split("/") if t],
                "inputs": cost(r["inputs"], f"{where} inputs", problems),
                "time": number(r["time"], f"{where} time", problems),
                "time_unit": r["time_unit"],
                # Q-34: "a+b" in the table = either unlocks.
                "unlock": [u for part in r["unlock"].split("|") for u in part.split("+") if u],
                "byproducts": [{"item": m[0], "qty": int(m[1])} for m in BYPRODUCT.findall(r["notes"])],
            }
        )
    return {"recipes": out}


DROP = re.compile(r"^(\w+):(\d+)(?:@([\w.]+))?$")
HARVEST = re.compile(r"^(\w+):(\d+) \((\w+); (?:cooldown|regrow) ([\d.]+) gdays\)$")


def drops(text, where, problems):
    """'a:4|b:1@0.4|c:1@dry' -> [{item, qty, chance, condition}] (Q-35)."""
    out = []
    for part in filter(None, text.split("|")):
        m = DROP.match(part)
        if not m:
            problems.append(f"{where}: '{part}' is not item:qty[@chance|@condition]")
            continue
        tag = m[3] or ""
        is_chance = tag.replace(".", "", 1).isdigit()
        out.append(
            {
                "item": m[1],
                "qty": int(m[2]),
                "chance": number(tag, where, problems) if is_chance else 1,
                "condition": "" if is_chance else tag,
            }
        )
    return out


def harvest(text, where, problems):
    if not text:
        return None
    m = HARVEST.match(text)
    if not m:
        problems.append(f"{where}: '{text}' is not 'item:qty (tool; cooldown N gdays)'")
        return None
    tool = "hand" if m[3] == "hands" else m[3]
    return {"item": m[1], "qty": int(m[2]), "tool": tool, "cooldown_gday": number(m[4], where, problems)}


def trees(rows, problems):
    out = []
    for i, r in enumerate(rows, 2):
        where = f"trees.csv:{i}"
        t = {"id": r["id"], "name_key": f"tree.{r['id']}", "species": r["species"], "size": r["size"]}
        for key in ("height_m", "trunk_r_m", "canopy_r_m", "hp", "logs", "poles", "sticks"):
            t[key] = number(r[key], f"{where} {key}", problems)
        t["extra_drops"] = drops(r["extra_drops"], f"{where} extra_drops", problems)
        t["variants"] = number(r["variants"], f"{where} variants", problems)
        t["harvest_no_fell"] = harvest(r["harvest_no_fell"], f"{where} harvest_no_fell", problems)
        t["models"] = []
        out.append(t)
    return {"trees": out}


def nodes(rows, problems):
    out = []
    for i, r in enumerate(rows, 2):
        where = f"nodes.csv:{i}"
        out.append(
            {
                "id": r["id"],
                "name_key": f"node.{r['id']}",
                "tool_class": r["tool_class"],
                "min_tier": number(r["min_tier"], f"{where} min_tier", problems),
                "hp": number(r["hp"], f"{where} hp", problems),
                "drops": drops(r["drops"], f"{where} drops", problems),
                "biomes": [b for b in r["biomes"].split(";") if b],
                # Q-35: "runtime" = placed at run time, not by the generator.
                "world_count": None if r["world_count"] == "runtime" else number(r["world_count"], f"{where} world_count", problems),
                "respawn_gdays": number(r["respawn_gdays"], f"{where} respawn_gdays", problems),
                "scene": "",
            }
        )
    return {"nodes": out}


def loot(rows, problems):
    """'item:weight:min-max|nothing:20:0-0' per table (04 §1.4)."""
    out = []
    for i, r in enumerate(rows, 2):
        where = f"loot.csv:{i}"
        entries = []
        for part in r["entries"].split("|"):
            fields = part.split(":")
            span = fields[2].split("-") if len(fields) == 3 else []
            if len(span) != 2:
                problems.append(f"{where}: '{part}' is not item:weight:min-max")
                continue
            entries.append(
                {
                    "item": fields[0],
                    "weight": number(fields[1], where, problems),
                    "min": number(span[0], where, problems),
                    "max": number(span[1], where, problems),
                }
            )
            if entries[-1]["min"] > entries[-1]["max"]:
                problems.append(f"{where}: '{part}' has min above max")
        out.append({"id": r["table"], "rolls": number(r["rolls"], f"{where} rolls", problems), "entries": entries})
    return {"tables": out}


SLOTS_RAIN = {"cell_floor", "cell_roof", "cell_stairs"}
SLOTS_WIND = {"edge", "door", "window", "corner"}


def pieces(rows, problems):
    out = []
    for i, r in enumerate(rows, 2):
        where = f"build_pieces.csv:{i}"
        size = r["size_m"].split("x")
        if len(size) != 3:
            problems.append(f"{where} size_m: expected AxBxC")
        out.append(
            {
                "id": r["id"],
                "name_key": f"piece.{r['id']}",
                "category": r["category"],
                "tier": number(r["tier"], f"{where} tier", problems),
                "slot": r["slot"],
                "size_m": [number(v, f"{where} size_m", problems) for v in size],
                "cost": cost(r["cost"], f"{where} cost", problems),
                "tool_class": r["tool_class"],
                "hp": number(r["hp"], f"{where} hp", problems),
                "support_base": number(r["support_base"], f"{where} support_base", problems) if r["support_base"] else None,
                "support_v": number(r["support_v"], f"{where} support_v", problems) if r["support_v"] else None,
                "support_h": number(r["support_h"], f"{where} support_h", problems) if r["support_h"] else None,
                "flammable": r["flammable"] == "1",
                "stages": number(r["stages"], f"{where} stages", problems),
                # Q-33: whether the piece takes part in the shelter rays.
                "blocks_wind": r["slot"] in SLOTS_WIND,
                "blocks_rain": r["slot"] in SLOTS_RAIN,
                "scene": "",
                "ghost_scene": "",
            }
        )
    return {"pieces": out}


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    csv_dir, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    problems = []
    try:
        outputs = {
            "materials.json": materials(read(csv_dir, "materials.csv"), problems),
            "items.json": items(
                read(csv_dir, "items.csv"),
                read(csv_dir, "item_effects.csv", required=False),
                read(csv_dir, TOOL_CLASSES, required=False),
                read(csv_dir, "build_pieces.csv", required=False),
                read(csv_dir, "units.csv", required=False),
                problems,
            ),
            "build_pieces.json": pieces(read(csv_dir, "build_pieces.csv"), problems),
            "recipes.json": recipes(read(csv_dir, "recipes.csv"), problems),
            "trees.json": trees(read(csv_dir, "trees.csv"), problems),
            "nodes.json": nodes(read(csv_dir, "nodes.csv"), problems),
            "loot.json": loot(read(csv_dir, "loot.csv"), problems),
        }
    except Problems as e:
        problems = e.args[0]
    if problems:
        for p in problems:
            print(p, file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, data in outputs.items():
        with (out_dir / name).open("w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent="\t", ensure_ascii=False)
            f.write("\n")
        print(f"wrote {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
