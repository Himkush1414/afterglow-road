"""Sample grid over map coordinates (x east, z south, metres)."""
from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Grid:
    x0: float
    z0: float
    sample_m: float
    nx: int
    nz: int

    @staticmethod
    def full(size_m, sample_m):
        """The whole map: size_m / sample_m + 1 samples per side."""
        n = int(round(size_m / sample_m)) + 1
        return Grid(0.0, 0.0, float(sample_m), n, n)

    @staticmethod
    def crop(centre_x, centre_z, size_m, sample_m):
        """A size_m square around a centre, aligned to the full map's samples."""
        half = size_m / 2.0
        x0 = round((centre_x - half) / sample_m) * sample_m
        z0 = round((centre_z - half) / sample_m) * sample_m
        n = int(round(size_m / sample_m)) + 1
        return Grid(float(x0), float(z0), float(sample_m), n, n)

    def coords(self):
        """x and z of every sample, each shaped (nz, nx); row 0 is north."""
        xs = self.x0 + np.arange(self.nx, dtype=np.float64) * self.sample_m
        zs = self.z0 + np.arange(self.nz, dtype=np.float64) * self.sample_m
        return np.meshgrid(xs, zs)

    def offset_in(self, other):
        """(row, column) of this grid's first sample inside a larger grid."""
        return (
            int(round((self.z0 - other.z0) / self.sample_m)),
            int(round((self.x0 - other.x0) / self.sample_m)),
        )
