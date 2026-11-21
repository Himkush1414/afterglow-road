"""Command line of the world generator.

  python3 -m tools.worldgen check-pois --sketch S.json --pois P.csv [--no-noise]
        [--until STAGE] [--tolerance M]
      Heights at every named place after the stages up to STAGE (default:
      the last registered one) against the place table's y column. Exit 1
      if any differs by more than the tolerance (default 1 m).

  python3 -m tools.worldgen water --sketch S.json --pois P.csv --out water.json
      Writes the water file, prints its SHA-256 and checks its rules (river
      levels never rise, lake levels as in the sketch). Exit 1 on a rule error.

  python3 -m tools.worldgen roads --sketch S.json --pois P.csv --buildings B.csv --out roads.json
      Runs every stage on the full map at the sketch's sample spacing, writes
      the way file and reports, on the final field: per way and grade limit
      the worst window grade (road and track part of T-05-10), whether every
      lot is flat, and buildings left unplaced, on a way, or without a layout.
      Exit 1 on any failure or a place without a track.

  python3 -m tools.worldgen generate --sketch S.json --pois P.csv --buildings B.csv --out DIR [--layer-colours M.json]
      Runs every stage on the full map and writes the world files of 04 §2
      into DIR (those implemented so far) plus meta.json with their SHA-256.
      --layer-colours: far colours from a painted-texture manifest (mean albedo).
      --trees: the tree table (the game's trees.json): places trees (stage 14a),
      writes trees/<cx>_<cz>.bin and trees/index.json and reports the counts per
      biome and species (exit 1 when one is more than 2 % off).

  python3 -m tools.worldgen check-files --sketch S.json --dir DIR
      Checks every world file in DIR against its format and its hash in
      meta.json. Exit 1 on any error.
"""
import argparse
import json
import os
import sys

from . import sketch as sketch_io
from . import lots as lots_io
from . import roads as roads_io
from . import water as water_io
from .grid import Grid
from .pipeline import STAGES, load_stages, run, sha256

load_stages()


def check_pois(args):
    sk = sketch_io.load(args.sketch, args.pois)
    until = args.until or STAGES[-1][0]
    if until not in [n for n, _ in STAGES]:
        print(f"unknown stage {until!r}; stages: {', '.join(n for n, _ in STAGES)}", file=sys.stderr)
        return 2
    s = float(sk.get("sample_m", 2.0))
    worst, bad = 0.0, 0
    for p in sk["pois"]:
        # a 3x3 patch centred on the place, so stages that need neighbours have them
        g = Grid(p["x"] - s, p["z"] - s, s, 3, 3)
        h = float(run(sk, g, sk["world_seed"], until=until, noise=not args.no_noise).layers["height"][1, 1])
        diff = h - p["y"]
        worst = max(worst, abs(diff))
        flag = "" if abs(diff) <= args.tolerance else "  FAIL"
        bad += bool(flag)
        print(f"{p['id']:<24} y {p['y']:8.2f}  generated {h:8.2f}  diff {diff:+7.2f}{flag}")
    mode = "noise off" if args.no_noise else "noise on"
    result = "FAIL" if bad else "PASS"
    print(f"POI CHECK: {result} ({len(sk['pois'])} places, until {until}, {mode}, worst {worst:.2f} m, limit {args.tolerance} m)")
    return 1 if bad else 0


def write_water(args):
    sk = sketch_io.load(args.sketch, args.pois)
    doc = water_io.document(sk)
    text = water_io.dumps(doc).encode("ascii")
    with open(args.out, "wb") as f:
        f.write(text)
    print(f"wrote {args.out}: {len(doc['lakes'])} lakes, {len(doc['rivers'])} rivers, sha256 {sha256(text)}")
    errors = water_io.check(doc, sk)
    for e in errors:
        print(f"  ERROR {e}")
    print(f"WATER CHECK: {'FAIL' if errors else 'PASS'}")
    return 1 if errors else 0


