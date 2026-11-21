"""Reads binary glTF (.glb) files far enough to check asset budgets
(22 §3, T-22-2): triangle count and bounds of every mesh.

  python3 -m tools.assetgen.glb --preset <rocks.json> --dir <dir>
"""
import argparse
import json
import os
import struct
import sys

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A


def read_json(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, _, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC or length != len(data):
        raise ValueError(f"{path}: not a binary glTF file")
    size, kind = struct.unpack_from("<II", data, 12)
    if kind != CHUNK_JSON:
        raise ValueError(f"{path}: first chunk is not JSON")
    return json.loads(data[20 : 20 + size])


def stats(path):
    """{"triangles": int, "min": [x, y, z], "max": [x, y, z]} over all meshes."""
    doc = read_json(path)
    acc = doc["accessors"]
    tris = 0
    lo, hi = [float("inf")] * 3, [float("-inf")] * 3
    for mesh in doc.get("meshes", []):
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4:
                raise ValueError(f"{path}: only triangle lists are counted")
            pos = acc[prim["attributes"]["POSITION"]]
            n = acc[prim["indices"]]["count"] if "indices" in prim else pos["count"]
            tris += n // 3
            lo = [min(a, b) for a, b in zip(lo, pos["min"])]
            hi = [max(a, b) for a, b in zip(hi, pos["max"])]
    return {"triangles": tris, "min": lo, "max": hi}


def check(preset, directory):
    """Errors for missing files or meshes over their triangle budget."""
    errors = []
    for spec in preset["meshes"]:
        for n in range(1, spec["variants"] + 1):
            path = os.path.join(directory, f"{preset['category']}_{spec['name']}_{n}.glb")
            if not os.path.exists(path):
                errors.append(f"{path}: missing")
                continue
            s = stats(path)
            if s["triangles"] > spec["max_tris"]:
                errors.append(f"{path}: {s['triangles']} triangles (budget {spec['max_tris']})")
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description="check glb budgets")
    ap.add_argument("--preset", required=True)
    ap.add_argument("--dir", required=True)
    a = ap.parse_args(argv)
    with open(a.preset, encoding="utf-8") as f:
        preset = json.load(f)
    errors = check(preset, a.dir)
    for spec in preset["meshes"]:
        for n in range(1, spec["variants"] + 1):
            path = os.path.join(a.dir, f"{preset['category']}_{spec['name']}_{n}.glb")
            if os.path.exists(path):
                s = stats(path)
                size = [round(h - l, 2) for l, h in zip(s["min"], s["max"])]
                print(f"  {os.path.basename(path):<24} {s['triangles']:>5} triangles  size {size}")
    for e in errors:
        print(f"  ERROR {e}")
    print(f"BUDGET CHECK: {'FAIL' if errors else 'PASS'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
