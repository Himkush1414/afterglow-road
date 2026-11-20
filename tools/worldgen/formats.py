"""Checks of written world files against their formats (04 §2)."""
import hashlib
import io
import json
import os

from . import files

META_KEYS = {"version", "size_m", "sample_m", "sea_level_y", "height_offset_m", "height_scale", "origin_offset_m", "world_seed", "sha256"}


def expected_sizes(sk):
    """Decoded byte size of every binary file for this sketch."""
    n = int(round(sk["size_m"] / sk["sample_m"])) + 1
    d = sk["derive"]
    t4 = int(round(sk["size_m"] / 4.0))
    t16 = int(round(sk["size_m"] / d.get("biome_cell_m", 16.0)))
    lo, hi = d["minmax_lods"]
    nodes0 = int(round(sk["size_m"] / d["minmax_node_m"]))
    nodes = sum((nodes0 >> level) ** 2 for level in range(lo, hi + 1))
    return {"height.bin": n * n * 2, "normal.bin": t4 * t4 * 2, "biome.bin": t16 * t16, "mask.bin": t4 * t4 * 4, "minmax.bin": nodes * 4}, t4


def check_dir(path, sk):
    """List of errors (empty when every file matches its format and hash)."""
    errors = []
    try:
        with open(os.path.join(path, "meta.json"), encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, ValueError) as e:
        return [f"meta.json: {e}"]
    if set(meta) != META_KEYS:
        errors.append(f"meta.json: keys {sorted(set(meta) ^ META_KEYS)} differ")
    sizes, macro_px = expected_sizes(sk)
    want = set(sizes) | {"macro.png", "water.json", "roads.json"}
    if set(meta.get("sha256", {})) != want:
        errors.append(f"meta.json: files {sorted(set(meta.get('sha256', {})) ^ want)} differ")
    for name in sorted(want):
        try:
            with open(os.path.join(path, name), "rb") as f:
                data = f.read()
        except OSError as e:
            errors.append(f"{name}: {e}")
            continue
        if hashlib.sha256(data).hexdigest() != meta.get("sha256", {}).get(name):
            errors.append(f"{name}: SHA-256 differs from meta.json")
        if name in sizes:
            try:
                raw = files.decompress(data)
            except Exception as e:  # noqa: BLE001  (any decoder error is a format error)
                errors.append(f"{name}: not a ZSTD frame ({e})")
                continue
            if len(raw) != sizes[name]:
                errors.append(f"{name}: {len(raw)} bytes decoded, expected {sizes[name]}")
        elif name == "macro.png":
            from PIL import Image

            img = Image.open(io.BytesIO(data))
            if img.format != "PNG" or img.mode != "RGB" or img.size != (macro_px, macro_px):
                errors.append(f"macro.png: {img.format} {img.mode} {img.size}, expected PNG RGB {macro_px}²")
        else:
            doc = json.loads(data)
            if name == "water.json" and set(doc) != {"sea_level_y", "lakes", "rivers"}:
                errors.append("water.json: top-level keys differ")
            if name == "roads.json" and (set(doc) != {"ways"} or any(set(w) != {"id", "type", "width_m", "points"} for w in doc["ways"])):
                errors.append("roads.json: keys differ")
    return errors