def write_roads(args):
    sk = sketch_io.load(args.sketch, args.pois, args.buildings)
    s = float(sk.get("sample_m", 2.0))
    ctx = run(sk, Grid.full(sk["size_m"], s), sk["world_seed"])
    text = water_io.dumps(roads_io.document(ctx)).encode("ascii")
    with open(args.out, "wb") as f:
        f.write(text)
    print(f"wrote {args.out}: {len(ctx.roads)} ways, sha256 {sha256(text)}")
    bad = 0
    for r in roads_io.grade_report(ctx):
        bad += not r["ok"]
        flag = "" if r["ok"] else "  FAIL"
        print(f"  {r['id']:<28} {r['type']:<6} limit {r['limit']:4.0%} worst {r['worst']:6.2%} at {r['at']}{flag}")
    for pid in ctx.route_failures:
        bad += 1
        print(f"  no track route under the limit to {pid}  FAIL")
    tilted = [(lot["id"], lots_io.core_spread(ctx, lot)) for lot in ctx.lots]
    tilted = [(i, v) for i, v in tilted if v > 1e-6]
    buildings = {lot["id"] for lot in ctx.lots if "archetype" in lot}
    on_way = [o for o in ctx.lot_way_overlaps if o[0] in buildings]
    unplaced = (ctx.settlement or {}).get("unplaced", [])
    for lid, v in tilted:
        print(f"  lot {lid} not flat (spread {v:.3f} m)  FAIL")
    for lid, wid in on_way:
        print(f"  lot {lid} on way {wid}  FAIL")
    for pid, name in unplaced:
        print(f"  {pid}: {name} did not fit  FAIL")
    for pid in ctx.lot_pending:
        print(f"  {pid}: no settlement layout  FAIL")
    bad += len(tilted) + len(on_way) + len(unplaced) + len(ctx.lot_pending)
    print(f"  lots: {len(ctx.lots)} ({len(buildings)} buildings), flat: {len(ctx.lots) - len(tilted)}")
    print(f"WAY CHECK: {'FAIL' if bad else 'PASS'} (sample {s:g} m)")
    return 1 if bad else 0


