#!/usr/bin/env python3
"""Тесты цикла пробок на стенде MLD (traffic_customize.sh) без Docker: вместо
docker — заглушка, которая пишет свои вызовы в журнал и изображает
osrm-customize (создаёт выходные файлы и переписывает входные НА МЕСТЕ, как
настоящий). Проверяется то, что нельзя сломать: эталон цел, слоты чередуются,
прод не задет, без пробок customize не идёт, упавший customize — граф без
пробок, а не прошлая пробка.
Запуск: python3 server/osrm/test_traffic_customize.py
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "traffic_customize.sh")
FILES = ("mldgr", "geometry", "cell_metrics", "datasource_names", "partition", "cells", "ebg", "properties",
         "turn_weight_penalties", "turn_duration_penalties")
TURN_FILES = ("turn_weight_penalties", "turn_duration_penalties")   # переписываются со штрафами манёвров
REWRITTEN = ("mldgr", "geometry")          # customize читает и пишет на месте
CREATED = ("cell_metrics", "datasource_names")   # customize только пишет

STUB = r"""#!/bin/bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  inspect) exit 1 ;;                      # контейнера стенда нет: без пробы
  restart) exit 0 ;;
  run)
    [ -n "${DOCKER_FAIL:-}" ] && exit 137 # предел памяти
    data=""; turns=0
    while [ $# -gt 0 ]; do
      case "$1" in -v) data="${2%%:/data}"; shift ;; --turn-penalty-file) turns=1 ;; esac
      shift
    done
    # Как osrm-customize: вход переписывается на месте, выход создаётся
    # (опыт 33B: со штрафами манёвров — и файлы штрафов на месте).
    if [ "$turns" = 1 ]; then
      for f in turn_weight_penalties turn_duration_penalties; do printf customized > "$data/uzbekistan.osrm.$f"; done
    fi
    for f in mldgr geometry; do printf customized > "$data/uzbekistan.osrm.$f"; done
    for f in cell_metrics datasource_names; do printf customized > "$data/uzbekistan.osrm.$f"; done
    exit 0 ;;
esac
"""


class Stand(unittest.TestCase):
    """Корень стенда во временном каталоге и заглушка docker."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "pristine"))
        for ext in FILES:
            with open(self.path("pristine", ext), "w") as f:
                f.write(f"pristine {ext}")
        self.stub = os.path.join(self.root, "docker-stub")
        with open(self.stub, "w") as f:
            f.write(STUB)
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.root, "docker.log")

    def tearDown(self):
        shutil.rmtree(self.root)

    def path(self, slot, ext):
        return os.path.join(self.root, slot, f"uzbekistan.osrm.{ext}")

    def speeds(self, body):
        path = os.path.join(self.root, "in.csv")
        with open(path, "w") as f:
            f.write(body)
        return path

    def turns(self, body):
        path = os.path.join(self.root, "turns-in.csv")
        with open(path, "w") as f:
            f.write(body)
        return path

    def cycle(self, body, *extra, env=None, check=True):
        full = dict(os.environ, RADARMAP_OSRM_MLD=self.root, RADARMAP_DOCKER=self.stub, DOCKER_LOG=self.log)
        full.update(env or {})
        done = subprocess.run(["bash", SCRIPT, "--speeds", self.speeds(body), *extra],
                              capture_output=True, text=True, env=full, timeout=60)
        if check:
            self.assertEqual(done.returncode, 0, done.stderr)
        self.last = done
        return done

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def current(self):
        return os.readlink(os.path.join(self.root, "current"))

    def read(self, slot, ext):
        with open(self.path(slot, ext)) as f:
            return f.read()

    def assert_pristine_intact(self):
        for ext in FILES:
            self.assertEqual(self.read("pristine", ext), f"pristine {ext}", f"эталон .{ext} испорчен")


