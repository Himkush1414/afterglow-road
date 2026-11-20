"""Command line of the world generator.

  python3 -m tools.worldgen check-pois --sketch S.json --pois P.csv [--no-noise]
        [--until STAGE] [--tolerance M]
      Heights at every named place after the stages up to STAGE (default:
      the last registered one) against the place table's y column. Exit 1
      if any differs by more than the tolerance (default 1 m).

  python3 -m tools.worldgen water --sketch S.json --pois P.csv --out water.json
      Writes the water file, prints its SHA-256 and checks its rules (river
      levels never rise, lake levels as in the sketch). Exit 1 on a rule error.

  python3 -m tools.worldgen roads --sketch S.json --pois P.csv --out roads.json
      Runs the stages up to the roads on the full map at the sketch's sample
      spacing, writes the way file and reports, per way and grade limit, the
      worst window grade on the final surface (road and track part of
      T-05-10). Exit 1 if one fails or a place got no track.
"""
import argparse
import sys

from . import sketch as sketch_io
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
    sk = sketch_io.load(args.sketch, args.pois)
    s = float(sk.get("sample_m", 2.0))
    ctx = run(sk, Grid.full(sk["size_m"], s), sk["world_seed"], until="roads")
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
    print(f"WAY CHECK: {'FAIL' if bad else 'PASS'} (sample {s:g} m)")
    return 1 if bad else 0


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
    rd.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    return {"check-pois": check_pois, "water": write_water, "roads": write_roads}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
