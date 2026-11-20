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
        # expected heights: the smooth terrain plus the scarp at each place;
        # with noise on, the coast line's own noise stays (only stage-4 noise is masked)
        self.rows, self.rows_noise = [], []
        for p in sk["pois"]:
            x, z = np.array(p["x"]), np.array(p["z"])
            sc = stages.scarp(x, z, sk["scarp"], sk["size_m"])
            self.rows.append((p["id"], p["x"], p["z"], float(stages.macro(x, z, sk, sk["world_seed"], False) + sc)))
            self.rows_noise.append((p["id"], p["x"], p["z"], float(stages.macro(x, z, sk, sk["world_seed"], True) + sc)))

    def tearDown(self):
        self.tmp.cleanup()

    def pois(self, shift=0.0, rows=None):
        path = os.path.join(self.tmp.name, "pois.csv")
        with open(path, "w", encoding="utf-8") as f:
            f.write("id,x,z,y\n")
            for i, (pid, x, z, y) in enumerate(rows or self.rows):
                f.write(f"{pid},{x},{z},{y + (shift if i == 0 else 0.0):.3f}\n")
        return path

    def test_passes_when_heights_match(self):
        r = cli("check-pois", "--until", "scarp", "--sketch", self.sketch, "--pois", self.pois(), "--no-noise")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("POI CHECK: PASS (6 places, until scarp, noise off", r.stdout)

    def test_fails_beyond_the_tolerance(self):
        r = cli("check-pois", "--until", "scarp", "--sketch", self.sketch, "--pois", self.pois(1.5), "--no-noise")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL", r.stdout.splitlines()[0])
        r = cli("check-pois", "--until", "scarp", "--sketch", self.sketch, "--pois", self.pois(1.5), "--no-noise", "--tolerance", "2")
        self.assertEqual(r.returncode, 0)

    def test_noise_is_masked_at_named_places(self):
        r = cli("check-pois", "--until", "scarp", "--sketch", self.sketch, "--pois", self.pois(rows=self.rows_noise))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("noise on, worst 0.00 m", r.stdout)

    def test_unknown_stage(self):
        r = cli("check-pois", "--until", "scarp", "--sketch", self.sketch, "--pois", self.pois(), "--until", "nope")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()


class RoadsCommandTest(unittest.TestCase):
    def test_writes_and_passes(self):
        with tempfile.TemporaryDirectory() as d:
            s, p, out = os.path.join(d, "s.json"), os.path.join(d, "p.csv"), os.path.join(d, "roads.json")
            with open(s, "w", encoding="utf-8") as f:
                json.dump(sketch(), f)
            with open(p, "w", encoding="utf-8") as f:
                f.write("id,x,z,y\nvillage,500,500,0\nfarm,1700,1200,0\n")
            r = cli("roads", "--sketch", s, "--pois", p, "--out", out)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("WAY CHECK: PASS", r.stdout)
            with open(out, encoding="utf-8") as f:
                self.assertIn("track_farm", [w["id"] for w in json.load(f)["ways"]])
            self.assertIn("flat: ", r.stdout)

    def test_reports_a_settlement_without_layout(self):
        with tempfile.TemporaryDirectory() as d:
            sk = sketch()
            del sk["lots"]["street_cross"]
            s, p, out = os.path.join(d, "s.json"), os.path.join(d, "p.csv"), os.path.join(d, "roads.json")
            with open(s, "w", encoding="utf-8") as f:
                json.dump(sk, f)
            with open(p, "w", encoding="utf-8") as f:
                f.write("id,x,z,y,contents\nhamlet,650,1590,0,2 village_house_a\nfarm,1700,1200,0,\n")
            r = cli("roads", "--sketch", s, "--pois", p, "--out", out)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("hamlet: no settlement layout  FAIL", r.stdout)


class GenerateCommandTest(unittest.TestCase):
    def test_T_05_1(self):
        """Generator run twice gives identical SHA-256 for every output file (sample sketch)."""
        from tools.worldgen import files

        with tempfile.TemporaryDirectory() as d:
            s, p = os.path.join(d, "s.json"), os.path.join(d, "p.csv")
            with open(s, "w", encoding="utf-8") as f:
                json.dump(sketch(), f)
            with open(p, "w", encoding="utf-8") as f:
                f.write("id,x,z,y,contents\nvillage,500,500,0,cabin; shed\nfarm,1700,1200,0,farmhouse; barn\n")
            metas = []
            for run_dir in ("a", "b"):
                out = os.path.join(d, run_dir)
                r = cli("generate", "--sketch", s, "--pois", p, "--out", out)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                with open(os.path.join(out, "meta.json"), encoding="utf-8") as f:
                    metas.append(json.load(f))
            self.assertEqual(metas[0]["sha256"], metas[1]["sha256"])
            self.assertEqual(set(metas[0]["sha256"]), {"height.bin", "normal.bin", "biome.bin", "water.json", "roads.json"})
            with open(os.path.join(d, "a", "height.bin"), "rb") as f:
                raw = files.decompress(f.read())
            n = sketch()["size_m"] // sketch()["sample_m"] + 1
            self.assertEqual(len(raw), n * n * 2, "4097-style square of u16 for this map")