class CycleTest(Stand):

    def test_jam_cycle_customizes_a_slot_built_from_pristine(self):
        self.cycle("1,2,40.0,1.389\n")
        self.assertEqual(self.current(), "a")
        self.assert_pristine_intact()
        for ext in REWRITTEN + CREATED:
            self.assertEqual(self.read("a", ext), "customized")
            self.assertNotEqual(os.stat(self.path("a", ext)).st_ino, os.stat(self.path("pristine", ext)).st_ino,
                                f".{ext} переписывается — жёсткая ссылка испортила бы эталон")
        for ext in set(FILES) - set(REWRITTEN) - set(CREATED) - set(TURN_FILES):
            self.assertEqual(os.stat(self.path("a", ext)).st_ino, os.stat(self.path("pristine", ext)).st_ino,
                             f".{ext} customize не трогает — общий с эталоном")
        run = [c for c in self.calls() if c.startswith("run ")]
        self.assertEqual(len(run), 1)
        for word in ("-m 900m", "--memory-swap 900m", "--cpus 1", "osrm-customize -t 1",
                     "--segment-speed-file /data/speeds.csv", "/data/uzbekistan.osrm"):
            self.assertIn(word, run[0])
        self.assertTrue(os.path.exists(os.path.join(self.root, "customize.log")), "журнал customize — в файл, не в cron")
        self.assertEqual(len(self.last.stdout.strip().splitlines()), 1, "в журнал cron — одна строка цикла")
        self.assertIn("inspect radarmap-osrm-mld", self.calls())
        self.assertIn("контейнера radarmap-osrm-mld нет", self.last.stdout)

    def test_customize_takes_cores_and_memory_from_the_machine_plan(self):
        server = os.path.dirname(os.path.dirname(os.path.abspath(SCRIPT)))
        self.cycle("1,2,40.0,1.389\n", env={"RADARMAP_OSRM_MLD_BIN": server, "RADARMAP_CUSTOMIZE_CPUS": "3",
                                            "RADARMAP_CUSTOMIZE_MEMORY_MB": "1500"})
        run = [c for c in self.calls() if c.startswith("run ")][0]
        for word in ("-m 1500m", "--memory-swap 1500m", "--cpus 3", "osrm-customize -t 3"):
            self.assertIn(word, run)

    def test_turn_penalties_copy_the_files_customize_rewrites(self):
        self.cycle("", "--turns", self.turns("1,2,3,40\n"))
        self.assertEqual(self.current(), "a")
        self.assert_pristine_intact()
        run = [c for c in self.calls() if c.startswith("run ")]
        self.assertEqual(len(run), 1, "манёвры без пробок — customize всё равно нужен")
        self.assertIn("--turn-penalty-file /data/turns.csv", run[0])
        self.assertNotIn("--segment-speed-file", run[0], "пустой файл скоростей не передаётся")
        for ext in TURN_FILES:
            self.assertEqual(self.read("a", ext), "customized")
            self.assertNotEqual(os.stat(self.path("a", ext)).st_ino, os.stat(self.path("pristine", ext)).st_ino,
                                f".{ext} переписывается со штрафами — жёсткая ссылка испортила бы эталон")
        with open(os.path.join(self.root, "a", "turns.csv")) as f:
            self.assertEqual(f.read(), "1,2,3,40\n")
        # Те же файлы — без изменений; другой штраф — новый слот.
        self.assertIn("без изменений", self.cycle("", "--turns", self.turns("1,2,3,40\n")).stdout)
        self.cycle("", "--turns", self.turns("1,2,3,50\n"))
        self.assertEqual(self.current(), "b")
        # Без манёвров файлы штрафов снова общие с эталоном.
        self.cycle("1,2,40.0,1.389\n")
        for ext in TURN_FILES:
            self.assertEqual(os.stat(self.path("a", ext)).st_ino, os.stat(self.path("pristine", ext)).st_ino)

    def test_slots_alternate_and_unchanged_file_is_skipped(self):
        self.cycle("1,2,40.0,1.389\n")
        self.assertEqual(self.current(), "a")
        before = len(self.calls())
        done = self.cycle("1,2,40.0,1.389\n")
        self.assertIn("без изменений", done.stdout)
        self.assertEqual(len(self.calls()), before, "без изменений — ни customize, ни перезапуска")
        self.cycle("1,2,40.0,2.778\n")
        self.assertEqual(self.current(), "b")
        self.cycle("3,4,30.0,1.389\n")
        self.assertEqual(self.current(), "a")
        with open(os.path.join(self.root, "a", "speeds.csv")) as f:
            self.assertEqual(f.read(), "3,4,30.0,1.389\n", "слот собран заново, не поверх прошлой пробки")
        self.assertFalse(os.path.exists(os.path.join(self.root, "a.new")))
        self.assert_pristine_intact()

    def test_force_rebuilds_an_unchanged_file(self):
        self.cycle("1,2,40.0,1.389\n")
        self.cycle("1,2,40.0,1.389\n", "--force")
        self.assertEqual(self.current(), "b")

    def test_no_jams_means_the_pristine_graph_without_customize(self):
        self.cycle("")
        self.assertEqual(self.current(), "a")
        self.assertFalse([c for c in self.calls() if c.startswith("run ")], "пустой файл — customize не нужен")
        for ext in FILES:
            self.assertEqual(self.read("a", ext), f"pristine {ext}", "метрика эталона — граф без пробок")
        self.assert_pristine_intact()

    def test_failed_customize_falls_back_to_no_jams(self):
        done = self.cycle("1,2,40.0,1.389\n", env={"DOCKER_FAIL": "1"})
        self.assertIn("слот без пробок", done.stdout)
        self.assertEqual(self.current(), "a")
        for ext in FILES:
            self.assertEqual(self.read("a", ext), f"pristine {ext}")
        self.assertEqual(os.path.getsize(os.path.join(self.root, "a", "speeds.csv")), 0)
        self.assert_pristine_intact()

    def test_refuses_production(self):
        for env in ({"RADARMAP_OSRM_MLD_CONTAINER": "radarmap-osrm"},
                    {"RADARMAP_OSRM_MLD_PORT": "8092"},
                    {"RADARMAP_OSRM_MLD": "/opt/radarmap/osrm-29e"},
                    {"RADARMAP_OSRM_MLD": "/opt/radarmap/osrm"}):
            done = self.cycle("1,2,40.0,1.389\n", env=env, check=False)
            self.assertEqual(done.returncode, 2, env)
            self.assertIn("отказ", done.stderr)
        self.assertEqual(self.calls(), [])

    def test_never_mentions_production(self):
        with open(SCRIPT, encoding="utf-8") as f:
            body = f.read()
        code = "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("nginx", code)
        self.assertIn("8094", code)
        # 8092 и radarmap-osrm встречаются только в отказах.
        for line in code.splitlines():
            if "8092" in line or "radarmap-osrm)" in line:
                self.assertIn("отказ", line)

    def test_dry_run_changes_nothing(self):
        done = self.cycle("1,2,40.0,1.389\n", "--dry-run")
        self.assertIn("osrm-customize", done.stdout)
        self.assertIn("restart -t 5 radarmap-osrm-mld", done.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.root, "current")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "a")))
        self.assertEqual(self.calls(), [])


