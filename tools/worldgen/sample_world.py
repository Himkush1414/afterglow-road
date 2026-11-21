"""Writes the tiny public sample world (game/content_sample/world/) so the
engine's world tests run without private content:

  python3 -m tools.worldgen.sample_world game/content_sample/world
"""
import hashlib
import json
import os
import sys
from types import SimpleNamespace

import numpy as np

from . import derive, files, objects, placement
from . import water as water_io
from .grid import Grid

SKETCH = {
    "size_m": 256,
    "sample_m": 2,
    "sea_level_y": 0,
    "height_encoding": {"scale": 0.02, "offset_m": 64.0},
    "origin_offset_m": 128,
    "world_seed": 5,
    # root quadtree nodes of 128 m (2 x 2), as the full map has 4,096 m roots
    "derive": {"minmax_node_m": 64, "minmax_lods": [0, 1]},
}
BIOME_CELL_M = 16


def heights():
    """A smooth made-up field: a slope, a hill and a valley, 129 x 129 samples."""
    n = SKETCH["size_m"] // SKETCH["sample_m"] + 1
    x, z = np.meshgrid(np.arange(n) * 2.0, np.arange(n) * 2.0)
    return heights_at(x, z)


def biomes():
    """Biome ids per 16 m cell: 2 everywhere, 6 on the hill, 4 in the valley."""
    n = SKETCH["size_m"] // BIOME_CELL_M
    c = (np.arange(n) + 0.5) * BIOME_CELL_M
    x, z = np.meshgrid(c, c)
    ids = np.full((n, n), 2, dtype=np.uint8)
    ids[np.hypot(x - 170.0, z - 90.0) < 40.0] = 6
    ids[np.abs(x - 70.0) < 16.0] = 4
    return ids


def water():
    """A small lake and a stream in the valley (map coordinates). The stream
    runs downhill (decreasing z), its level 0.3 m above the valley floor."""
    t = np.linspace(0.0, 2.0 * np.pi, 24, endpoint=False)
    lake = [[round(70.0 + 9.0 * np.cos(a), 3), round(40.0 + 14.0 * np.sin(a), 3)] for a in t]
    zs = np.arange(230.0, 119.0, -5.0)
    centre = [[70.0, float(z)] for z in zs]
    floor = heights_at(np.full(zs.shape, 70.0), zs)
    level = np.minimum.accumulate(floor + 0.3)
    return {
        "sea_level_y": SKETCH["sea_level_y"],
        "lakes": [{"id": "pond", "level": 11.0, "polygon": lake}],
        "rivers": [{"id": "brook", "kind": "stream", "centre": centre, "level": [round(float(v), 3) for v in level], "width": [2.0] * len(centre)}],
    }


def region_objects():
    """One cliff face on the hill's east flank and one boulder, for the
    engine's region tests (the sample content has no rock meshes, so a
    stand-in slab is drawn)."""
    return [("cliff", "face_a", 196.0, 90.0, 90, 35), ("node", "boulder", 120.0, 150.0, 30)]


def trees():
    """Three trees of the sample's one tree model, two in chunk (0, 0) and one
    in chunk (1, 1), for the engine's chunk-file test."""
    return {
        "model": np.array([0, 0, 0], dtype=np.uint8),
        "x": np.array([20.0, 64.5, 200.25]),
        "z": np.array([30.0, 100.0, 140.75]),
        "yaw": np.array([0, 64, 200], dtype=np.uint8),
        "scale": np.array([0, 128, 255], dtype=np.uint8),
    }


def heights_at(x, z):
    hill = 30.0 * np.exp(-((x - 170.0) ** 2 + (z - 90.0) ** 2) / (2 * 35.0**2))
    valley = -6.0 * np.exp(-((x - 70.0) ** 2) / (2 * 15.0**2))
    return 12.0 + 0.05 * x + 0.02 * z + hill + valley + 0.7 * np.sin(x / 9.0) * np.cos(z / 13.0)


def write(out):
    os.makedirs(out, exist_ok=True)
    h = heights()
    encoded = files.encode_height(h, SKETCH)
    ctx = SimpleNamespace(sketch=SKETCH, grid=Grid.full(SKETCH["size_m"], SKETCH["sample_m"]), layers={"height": h})
    data = {
        "height.bin": files.compress(encoded.tobytes()),
        "biome.bin": files.compress(biomes().tobytes()),
        "minmax.bin": files.compress(derive.minmax_bytes(ctx, encoded)),
        "normal.bin": files.compress(derive.normal_bytes(ctx)),
        "water.json": water_io.dumps(water()).encode("ascii"),
    }
    hashes = {name: files.write(os.path.join(out, name), blob) for name, blob in data.items()}
    hashes["trees/index.json"] = hashlib.sha256(placement.write_tree_files(trees(), out)).hexdigest()
    docs = objects.region_documents(region_objects(), SKETCH, h)
    hashes["regions/index.json"] = hashlib.sha256(objects.write_region_files(docs, out)).hexdigest()
    files.write(os.path.join(out, "meta.json"), files.meta_text(files.meta(SKETCH, hashes)).encode("ascii"))
    points = files.height_points(h, SKETCH)
    files.write(os.path.join(out, "height_points.json"), (json.dumps(points) + "\n").encode("ascii"))
    return hashes


if __name__ == "__main__":
    print(write(sys.argv[1] if len(sys.argv) > 1 else "game/content_sample/world"))
