"""A small made-up sketch for the stage tests (2,048 m map)."""
import copy

SAMPLE = {
    "version": 1,
    "world_seed": 11,
    "size_m": 2048,
    "sample_m": 2,
    "ramp": {"h0": 10.0, "kx": 0.01, "kz": 0.02, "z_ref": 2048.0},
    "bumps": [
        {"id": "big", "x": 1500.0, "z": 400.0, "r": 600.0, "h": 300.0},
        {"id": "small", "x": 600.0, "z": 1400.0, "r": 200.0, "h": 20.0},
    ],
    "coast": {
        "west": {"base": 200.0, "amp": 60.0, "wavelength": 300.0},
        "south": {"base": 1850.0, "amp": 50.0, "wavelength": 300.0},
        "blend_m": 300.0,
        "shore_h": -6.0,
        "sea_slope": 0.02,
        "sea_min_h": -40.0,
    },
}


def sketch():
    return copy.deepcopy(SAMPLE)
