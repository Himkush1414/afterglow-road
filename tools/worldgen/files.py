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
