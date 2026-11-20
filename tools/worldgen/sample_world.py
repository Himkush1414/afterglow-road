"""Writes the tiny public sample world (game/content_sample/world/) so the
engine's world tests run without private content:

  python3 -m tools.worldgen.sample_world game/content_sample/world
"""
import json
import os
import sys

import numpy as np

from . import files

SKETCH = {
    "size_m": 256,
    "sample_m": 2,
    "sea_level_y": 0,
    "height_encoding": {"scale": 0.02, "offset_m": 64.0},
    "origin_offset_m": 128,
    "world_seed": 5,
}
BIOME_CELL_M = 16


def heights():
    """A smooth made-up field: a slope, a hill and a valley, 129 x 129 samples."""
    n = SKETCH["size_m"] // SKETCH["sample_m"] + 1
    x, z = np.meshgrid(np.arange(n) * 2.0, np.arange(n) * 2.0)
    hill = 30.0 * np.exp(-((x - 170.0) ** 2 + (z - 90.0) ** 2) / (2 * 35.0**2))
    valley = -6.0 * np.exp(-((x - 70.0) ** 2) / (2 * 15.0**2))
    return 12.0 + 0.05 * x + 0.02 * z + hill + valley + 0.7 * np.sin(x / 9.0) * np.cos(z / 13.0)


def biomes():
    """Biome ids per 16 m cell: 2 everywhere, 6 on the hill, 4 in the valley."""
    n = SKETCH["size_m"] // BIOME_CELL_M
    c = (np.arange(n) + 0.5) * BIOME_CELL_M
    x, z = np.meshgrid(c, c)
    ids = np.full((n, n), 2, dtype=np.uint8)
    ids[np.hypot(x - 170.0, z - 90.0) < 40.0] = 6
    ids[np.abs(x - 70.0) < 16.0] = 4
    return ids


def write(out):
    os.makedirs(out, exist_ok=True)
    h = heights()
    data = {
        "height.bin": files.compress(files.encode_height(h, SKETCH).tobytes()),
        "biome.bin": files.compress(biomes().tobytes()),
    }
    hashes = {name: files.write(os.path.join(out, name), blob) for name, blob in data.items()}
    files.write(os.path.join(out, "meta.json"), files.meta_text(files.meta(SKETCH, hashes)).encode("ascii"))
    points = files.height_points(h, SKETCH)
    files.write(os.path.join(out, "height_points.json"), (json.dumps(points) + "\n").encode("ascii"))
    return hashes


if __name__ == "__main__":
    print(write(sys.argv[1] if len(sys.argv) > 1 else "game/content_sample/world"))
