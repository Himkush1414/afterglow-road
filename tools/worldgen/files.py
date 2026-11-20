"""World file writers: ZSTD frames, height encoding, the meta file."""
import hashlib
import json

import numpy as np
import zstandard

ZSTD_LEVEL = 9
WORLD_FILE_VERSION = 1


def compress(data):
    """One plain ZSTD frame with the content size in its header (read in the
    game with PackedByteArray.decompress)."""
    return zstandard.ZstdCompressor(level=ZSTD_LEVEL, write_content_size=True, threads=0).compress(bytes(data))


def decompress(frame):
    return zstandard.ZstdDecompressor().decompress(frame)


def encode_height(y, sk):
    """u16 per sample: round((y + offset) / scale), clamped to 0..65535."""
    enc = sk["height_encoding"]
    v = np.floor((np.asarray(y, dtype=np.float64) + enc["offset_m"]) / enc["scale"] + 0.5)
    return np.clip(v, 0, 65535).astype("<u2")


def decode_height(u, sk):
    enc = sk["height_encoding"]
    return np.asarray(u, dtype=np.float64) * enc["scale"] - enc["offset_m"]


def write(path, data):
    """Writes bytes and returns their SHA-256."""
    with open(path, "wb") as f:
        f.write(data)
    return hashlib.sha256(data).hexdigest()


def meta(sk, hashes):
    enc = sk["height_encoding"]
    return {
        "version": WORLD_FILE_VERSION,
        "size_m": sk["size_m"],
        "sample_m": sk["sample_m"],
        "sea_level_y": sk.get("sea_level_y", 0),
        "height_offset_m": enc["offset_m"],
        "height_scale": enc["scale"],
        "origin_offset_m": sk.get("origin_offset_m", sk["size_m"] // 2),
        "world_seed": sk["world_seed"],
        "sha256": dict(sorted(hashes.items())),
    }


def meta_text(doc):
    return json.dumps(doc, sort_keys=True, indent=1) + "\n"


def height_tri(h, sample_m, x, z):
    """Height at map points from a sample field, on the triangles the
    engine's heightmap collision uses: each cell is split along the diagonal
    from (1, 0) to (0, 1). Points are clamped to the field."""
    h = np.asarray(h, dtype=np.float64)
    nz, nx = h.shape
    fx = np.clip(np.asarray(x, dtype=np.float64) / sample_m, 0.0, nx - 1.0)
    fz = np.clip(np.asarray(z, dtype=np.float64) / sample_m, 0.0, nz - 1.0)
    i = np.minimum(np.floor(fx).astype(int), nx - 2)
    j = np.minimum(np.floor(fz).astype(int), nz - 2)
    tx, tz = fx - i, fz - j
    h00, h10, h01, h11 = h[j, i], h[j, i + 1], h[j + 1, i], h[j + 1, i + 1]
    lower = h00 + (h10 - h00) * tx + (h01 - h00) * tz
    upper = h11 + (h01 - h11) * (1.0 - tx) + (h10 - h11) * (1.0 - tz)
    return np.where(tx + tz <= 1.0, lower, upper)


def height_points(h, sk, count=1000):
    """Seeded random map points with the generator's height there (its float
    field on the collision triangles), for the engine's T-05-2 check."""
    rng = np.random.default_rng(sk["world_seed"])
    size = float(sk["size_m"])
    x, z = rng.uniform(0.0, size, count), rng.uniform(0.0, size, count)
    y = height_tri(h, float(sk["sample_m"]), x, z)
    return {"points": [[round(float(a), 4), round(float(b), 4), round(float(c), 4)] for a, b, c in zip(x, z, y)]}
