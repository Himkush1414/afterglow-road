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
    "lake": {"id": "pond", "x": 1000.0, "z": 1000.0, "level": 50.0, "a": 200.0, "b": 120.0, "max_depth": 5.0, "shore_blend_m": 30.0},
    "lines": [
        {"id": "lane", "kind": "road", "width_m": 7, "points": [[300.0, 1700.0], [900.0, 1500.0], [1900.0, 1600.0]]},
        {"id": "brook", "kind": "river", "chain": "b", "width_m": [4, 8], "depth_m": [0.3, 1.0], "points": [[1600.0, 1000.0], [1200.0, 1000.0]]},
        {"id": "brook_low", "kind": "river", "chain": "b", "start": "lake", "width_m": [4, 8], "depth_m": [0.3, 1.0], "points": [[800.0, 1000.0], [500.0, 1300.0], [150.0, 1400.0]]},
        {"id": "rill", "kind": "stream", "width_m": [2, 2], "depth_m": [0.3, 0.3], "points": [[1500.0, 300.0], [1450.0, 900.0]]},
    ],
    "pois": [{"id": "village", "x": 500.0, "z": 500.0, "y": 0.0}, {"id": "farm", "x": 1700.0, "z": 1200.0, "y": 0.0}],
    "biomes": [
        {"id": 0, "name": "sea", "rule": {"height_below": 0, "not_water": True}},
        {"id": 1, "name": "beach", "rule": {"any": [{"height_between": [0, 2.5], "near_sea_m": 60}, {"near_lake_edge_m": 12}]}},
        {"id": 7, "name": "high", "rule": {"height_above": 250}},
        {"id": 6, "name": "hills", "rule": {"any": [{"bumps_above": {"ids": ["big"], "m": 100}}, {"slope_above_deg": 32}]}},
        {"id": 4, "name": "wet", "rule": {"any": [{"near_point": {"x": 1800, "z": 1800, "m": 150}}, {"near_water_m": 40, "slope_below_deg": 3}]}},
        {"id": 9, "name": "town", "rule": {"near_pois": {"village": 100}}},
        {"id": 3, "name": "field", "rule": {"rects": [[100, 1500, 600, 1800]]}},
        {"id": 2, "name": "forest", "rule": {}},
    ],
    "noise": {
        "octaves": 5,
        "wavelength": 300.0,
        "gain": 0.5,
        "lacunarity": 2.0,
        "blend_m": 100.0,
        "amplitude": {"forest": 14.0, "field": 6.0, "wet": 2.0, "town": 3.0, "hills": 45.0, "high": 70.0, "beach": 1.0},
        "ridged": {"wavelength": 150.0, "amplitude": {"hills": 40.0, "high": 80.0}},
        "worst_case_m": 150.0,
    },
    "corridor": {"d0": 20.0, "d1": 160.0, "poi_r_m": {"default": 0.0, "village": 100.0}, "discs": [{"x": 1700.0, "z": 300.0, "r": 40.0}]},
    "vista": {"from": [1200.0, 1300.0], "bearing_deg": 43.0, "width_m": 60.0, "length_m": 400.0},
    "rivers": {"bank_deg": 30.0, "valley_m": 150.0, "valley_depth_m": 12.0, "max_incision_m": 14.0},
    "scarp": {"edges": ["north", "east"], "band_m": 200.0, "height_m": 160.0, "full_at_m": 110.0, "noise_free_m": 64.0},
}


def sketch():
    return copy.deepcopy(SAMPLE)
