"""Asset validator for one content tree (22 §7):

  python3 -m tools.assetgen.validate <content dir under game/> [--no-engine]

T-22-3 (tree models), file side: every model the tree preset
(<content>/assetgen/trees.json) asks for exists for each variant of its
tree definition (<content>/data/trees.json); every
<content>/assets/models/trees/tree_*.glb has the meshes _t0, _t1 and _t2,
each within the triangle budget of its size (T-22-2) and with a bark and a
leaves surface (bark only when the model's shape preset has no clumps) that all
carry RGBA vertex colours (COLOR_0, VEC4); and a _t3 billboard quad (2
triangles, "billboard" surface, vertex colours) whose atlas cell is listed,
unique and inside the grid in <models>/<category>_models.json, and holds
part of a tree in the billboard atlas <content>/assets/texture_sets/trees/
hi/<category>_billboards_ca.png (+ _n.png with the same coverage; the lo
set at half size, T-22-8).
Stumps and felled caps (22 §3), when <content>/assetgen/stumps.json exists:
every mesh the preset asks for exists within its triangle budget and has
exactly a bark and a cut surface.
Engine side (unless --no-engine): the imported models are checked headless
by res://src/tools/check_tree_models.gd.
Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

from tools.assetgen import glb
from tools.assetgen.shapes import shape_for

ROOT = pathlib.Path(__file__).resolve().parents[2]
TIERS = ("t0", "t1", "t2")
SURFACES = ("bark", "leaves")
MODEL_DIR = os.path.join("assets", "models", "trees")
STUMP_DIR = os.path.join("assets", "models", "stumps")
STUMP_SURFACES = ["bark", "cut"]
COVER_MODEL_DIR = os.path.join("assets", "models", "ground_cover")
COVER_TEXTURE_DIR = os.path.join("assets", "textures", "ground_cover")
COVER_SURFACES = ["ground_cover"]
TEXTURE_DIR = os.path.join("assets", "texture_sets", "trees")
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
        shapes[model["id"]] = shape_for(preset, model, tree)
        for n in range(1, tree["variants"] + 1):
            expected[f"{category}_{model['id']}_{n}.glb"] = tree
    found = sorted(f for f in os.listdir(model_dir) if f.startswith(category + "_") and f.endswith(".glb")) if os.path.isdir(model_dir) else []
    for name in sorted(set(expected) - set(found)):
        errors.append(f"{name}: missing")
    manifest_path = os.path.join(model_dir, f"{category}_models.json")
    manifest = {"grid": 0, "models": {}}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    elif found:
        errors.append(f"{category}_models.json: missing")
    seen = {}
    for name in found:
        stem = name[: -len(".glb")]
        entry = manifest["models"].get(stem)
        if entry is None:
            errors.append(f"{stem}: no billboard cell in {category}_models.json")
        elif not 0 <= entry["cell"] < manifest["grid"] ** 2:
            errors.append(f"{stem}: billboard cell {entry['cell']} outside the {manifest['grid']} x {manifest['grid']} atlas")
        elif entry["cell"] in seen:
            errors.append(f"{stem}: billboard cell {entry['cell']} also used by {seen[entry['cell']]}")
        else:
            seen[entry["cell"]] = stem
        if entry is not None:
            errors += check_sets(os.path.join(content, TEXTURE_DIR, "hi"), category, stem, entry)
    if found and manifest["grid"]:
        errors += check_atlas(os.path.join(content, TEXTURE_DIR), category, manifest)
    for name in found:
        tree = expected.get(name) or next((t for i, t in defs.items() if name.startswith(f"{category}_{i}_")), None)
        if tree is None:
            errors.append(f"{name}: no tree definition")
            continue
        shape = shapes.get(tree["id"]) or shape_for(preset, {"id": tree["id"]}, tree)
        surfaces = SURFACES if "clumps" in shape else SURFACES[:1]
        errors += check_model(os.path.join(model_dir, name), name[: -len(".glb")], preset["budgets"][tree["size"]], surfaces)
    return errors


def check_stumps(content):
    """Errors of the stump and cap models ([] without a stump preset)."""
    preset_path = os.path.join(content, "assetgen", "stumps.json")
    if not os.path.exists(preset_path):
        return []
    with open(preset_path, encoding="utf-8") as f:
        preset = json.load(f)
    model_dir = os.path.join(content, STUMP_DIR)
    errors = glb.check(preset, model_dir)
    for spec in preset["meshes"]:
        for n in range(1, spec["variants"] + 1):
            name = f"{preset['category']}_{spec['name']}_{n}"
            path = os.path.join(model_dir, name + ".glb")
            if not os.path.exists(path):
                continue
            for mesh, entry in glb.meshes(path).items():
                materials = sorted(p["material"] or "" for p in entry["primitives"])
                if materials != STUMP_SURFACES:
                    errors.append(f"{name} {mesh}: surfaces {materials}, expected {STUMP_SURFACES}")
    return errors


def check_sets(hi_dir, category, stem, entry):
    """Errors of a model's texture sets: a bark set, and a leaf set exactly
    when the model has leaves (checked against its surfaces elsewhere), each
    naming textures that exist."""
    errors = []
    if not entry.get("bark_set"):
        return [f"{stem}: no bark_set in {category}_models.json"]
    wanted = [f"{category}_{entry['bark_set']}_bark_ah.png", f"{category}_{entry['bark_set']}_bark_nra.png"]
    if entry.get("leaf_set"):
        wanted += [f"{category}_{entry['leaf_set']}_leaves_ca.png", f"{category}_{entry['leaf_set']}_leaves_nra.png"]
    for name in wanted:
        if not os.path.exists(os.path.join(hi_dir, name)):
            errors.append(f"{stem}: texture {name} missing")
    return errors


def check_atlas(texture_dir, category, manifest):
    """Errors of the billboard atlas: files, sizes, matching coverage, and a
    covered pixel in every listed cell."""
    import numpy as np
    from PIL import Image

    errors, images = [], {}
    for kind in ("ca", "n"):
        for d in ("hi", "lo"):
            path = os.path.join(texture_dir, d, f"{category}_billboards_{kind}.png")
            if not os.path.exists(path):
                errors.append(f"{d}/{category}_billboards_{kind}.png: missing")
                continue
            with Image.open(path) as im:
                images[(kind, d)] = np.asarray(im.convert("RGBA"))
    if errors:
        return errors
    g = manifest["grid"]
    hi = images[("ca", "hi")]
    if hi.shape[0] != hi.shape[1] or hi.shape[0] % g:
        return [f"billboard atlas {hi.shape[1]} x {hi.shape[0]} does not split into {g} x {g} cells"]
    for kind in ("ca", "n"):
        if images[(kind, "lo")].shape[:2] != (hi.shape[0] // 2, hi.shape[1] // 2):
            errors.append(f"lo/{category}_billboards_{kind}.png is not half of the hi size")
    if images[("n", "hi")].shape != hi.shape or not np.array_equal(images[("n", "hi")][..., 3], hi[..., 3]):
        errors.append("billboard colour and normal atlases differ in coverage")
    n = hi.shape[0] // g
    for stem, entry in sorted(manifest["models"].items()):
        c = entry["cell"]
        if 0 <= c < g * g and not (hi[(c // g) * n : (c // g + 1) * n, (c % g) * n : (c % g + 1) * n, 3] >= 128).any():
            errors.append(f"{stem}: billboard cell {c} is empty")
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
    quad = meshes.get(f"{stem}_t3")
    if quad is None:
        errors.append(f"{stem}: no _t3 mesh")
    elif quad["triangles"] != 2 or [p["material"] for p in quad["primitives"]] != ["billboard"]:
        errors.append(f"{stem}_t3: {quad['triangles']} triangles, surfaces {[p['material'] for p in quad['primitives']]}; expected 2, ['billboard']")
    elif quad["primitives"][0]["attributes"].get("COLOR_0") != "VEC4":
        errors.append(f"{stem}_t3: no RGBA vertex colours")
    return errors


def engine_check(content):
    rel = pathlib.Path(content).resolve().relative_to(ROOT / "game").as_posix()
    cmd = [str(ROOT / "tools" / "godot.sh"), "--headless", "-s", "res://src/tools/check_tree_models.gd", "--", f"res://{rel}"]
    try:
        return subprocess.run(cmd, cwd=ROOT, check=False, timeout=TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        print(f"engine check did not finish in {TIMEOUT_S} s", file=sys.stderr)
        return 1


def check_ground_cover(content):
    """Errors of the ground-cover atlas and meshes ([] without a mesh
    preset): atlas images and manifest present, every mesh preset cell in
    the atlas, every level of detail present, within its triangle budget,
    one "ground_cover" surface carrying vertex colour (the tip weight)."""
    preset_path = os.path.join(content, "assetgen", "ground_cover_meshes.json")
    if not os.path.exists(preset_path):
        return []
    with open(preset_path, encoding="utf-8") as f:
        preset = json.load(f)
    errors = []
    textures = os.path.join(content, COVER_TEXTURE_DIR)
    cat = preset["category"]
    for sub in ("hi", "lo"):
        for kind in ("ca", "nra"):
            path = os.path.join(textures, sub, f"{cat}_{kind}.png")
            if not os.path.exists(path):
                errors.append(f"{path}: missing")
    manifest_path = os.path.join(textures, f"{cat}.json")
    cells = set()
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            cells = {c["name"] for c in json.load(f)["cells"]}
    else:
        errors.append(f"{manifest_path}: missing")
    models = os.path.join(content, COVER_MODEL_DIR)
    for spec in preset["meshes"]:
        if cells and spec["cell"] not in cells:
            errors.append(f"{spec['name']}: atlas has no cell '{spec['cell']}'")
        for lod in spec["lods"]:
            path = os.path.join(models, f"{cat}_{spec['name']}_{lod}.glb")
            if not os.path.exists(path):
                errors.append(f"{path}: missing")
                continue
            for mesh, entry in glb.meshes(path).items():
                budget = spec["max_tris"][lod]
                if entry["triangles"] > budget:
                    errors.append(f"{path}: {entry['triangles']} triangles (budget {budget})")
                materials = sorted(p["material"] or "" for p in entry["primitives"])
                if materials != COVER_SURFACES:
                    errors.append(f"{path} {mesh}: surfaces {materials}, expected {COVER_SURFACES}")
                if any("COLOR_0" not in p["attributes"] for p in entry["primitives"]):
                    errors.append(f"{path} {mesh}: no vertex colour (tip weight)")
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description="validate the assets of a content tree")
    ap.add_argument("content")
    ap.add_argument("--no-engine", action="store_true")
    a = ap.parse_args(argv)
    errors = check_trees(a.content) + check_stumps(a.content) + check_ground_cover(a.content)
    for e in errors:
        print(f"  ERROR {e}")
    code = 0 if a.no_engine or errors else engine_check(a.content)
    ok = not errors and code == 0
    print(f"RESULT {'PASS' if ok else 'FAIL'} (assets, {len(errors)} file errors)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
