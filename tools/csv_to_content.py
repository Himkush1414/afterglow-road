#!/usr/bin/env python3
"""Convert content tables (CSV) into the game's JSON data files.

Usage: csv_to_content.py <csv dir> <output data dir>

Writes materials.json and items.json (effect rows of ids that are not
items become `fluids` there); other files in the output folder are
left alone. Columns map 1:1 to JSON fields except where a rule below says
otherwise. Exit code 1 with one line per problem when a table is invalid.
"""
import csv
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


def items(rows, effects, tool_classes, pieces, problems):
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
    # Effect rows of ids that are not items are fluids (04 §1.2 pseudo-items).
    fluids = []
    for fid in sorted(set(by_effect) - {r["id"] for r in rows}):
        e = by_effect[fid]
        effect = {k: v if k in EFFECT_TEXT else number(v, f"item_effects.csv {fid} {k}", problems) for k, v in e.items() if k != "id" and v != ""}
        fluids.append({"id": fid, "effect": effect})
    return {"items": out, "fluids": fluids}


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
                problems,
            ),
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
