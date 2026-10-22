#!/usr/bin/env python3
"""Тесты сборки графа MLD на маке (build_osrm_mld.sh) в режиме --dry-run:
порядок шагов, закреплённая версия OSRM, и что скрипт не трогает прод.
Запуск: python3 server/test_build_osrm_mld.py
"""
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "build_osrm_mld.sh")
#: Дайджест образа, который крутится на VPS (docker image inspect, 22.10.2026).
VPS_DIGEST = "sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad"


def dry(*args):
    work = tempfile.mkdtemp()
    env = dict(os.environ)
    env.pop("RADARMAP_OSRM_IMAGE", None)
    done = subprocess.run(["bash", SCRIPT, "--dry-run", "--work", work, *args],
                          capture_output=True, text=True, env=env, timeout=30)
    return done.returncode, done.stdout, done.stderr, work


class DryRunTest(unittest.TestCase):

    def test_country_steps_in_order_on_the_vps_version(self):
        code, out, err, _ = dry()
        self.assertEqual(code, 0, err)
        steps = [line for line in out.splitlines() if "osrm-" in line and "docker run" in line]
        self.assertEqual([next(w for w in s.split() if w.startswith("osrm-")) for s in steps],
                         ["osrm-extract", "osrm-partition", "osrm-customize"], "MLD: extract → partition → customize")
        for line in steps:
            self.assertIn(VPS_DIGEST, line, "та же версия OSRM, что на VPS: иначе граф не откроется")
            self.assertIn("--platform linux/amd64", line)
        self.assertNotIn("osrm-contract", out, "CH не собирается")
        self.assertIn("/opt/car.lua", out)

    def test_city_cuts_the_bbox_first(self):
        code, out, err, work = dry("--city")
        self.assertEqual(code, 0, err)
        cut = out.index("osmium extract")
        self.assertLess(cut, out.index("osrm-extract"))
        self.assertIn("69.05,41.15,69.55,41.48", out)
        self.assertIn(os.path.join(work, "mld-tashkent"), out)

    def test_never_touches_production(self):
        for args in ((), ("--city",), ("--speeds", "/tmp/speeds.csv"), ("--fetch",)):
            code, out, err, _ = dry(*args)
            self.assertEqual(code, 0, err)
            for word in ("ssh ", "scp ", "45.130.148.94", "soulmed.uz", "docker restart", "crontab"):
                self.assertNotIn(word, out, f"{args}: {word}")

    def test_trial_customize_runs_on_a_copy(self):
        code, out, err, work = dry("--speeds", "/tmp/speeds.csv")
        self.assertEqual(code, 0, err)
        trial = os.path.join(work, "mld-uzbekistan.trial")
        self.assertIn(f"cp -R {os.path.join(work, 'mld-uzbekistan')} {trial}", out)
        self.assertIn(f"-v {trial}:/data", out)
        self.assertIn("--segment-speed-file /data/speeds.csv", out)

    def test_fetch_checks_the_download(self):
        code, out, err, _ = dry("--fetch")
        self.assertEqual(code, 0, err)
        self.assertIn("download.geofabrik.de/asia/uzbekistan-latest.osm.pbf.md5", out)

    def test_unknown_key_is_refused(self):
        code, _out, err, _ = dry("--deploy")
        self.assertEqual(code, 2)
        self.assertIn("неизвестный ключ", err)


if __name__ == "__main__":
    unittest.main()