def generate(args):
    from . import files

    sk = sketch_io.load(args.sketch, args.pois, args.buildings)
    if args.layer_colours:
        from . import derive as derive_mod

        with open(args.layer_colours, encoding="utf-8") as f:
            derive_mod.apply_layer_colours(sk, json.load(f))
    ctx = run(sk, Grid.full(sk["size_m"], float(sk["sample_m"])), sk["world_seed"])
    os.makedirs(args.out, exist_ok=True)
    from . import derive

    encoded = files.encode_height(ctx.layers["height"], sk)
    mask = derive.mask_rgba(ctx)
    bad = 0
    tree_lines = []
    tree_index = None
    region_index = None
    if args.trees:
        import numpy as np

        from . import biome, placement

        table = placement.tree_table(args.trees)
        gd = placement.ground(ctx)
        rec = placement.place_trees(ctx, table, gd)
        mask[..., 3] = placement.tree_cover(rec, table, sk["size_m"])
        tree_index = placement.write_tree_files(rec, args.out)
        names = biome.names(sk)
        for bid, sp, want, have in placement.count_report(rec, placement.expected_counts(sk, gd), table):
            off = abs(have - want) > max(1, 0.02 * want)
            bad += off
            flag = "  FAIL" if off else ""
            tree_lines.append(f"  trees {names[bid]:<18} {sp:<8} expected {want:>7} placed {have:>7}{flag}")
        rules, counts = np.unique(rec["rule"], return_counts=True)
        tree_lines.append("  trees by rule: " + ", ".join(f"{r} {c}" for r, c in zip(rules, counts)))
        tree_lines.append(f"  trees total {rec['model'].size} in {len(json.loads(tree_index)['files'])} chunks")
        tree_lines.append(f"  tree cover: mean {mask[..., 3].mean() / 255:.3f} of the map")
        from . import objects

        from . import nodes

        objs, counts = objects.area_objects(ctx, gd, mask[..., 3])
        node_objs, node_plan = nodes.place_nodes(ctx, gd)
        for (tid, k), (want, have) in node_plan.items():
            counts[f"{tid}#{k + 1}"] = (want, have)
        objs += node_objs
        for name, (want, have) in sorted(counts.items()):
            off = abs(have - want) > max(1, 0.02 * want)
            bad += off
            tree_lines.append(f"  objects {name:<16} expected {want:>7} placed {have:>7}{'  FAIL' if off else ''}")
        region_index = objects.write_region_files(objects.region_documents(objs, sk, ctx.layers["height"]), args.out)
        tree_lines.append(f"  objects total {len(objs)} in {len(json.loads(region_index)['files'])} region files")
    out = {
        "height.bin": files.compress(encoded.tobytes()),
        "minmax.bin": files.compress(derive.minmax_bytes(ctx, encoded)),
        "normal.bin": files.compress(derive.normal_bytes(ctx)),
        "biome.bin": files.compress(derive.biome_bytes(ctx)),
        "mask.bin": files.compress(mask.tobytes()),
        "macro.png": derive.macro_png(ctx, mask),
        "water.json": water_io.dumps(water_io.document(sk)).encode("ascii"),
        "roads.json": water_io.dumps(roads_io.document(ctx)).encode("ascii"),
    }
    for line in tree_lines:
        print(line)
    if tree_index is not None:
        out["trees/index.json"] = tree_index
        out["regions/index.json"] = region_index
    written = ("trees/index.json", "regions/index.json")  # written with their files
    hashes = {name: files.write(os.path.join(args.out, name), data) for name, data in out.items() if name not in written}
    import hashlib

    for name in written:
        if name in out:
            hashes[name] = hashlib.sha256(out[name]).hexdigest()
    files.write(os.path.join(args.out, "meta.json"), files.meta_text(files.meta(sk, hashes)).encode("ascii"))
    # check fixture for the engine (T-05-2), not a world file
    points = files.height_points(ctx.layers["height"], sk)
    files.write(os.path.join(args.out, "height_points.json"), (json.dumps(points) + "\n").encode("ascii"))
    for name in sorted(hashes):
        print(f"  {name:<12} {len(out[name]):>10} bytes  sha256 {hashes[name]}")
    print(f"GENERATE: wrote {len(hashes) + 1} files to {args.out}")
    if bad:
        print(f"PLACEMENT CHECK: FAIL ({bad} counts more than 2 % off)")
    return 1 if bad else 0


def check_files(args):
    from . import formats

    errors = formats.check_dir(args.dir, sketch_io.load(args.sketch))
    for e in errors:
        print(f"  ERROR {e}")
    print(f"FILE CHECK: {'FAIL' if errors else 'PASS'} ({args.dir})")
    return 1 if errors else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python3 -m tools.worldgen")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check-pois", help="compare generated heights with the place table")
    c.add_argument("--sketch", required=True)
    c.add_argument("--pois", required=True)
    c.add_argument("--until")
    c.add_argument("--no-noise", action="store_true")
    c.add_argument("--tolerance", type=float, default=1.0)
    w = sub.add_parser("water", help="write and check the water file")
    w.add_argument("--sketch", required=True)
    w.add_argument("--pois", required=True)
    w.add_argument("--out", required=True)
    rd = sub.add_parser("roads", help="write the way file and check way grades")
    rd.add_argument("--sketch", required=True)
    rd.add_argument("--pois", required=True)
    rd.add_argument("--buildings")
    rd.add_argument("--out", required=True)
    gen = sub.add_parser("generate", help="write the world files")
    gen.add_argument("--sketch", required=True)
    gen.add_argument("--pois", required=True)
    gen.add_argument("--buildings")
    gen.add_argument("--out", required=True)
    gen.add_argument("--layer-colours")
    gen.add_argument("--trees")
    cf = sub.add_parser("check-files", help="check written world files against their formats")
    cf.add_argument("--sketch", required=True)
    cf.add_argument("--dir", required=True)
    args = ap.parse_args(argv)
    commands = {"check-pois": check_pois, "water": write_water, "roads": write_roads, "generate": generate, "check-files": check_files}
    return commands[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
