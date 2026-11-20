"""Command-line tests (run as a subprocess, as a user would)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

import numpy as np

from tools.worldgen import stages
from tools.worldgen.tests.sample import sketch

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def cli(*args):
    return subprocess.run(
        [sys.executable, "-m", "tools.worldgen", *args], cwd=ROOT, capture_output=True, text=True
    )


class CheckPoisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        sk = sketch()
        self.sketch = os.path.join(self.tmp.name, "sketch.json")
        with open(self.sketch, "w", encoding="utf-8") as f:
            json.dump(sk, f)
        # expected heights: the smooth terrain plus the scarp at each place
        self.rows = []
        for p in sk["pois"]:
            x, z = np.array(p["x"]), np.array(p["z"])
            y = float(stages.macro(x, z, sk, sk["world_seed"], False) + stages.scarp(x, z, sk["scarp"], sk["size_m"]))
            self.rows.append((p["id"], p["x"], p["z"], y))

    def tearDown(self):
        self.tmp.cleanup()

    def pois(self, shift=0.0):
        path = os.path.join(self.tmp.name, "pois.csv")
        with open(path, "w", encoding="utf-8") as f:
            f.write("id,x,z,y\n")
            for i, (pid, x, z, y) in enumerate(self.rows):
                f.write(f"{pid},{x},{z},{y + (shift if i == 0 else 0.0):.3f}\n")
        return path

    def test_passes_when_heights_match(self):
        r = cli("check-pois", "--sketch", self.sketch, "--pois", self.pois(), "--no-noise")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("POI CHECK: PASS (2 places, until scarp, noise off", r.stdout)

    def test_fails_beyond_the_tolerance(self):
        r = cli("check-pois", "--sketch", self.sketch, "--pois", self.pois(1.5), "--no-noise")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL", r.stdout.splitlines()[0])
        r = cli("check-pois", "--sketch", self.sketch, "--pois", self.pois(1.5), "--no-noise", "--tolerance", "2")
        self.assertEqual(r.returncode, 0)

    def test_noise_is_masked_at_named_places(self):
        r = cli("check-pois", "--sketch", self.sketch, "--pois", self.pois())
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("noise on", r.stdout)

    def test_unknown_stage(self):
        r = cli("check-pois", "--sketch", self.sketch, "--pois", self.pois(), "--until", "nope")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
