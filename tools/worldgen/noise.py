"""Seeded value noise from integer hashing (no random generator state), so
the same seed gives the same numbers on every machine and numpy version."""
import numpy as np

_M32 = np.uint64(0xFFFFFFFF)


def _hash(ix, iz, seed):
    """32-bit hash of integer lattice coordinates and a seed, as uint64."""
    h = (ix.astype(np.int64).astype(np.uint64) * np.uint64(0x9E3779B1)) & _M32
    h ^= (iz.astype(np.int64).astype(np.uint64) * np.uint64(0x85EBCA77)) & _M32
    h ^= np.uint64(seed & 0xFFFFFFFF) * np.uint64(0xC2B2AE3D) & _M32
    h ^= h >> np.uint64(15)
    h = (h * np.uint64(0x2C1B3C6D)) & _M32
    h ^= h >> np.uint64(12)
    h = (h * np.uint64(0x297A2D39)) & _M32
    h ^= h >> np.uint64(15)
    return h


def _lattice(ix, iz, seed):
    """Lattice value in -1..1."""
    return _hash(ix, iz, seed).astype(np.float64) / 2147483647.5 - 1.0


def _fade(t):
    return t * t * (3.0 - 2.0 * t)


def value2(x, z, wavelength, seed):
    """2-D value noise in -1..1 at world positions x, z (arrays)."""
    fx = np.asarray(x, dtype=np.float64) / wavelength
    fz = np.asarray(z, dtype=np.float64) / wavelength
    ix, iz = np.floor(fx), np.floor(fz)
    tx, tz = _fade(fx - ix), _fade(fz - iz)
    ix, iz = ix.astype(np.int64), iz.astype(np.int64)
    a = _lattice(ix, iz, seed)
    b = _lattice(ix + 1, iz, seed)
    c = _lattice(ix, iz + 1, seed)
    d = _lattice(ix + 1, iz + 1, seed)
    return (a + (b - a) * tx) * (1 - tz) + (c + (d - c) * tx) * tz


def value1(t, wavelength, seed):
    """1-D value noise in -1..1."""
    t = np.asarray(t, dtype=np.float64)
    return value2(t, np.zeros_like(t), wavelength, seed)


def fbm(x, z, wavelength, seed, octaves=5, gain=0.5, lacunarity=2.0):
    """Fractal sum of value noise, normalised to -1..1."""
    total, amp, norm, wl = 0.0, 1.0, 0.0, float(wavelength)
    for o in range(octaves):
        total = total + amp * value2(x, z, wl, seed + 1013 * o)
        norm += amp
        amp *= gain
        wl /= lacunarity
    return total / norm


def ridged(x, z, wavelength, seed, octaves=4, gain=0.5, lacunarity=2.0):
    """Ridged fractal noise in 0..1 (sharp crests where the noise crosses 0)."""
    total, amp, norm, wl = 0.0, 1.0, 0.0, float(wavelength)
    for o in range(octaves):
        total = total + amp * (1.0 - np.abs(value2(x, z, wl, seed + 7919 * o)))
        norm += amp
        amp *= gain
        wl /= lacunarity
    return total / norm
