"""Reads the world sketch (JSON) and the named-place table (CSV)."""
import csv
import json

SKETCH_VERSION = 1


def load(path, pois_path=None):
    """The sketch as a dict. With pois_path, sketch["pois"] holds the rows of
    that CSV (columns id, x, z, y at least; x, z, y as floats)."""
    with open(path, encoding="utf-8") as f:
        sketch = json.load(f)
    if sketch.get("version") != SKETCH_VERSION:
        raise ValueError(f"{path}: sketch version {sketch.get('version')!r}, expected {SKETCH_VERSION}")
    if pois_path:
        sketch["pois"] = load_pois(pois_path)
    return sketch


def load_pois(path):
    with open(path, encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in ("x", "z", "y"):
            r[k] = float(r[k])
    return rows
