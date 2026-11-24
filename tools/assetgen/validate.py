"""Asset validator for one content tree (22 §7):

  python3 -m tools.assetgen.validate <content dir under game/> [--no-engine]

T-22-3 (tree models), file side: every model the tree preset
(<content>/assetgen/trees.json) asks for exists for each variant of its
tree definition (<content>/data/trees.json); every
<content>/assets/models/trees/tree_*.glb has the meshes _t0, _t1 and _t2,
each within the triangle budget of its size (T-22-2) and with a bark and a
leaves surface (bark only when the model's shape preset has no clumps) that all
carry RGBA vertex colours (COLOR_0, VEC4).
Engine side (unless --no-engine): the imported models are checked headless
by res://src/tools/check_tree_models.gd. The billboard atlas cell part of
T-22-3 is added with the atlas baker.
Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

from tools.assetgen import glb

ROOT = pathlib.Path(__file__).resolve().parents[2]
TIERS = ("t0", "t1", "t2")
SURFACES = ("bark", "leaves")
MODEL_DIR = os.path.join("assets", "models", "trees")
TIMEOUT_S = 300


def check_trees(content):
    """Errors of the file side of T-22-3 for a content directory."""
    with open(os.path.join(content, "assetgen", "trees.json"), encoding="utf-8") as f:
        preset = json.load(f)
    with open(os.path.join(content, "data", "trees.json"), encoding="utf-8") as f:
        defs = {t["id"]: t for t in json.load(f)["trees"]}
    model_dir = os.path.join(content, MODEL_DIR)
    category = preset["category"]
    errors = []
    expected = {}
    shapes = {}
    for model in preset["models"]:
        tree = defs.get(model["id"])
        if tree is None:
            errors.append(f"preset model {model['id']}: no tree definition")
            continue
        shapes[model["id"]] = model.get("shape", tree["species"])
        for n in range(1, tree["variants"] + 1):
            expected[f"{category}_{model['id']}_{n}.glb"] = tree
    found = sorted(f for f in os.listdir(model_dir) if f.startswith(category + "_") and f.endswith(".glb")) if os.path.isdir(model_dir) else []
    for name in sorted(set(expected) - set(found)):
        errors.append(f"{name}: missing")
    for name in found:
        tree = expected.get(name) or next((t for i, t in defs.items() if name.startswith(f"{category}_{i}_")), None)
        if tree is None:
            errors.append(f"{name}: no tree definition")
            continue
        shape = shapes.get(tree["id"], tree["species"])
        surfaces = SURFACES if "clumps" in preset["species"].get(shape, {}) else SURFACES[:1]
        errors += check_model(os.path.join(model_dir, name), name[: -len(".glb")], preset["budgets"][tree["size"]], surfaces)
    return errors


def check_model(path, stem, budgets, surfaces=SURFACES):
    errors = []
    meshes = glb.meshes(path)
    for tier, budget in zip(TIERS, budgets):
        mesh = meshes.get(f"{stem}_{tier}")
        if mesh is None:
            errors.append(f"{stem}: no _{tier} mesh")
            continue
        if mesh["triangles"] > budget:
            errors.append(f"{stem}_{tier}: {mesh['triangles']} triangles (budget {budget})")
        materials = [p["material"] for p in mesh["primitives"]]
        if sorted(materials) != sorted(surfaces):
            errors.append(f"{stem}_{tier}: surfaces {materials}, expected {list(surfaces)}")
        for p in mesh["primitives"]:
            if p["attributes"].get("COLOR_0") != "VEC4":
                errors.append(f"{stem}_{tier} {p['material']}: no RGBA vertex colours")
    return errors


def engine_check(content):
    rel = pathlib.Path(content).resolve().relative_to(ROOT / "game").as_posix()
    cmd = [str(ROOT / "tools" / "godot.sh"), "--headless", "-s", "res://src/tools/check_tree_models.gd", "--", f"res://{rel}"]
    try:
        return subprocess.run(cmd, cwd=ROOT, check=False, timeout=TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        print(f"engine check did not finish in {TIMEOUT_S} s", file=sys.stderr)
        return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="validate the assets of a content tree")
    ap.add_argument("content")
    ap.add_argument("--no-engine", action="store_true")
    a = ap.parse_args(argv)
    errors = check_trees(a.content)
    for e in errors:
        print(f"  ERROR {e}")
    code = 0 if a.no_engine or errors else engine_check(a.content)
    ok = not errors and code == 0
    print(f"RESULT {'PASS' if ok else 'FAIL'} (assets, {len(errors)} file errors)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
