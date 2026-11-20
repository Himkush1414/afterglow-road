"""Water file tests, including T-05-4 on the sample sketch."""
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest

from tools.worldgen import water
from tools.worldgen.tests.sample import sketch

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


class WaterFileTest(unittest.TestCase):
    def test_T_05_4(self):
        """River levels are non-increasing from source to mouth; the lake level is the sketch level."""
        sk = sketch()
        doc = water.document(sk)
        self.assertEqual(water.check(doc, sk), [])
        self.assertEqual([r["id"] for r in doc["rivers"]], ["brook", "brook_low", "ditch", "rill"])
        for r in doc["rivers"]:
            self.assertTrue(all(b <= a for a, b in zip(r["level"], r["level"][1:])), r["id"])
        self.assertEqual([lk["level"] for lk in doc["lakes"]], [sk["lake"]["level"]])

    def test_check_finds_a_rising_level_and_a_wrong_lake(self):
        sk = sketch()
        doc = copy.deepcopy(water.document(sk))
        doc["rivers"][0]["level"][5] = doc["rivers"][0]["level"][4] + 0.01
        doc["lakes"][0]["level"] = 49.0
        errors = water.check(doc, sk)
        self.assertEqual(len(errors), 2, errors)

    def test_schema_and_byte_stable_text(self):
        sk = sketch()
        doc = water.document(sk)
        self.assertEqual(set(doc), {"sea_level_y", "lakes", "rivers"})
        self.assertEqual(set(doc["rivers"][0]), {"id", "kind", "centre", "width", "level"})
        self.assertEqual(water.dumps(doc), water.dumps(water.document(sketch())))
        self.assertEqual(json.loads(water.dumps(doc)), doc)

    def test_cli_writes_and_checks(self):
        with tempfile.TemporaryDirectory() as d:
            s, p, out = os.path.join(d, "s.json"), os.path.join(d, "p.csv"), os.path.join(d, "water.json")
            with open(s, "w", encoding="utf-8") as f:
                json.dump(sketch(), f)
            with open(p, "w", encoding="utf-8") as f:
                f.write("id,x,z,y\nvillage,500,500,0\nfarm,1700,1200,0\n")
            args = [sys.executable, "-m", "tools.worldgen", "water", "--sketch", s, "--pois", p, "--out", out]
            r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("WATER CHECK: PASS", r.stdout)
            with open(out, "rb") as f:
                first = f.read()
            subprocess.run(args, cwd=ROOT, capture_output=True, check=True)
            with open(out, "rb") as f:
                self.assertEqual(f.read(), first, "same input, same bytes")


if __name__ == "__main__":
    unittest.main()
