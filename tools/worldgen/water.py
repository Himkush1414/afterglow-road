"""The water file: lakes (outline, level), rivers (centre line, widths,
levels) and the sea level, plus its acceptance check."""
import json

from .grid import Grid
from .pipeline import run


def document(sketch, seed=None, noise=True):
    """Runs the stages up to the rivers (their records do not depend on the
    grid, so one sample is enough) and returns the water document."""
    seed = sketch["world_seed"] if seed is None else seed
    ctx = run(sketch, Grid(0.0, 0.0, float(sketch.get("sample_m", 2.0)), 1, 1), seed, until="rivers", noise=noise)
    return {
        "sea_level_y": float(sketch.get("sea_level_y", 0.0)),
        "lakes": ctx.water.get("lakes", []),
        "rivers": [
            {k: r[k] for k in ("id", "kind", "centre", "width", "level")} for r in ctx.water.get("rivers", [])
        ],
    }


def dumps(doc):
    """Byte-stable JSON text."""
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"


def check(doc, sketch):
    """Errors against the water rules: every river level is non-increasing
    from source to mouth; every lake has the sketch's level."""
    errors = []
    for r in doc["rivers"]:
        lv = r["level"]
        if len(lv) != len(r["centre"]) or len(lv) != len(r["width"]):
            errors.append(f"{r['id']}: centre, width and level lengths differ")
        for i in range(1, len(lv)):
            if lv[i] > lv[i - 1]:
                errors.append(f"{r['id']}: level rises at vertex {i} ({lv[i - 1]} -> {lv[i]})")
                break
    want = float(sketch["lake"]["level"])
    for lk in doc["lakes"]:
        if lk["level"] != want:
            errors.append(f"{lk['id']}: level {lk['level']}, expected {want}")
    return errors