# traffic_speeds.py стенда для цикла без --speeds: расчёт подменён (пишет файл
# из FAKE_SPEEDS и сведения из FAKE_META), а --decide — настоящий.
SPEEDS_WRAPPER = r"""
import os, sys
sys.path.insert(0, os.environ["SERVER_DIR"])
import traffic_speeds as ts
argv = sys.argv[1:]
if "--decide" in argv:
    sys.exit(ts.main(argv))
out = argv[argv.index("--out") + 1]
turns = argv[argv.index("--turns-out") + 1]
with open(os.environ["FAKE_SPEEDS"]) as f:
    body = f.read()
with open(out, "w") as f:
    f.write(body)
with open(turns, "w") as f:
    pass
with open(out + ".meta", "w") as f:
    f.write(os.environ["FAKE_META"])
"""


class GateTest(Stand):
    """38A: цикл cron (без --speeds) спрашивает traffic_speeds.py --decide и
    пропускает customize при малом дрейфе в том же часе недели."""

    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "traffic_speeds.py"), "w") as f:
            f.write(SPEEDS_WRAPPER)

    def auto(self, rows, slot=104, live=0):
        body = "".join(f"{u},{u + 1},50.0,{rate}\n" for u, rate in rows)
        path = self.speeds(body)
        env = dict(os.environ, RADARMAP_OSRM_MLD=self.root, RADARMAP_DOCKER=self.stub, DOCKER_LOG=self.log,
                   RADARMAP_OSRM_MLD_BIN=self.bin, SERVER_DIR=os.path.dirname(HERE), FAKE_SPEEDS=path,
                   FAKE_META='{"slot": %d, "live": %d, "events": 0}' % (slot, live))
        done = subprocess.run(["bash", SCRIPT], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def runs(self):
        return len([c for c in self.calls() if c.startswith("run ")])

    def test_small_drift_is_skipped_and_said_so(self):
        base = [(u, "5.000") for u in range(0, 2000, 2)]          # 1000 рёбер
        self.auto(base)
        self.assertEqual((self.current(), self.runs()), ("a", 1))
        with open(os.path.join(self.root, "a", "speeds.csv.meta")) as f:
            self.assertIn('"slot": 104', f.read(), "сведения расчёта — в слоте")
        drift = [(u, "4.000") for u, _ in base[:30]] + base[30:]  # 3 %
        out = self.auto(drift)
        self.assertIn("пропущено:", out)
        self.assertIn("ниже порога", out)
        self.assertEqual((self.current(), self.runs()), ("a", 1), "ни слота, ни customize")
        more = [(u, "4.000") for u, _ in base[:120]] + base[120:]  # 12 % от загруженного
        out = self.auto(more)
        self.assertEqual((self.current(), self.runs()), ("b", 2))
        self.assertIn("изменено 120 из 1000", out)

    def test_new_hour_live_edges_and_clearing_always_run(self):
        base = [(u, "5.000") for u in range(0, 2000, 2)]
        self.auto(base)
        drift = [(u, "4.000") for u, _ in base[:5]] + base[5:]
        out = self.auto(drift, slot=105)
        self.assertIn("104 → 105", out)
        self.assertEqual(self.current(), "b")
        drift2 = [(u, "3.000") for u, _ in base[:5]] + base[5:]
        self.assertIn("живых рёбер 1", self.auto(drift2, slot=105, live=1))
        self.assertEqual(self.current(), "a")
        self.assertIn("сняты", self.auto([], slot=105))
        self.assertEqual(self.current(), "b")

    def test_gate_failure_runs_as_before(self):
        base = [(u, "5.000") for u in range(0, 200, 2)]
        self.auto(base)
        # Старый traffic_speeds.py без --decide: argparse — код 2, цикл как раньше.
        with open(os.path.join(self.bin, "traffic_speeds.py")) as f:
            body = f.read()
        with open(os.path.join(self.bin, "traffic_speeds.py"), "w") as f:
            f.write(body.replace('    sys.exit(ts.main(argv))', '    sys.exit(2)'))
        out = self.auto([(u, "4.000") for u, _ in base[:1]] + base[1:])
        self.assertIn("ворота не ответили (код 2)", out)
        self.assertEqual(self.current(), "b")


if __name__ == "__main__":
    unittest.main()
