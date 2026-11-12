#!/usr/bin/env python3
"""Тесты чистой логики graph_refresh.py: ворота нагрузки VPS, ворота аудита,
чистка кандидатов, разбор журналов OSRM и текст подмены. Без сети и Docker.
Запуск: python3 server/osrm/test_graph_refresh.py
"""
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import graph_refresh as g  # noqa: E402

EXTRACT_LOG = """[2026-10-26T05:51:26] [info] Found 3 turn restriction tags:
[2026-10-26T05:51:41] [info] Raw input contains 17495480 nodes, 2624269 ways, and 343 relations, 1216 restrictions
[2026-10-26T05:51:52] [info] Removing invalid turn restrictions...removed 66 invalid turn restrictions, after 0.0011s
[2026-10-26T05:51:52] [info] Constructing restriction graph on 1124 restrictions...ok, after 0.000763s
[2026-10-26T05:51:52] [info] Generated 2289391 nodes (19 of which are duplicates)  and 3705913 segments in edge-expanded graph
[2026-10-26T05:52:10] [info] Node-based graph contains 2283555 edges
[2026-10-26T05:52:22] [info] RAM: peak bytes used: 3133734912
"""

QUIET_NIGHT = {"hhmm": "03:40", "load1": 0.2, "load5": 0.3, "mem_avail_mb": 1500,
               "disk_free_mb": 12000, "inodes_free": 900000, "customize_lock": False}


def variant(dist=10000, dur=900, restr=0):
    return {"distance": dist, "duration": dur, "restrictions": restr}


def run(pairs, graph=None):
    return {"pairs": pairs, "graph": graph or {"restrictions_used": 1124, "node_edges": 2283555}}


class OsrmLog(unittest.TestCase):
    def test_extract_numbers(self):
        r = g.parse_osrm_log(EXTRACT_LOG)
        self.assertEqual(r["peak_mb"], 2989)
        self.assertEqual((r["restrictions_raw"], r["restrictions_invalid"], r["restrictions_used"]), (1216, 66, 1124))
        self.assertEqual(r["node_edges"], 2283555)
        self.assertEqual((r["ebg_nodes"], r["ebg_segments"]), (2289391, 3705913))

    def test_last_peak_wins_and_empty_log(self):
        self.assertEqual(g.parse_osrm_log("RAM: peak bytes used: 1048576\nRAM: peak bytes used: 2097152")["peak_mb"], 2)
        self.assertEqual(g.parse_osrm_log("ничего"), {})

    def test_sha_lines_skip_header(self):
        sha = "a" * 64
        text = f"image x\npbf 35c7\nbuilt 2026\nalgorithm mld\nprofile p {'b' * 64}\n{sha}  uzbekistan.osrm.ebg\n"
        self.assertEqual(g.sha_lines(text), [f"{sha}  uzbekistan.osrm.ebg"])

    def test_image_from_build_script(self):
        self.assertTrue(g.image_digest().startswith("ghcr.io/project-osrm/osrm-backend@sha256:"))


class LoadGate(unittest.TestCase):
    def test_quiet_night_passes(self):
        self.assertEqual(g.gate_reasons(QUIET_NIGHT, need_mb=1700), [])

    def test_window_edges(self):
        for hhmm, ok in (("01:59", False), ("02:00", True), ("05:30", True), ("05:31", False), ("20:46", False)):
            self.assertEqual(g.in_window(hhmm), ok, hhmm)

    def test_each_reason_blocks(self):
        for key, value, word in (("hhmm", "20:46", "не ночь"), ("load1", 0.5, "load"),
                                 ("mem_avail_mb", 800, "памяти"), ("customize_lock", True, "цикл пробок"),
                                 ("disk_free_mb", 3000, "диск"), ("inodes_free", 50000, "inode")):
            reasons = g.gate_reasons(dict(QUIET_NIGHT, **{key: value}), need_mb=1700)
            self.assertEqual(len(reasons), 1, key)
            self.assertIn(word, reasons[0])

    def test_during_upload_tolerates_own_load(self):
        snap = dict(QUIET_NIGHT, load1=0.8)
        self.assertTrue(g.gate_reasons(snap))
        self.assertEqual(g.gate_reasons(snap, during=True), [])
        self.assertTrue(g.gate_reasons(dict(snap, load1=1.2), during=True))

    def test_any_time_drops_only_the_window(self):
        day = dict(QUIET_NIGHT, hhmm="14:10")
        self.assertTrue(g.gate_reasons(day))
        self.assertEqual(g.gate_reasons(day, any_time=True, need_mb=1700), [])
        busy = g.gate_reasons(dict(day, load1=0.7, customize_lock=True), any_time=True)
        self.assertEqual(len(busy), 2)

    def test_missing_numbers_mean_no(self):
        self.assertEqual(len(g.gate_reasons({"hhmm": "03:00"})), 2)   # load и память неизвестны

    def test_parse_snapshot(self):
        s = g.parse_snapshot("hhmm=03:12\nload1=0.26\nload5=0.15\nmem_avail_mb=1520\ndisk_free_mb=12594\n"
                             "inodes_free=968142\ncustomize_lock=0\nentry=a\nentry=pristine\n"
                             "entry=candidate-2026-11-03\nmount=/opt/radarmap/osrm-mld\nmount=/opt/radarmap/osrm-29e\n")
        self.assertEqual(s["load1"], 0.26)
        self.assertFalse(s["customize_lock"])
        self.assertEqual(s["entries"], ["a", "pristine", "candidate-2026-11-03"])
        self.assertEqual(len(s["mounts"]), 2)
        self.assertEqual(g.gate_reasons(s), [])


class Prune(unittest.TestCase):
    ENTRIES = ["a", "b", "bin", "current", "pristine", "test", "speeds.csv",
               "candidate-2026-10-27", "candidate-2026-11-03", "candidate-2026-11-10.part",
               "ch-candidate-2026-10-27", "ch-candidate-2026-11-03", "ch-candidate-2026-11-10",
               "candidate-2026-10-20.part", "candidate-2026-11-03.failed"]

    def test_keeps_new_and_one_previous(self):
        self.assertEqual(g.prune_plan(self.ENTRIES, "mld", "2026-11-10"),
                         ["candidate-2026-10-20.part", "candidate-2026-10-27"])
        self.assertEqual(g.prune_plan(self.ENTRIES, "ch", "2026-11-10"), ["ch-candidate-2026-10-27"])

    def test_never_live_or_mounted(self):
        drop = g.prune_plan(self.ENTRIES, "mld", "2026-11-10", mounts=["/opt/radarmap/osrm-mld/candidate-2026-10-27/"])
        self.assertEqual(drop, ["candidate-2026-10-20.part"])
        for kind in ("mld", "ch"):
            self.assertFalse(set(g.prune_plan(self.ENTRIES, kind, "2026-11-10")) & g.LIVE_ENTRIES)

    def test_kinds_do_not_mix(self):
        self.assertEqual(g.prune_plan(["ch-candidate-2026-10-01", "ch-candidate-2026-10-08"], "mld", "2026-11-10"), [])

    def test_failed_is_left_to_owner(self):
        self.assertNotIn("candidate-2026-11-03.failed", g.prune_plan(self.ENTRIES, "mld", "2026-11-10"))

    def test_names(self):
        self.assertEqual(g.candidate_name("mld", "2026-11-10"), "candidate-2026-11-10")
        self.assertEqual(g.candidate_name("ch", "2026-11-10", part=True), "ch-candidate-2026-11-10.part")


class LocalPrune(unittest.TestCase):
    def test_three_newest_and_live(self):
        dates = ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10", "2026-11-17", "notes", "x.tmp"]
        self.assertEqual(g.local_prune_plan(dates, keep=set()), ["2026-10-20", "2026-10-27"])
        self.assertEqual(g.local_prune_plan(dates, keep={"2026-10-27", "osrm"}), ["2026-10-20"])
        self.assertEqual(g.local_prune_plan(dates[:2], keep=set()), [])


class AuditGate(unittest.TestCase):
    def pairs(self, n=20, **over):
        base = {f"p{i:02}": {"variants": [variant(), variant(11000, 1000)]} for i in range(n)}
        base.update(over)
        return base

    def test_same_graph_passes(self):
        c = g.compare(run(self.pairs()), run(self.pairs()))
        self.assertTrue(c["pass"], c["fails"])
        self.assertEqual(c["slower_pairs"], 0)

    def test_new_violation_fails(self):
        c = g.compare(run(self.pairs()), run(self.pairs(p03={"variants": [variant(restr=1)]})))
        self.assertFalse(c["pass"])
        self.assertTrue(any("первых" in f for f in c["fails"]))

    def test_violation_in_alternative_fails(self):
        c = g.compare(run(self.pairs()), run(self.pairs(p03={"variants": [variant(), variant(restr=2)]})))
        self.assertEqual(c["violations_first"], [0, 0])
        self.assertEqual(c["violations_all"], [0, 2])
        self.assertFalse(c["pass"])

    def test_fixed_violation_is_fine(self):
        c = g.compare(run(self.pairs(p03={"variants": [variant(restr=1)]})), run(self.pairs()))
        self.assertTrue(c["pass"], c["fails"])

    def test_slower_share(self):
        two = {"p01": {"variants": [variant(dur=1200)]}, "p02": {"variants": [variant(dur=1200)]}}
        self.assertTrue(g.compare(run(self.pairs()), run(self.pairs(**two)))["pass"])   # 2 из 20 = 10 %
        three = dict(two, p03={"variants": [variant(dur=1200)]})
        c = g.compare(run(self.pairs()), run(self.pairs(**three)))
        self.assertFalse(c["pass"])
        self.assertEqual(c["slower_pairs"], 3)

    def test_just_under_factor_is_not_slower(self):
        c = g.compare(run(self.pairs()), run(self.pairs(p01={"variants": [variant(dur=1080)]})))
        self.assertEqual(c["slower_pairs"], 0)

    def test_lost_route_fails(self):
        c = g.compare(run(self.pairs()), run(self.pairs(p05={"error": "NoRoute"})))
        self.assertFalse(c["pass"])
        self.assertEqual(c["errors"], [0, 1])

    def test_fewer_alternatives(self):
        one = {f"p{i:02}": {"variants": [variant()]} for i in range(5)}
        c = g.compare(run(self.pairs()), run(self.pairs(**one)))       # 40 → 35
        self.assertTrue(c["pass"], c["fails"])
        self.assertEqual(c["variants"], [40, 35])
        many = {f"p{i:02}": {"variants": [variant()]} for i in range(9)}
        self.assertFalse(g.compare(run(self.pairs()), run(self.pairs(**many)))["pass"])   # 40 → 31

    def test_graph_sanity(self):
        broken = {"restrictions_used": 900, "node_edges": 2283555}
        self.assertFalse(g.compare(run(self.pairs()), run(self.pairs(), broken))["pass"])
        shrunk = {"restrictions_used": 1124, "node_edges": 1800000}
        self.assertFalse(g.compare(run(self.pairs()), run(self.pairs(), shrunk))["pass"])
        grown = {"restrictions_used": 1180, "node_edges": 2300000}
        self.assertTrue(g.compare(run(self.pairs()), run(self.pairs(), grown))["pass"])


class Switch(unittest.TestCase):
    def test_scripts_parse(self):
        bash = shutil.which("bash")
        for kind in ("mld", "ch"):
            r = subprocess.run([bash, "-n"], input=g.switch_script(kind, "2026-11-10"), text=True, capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_mld_holds_lock_and_rolls_back(self):
        s = g.switch_script("mld", "2026-11-10")
        self.assertIn('mkdir "$R/.lock"', s)
        self.assertIn("sha256sum -c", s)
        self.assertIn("traffic_customize.sh\" --force", s)
        self.assertIn("inode \"$R/current", s)   # слот с нового эталона, а не «без изменений»
        self.assertIn('mv "$PREV" "$R/pristine"', s)
        self.assertLess(s.index('mv "$R/pristine" "$PREV"'), s.index('mv "$C" "$R/pristine"'))

    def test_ch_rolls_back_to_running_config(self):
        s = g.switch_script("ch", "2026-11-10")
        self.assertIn("PREV_SRC=", s)
        self.assertIn('run "$PREV_SRC" "$PREV_CMD"', s)
        self.assertIn("127.0.0.1:8092:5000", s)
        self.assertNotIn("8094", s)

    def test_switch_without_flag_only_prints(self):
        import argparse
        import contextlib
        import io
        calls = []
        real = subprocess.run
        subprocess.run = lambda *a, **k: calls.append(a) or real(["true"])
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                g.cmd_switch(argparse.Namespace(kind="mld", date="2026-11-10", i_am_owner=False))
        finally:
            subprocess.run = real
        self.assertEqual(calls, [])
        self.assertIn("ничего не выполнено", out.getvalue())


DOCKER_STUB = r"""#!/bin/bash
echo "docker $*" >> "$STATE/log"
case "$*" in
  "image inspect"*) echo sha256:img ;;
  *Mounts*) cat "$STATE/mounted" ;;
  *"json .Config.Cmd"*) echo '["osrm-routed","--algorithm","ch","--mmap","1","/data/uzbekistan.osrm"]' ;;
  *.Image*) echo sha256:img ;;
  "inspect "*) echo '{}' ;;
  run*)
    for a in "$@"; do case "$a" in *:/data) echo "${a%:/data}" > "$STATE/mounted" ;; esac; done ;;
esac
exit 0
"""

# Стенд отвечает, только когда в рабочем слоте граф с нужной меткой (OK_MLD);
# резерв CH — когда смонтирован каталог, в имени которого есть OK_CH.
CURL_STUB = r"""#!/bin/bash
url="${@: -1}"
case "$url" in
  *:8094/*) head -c 3 "$RADARMAP_OSRM_MLD/current/uzbekistan.osrm.ebg" | grep -q "$OK_MLD" || exit 22 ;;
  *:8092/*) grep -q "$OK_CH" "$STATE/mounted" || exit 22 ;;
esac
echo '{"code":"Ok","routes":[]}'
"""


class SwitchRun(unittest.TestCase):
    """Сценарий подмены целиком на временном корне: настоящий
    traffic_customize.sh, заглушки docker и curl. Медленный (~35 с) из-за
    пробы traffic_customize.sh в провальном случае."""
    DATE = "2026-11-10"
    FILES = ("mldgr", "geometry", "cell_metrics", "datasource_names", "ebg", "partition")

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "osrm-mld")
        self.state = os.path.join(self.tmp, "state")
        stubs = os.path.join(self.tmp, "stubs")
        for d in (self.root, self.state, stubs, os.path.join(self.root, "bin")):
            os.makedirs(d, exist_ok=True)
        for name, body in (("docker", DOCKER_STUB), ("curl", CURL_STUB), ("ionice", '#!/bin/bash\nshift\nexec "$@"\n')):
            with open(os.path.join(stubs, name), "w") as f:
                f.write(body)
            os.chmod(os.path.join(stubs, name), 0o755)
        shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "traffic_customize.sh"),
                    os.path.join(self.root, "bin"))
        self.env = dict(os.environ, PATH=stubs + os.pathsep + os.environ["PATH"], STATE=self.state,
                        RADARMAP_OSRM_MLD=self.root, RADARMAP_BASE=self.tmp, PROBE_TRIES="2",
                        SLOT_RETRY_SECONDS="0")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def make_set(self, path, label):
        import hashlib
        os.makedirs(path)
        sums = []
        for ext in self.FILES:
            data = f"{label} {ext}".encode()
            with open(os.path.join(path, f"uzbekistan.osrm.{ext}"), "wb") as f:
                f.write(data)
            sums.append(f"{hashlib.sha256(data).hexdigest()}  uzbekistan.osrm.{ext}")
        with open(os.path.join(path, "manifest.txt"), "w") as f:
            f.write("image ghcr.io/project-osrm/osrm-backend@sha256:x\nalgorithm mld\n")
        with open(os.path.join(path, "SHA256SUMS"), "w") as f:
            f.write("\n".join(sums) + "\n")

    def read(self, *parts):
        with open(os.path.join(self.root, *parts)) as f:
            return f.read()

    def run_switch(self, kind):
        return subprocess.run(["bash", "-s"], input=g.switch_script(kind, self.DATE), text=True,
                              capture_output=True, env=self.env, timeout=180)

    def stand(self):
        self.make_set(os.path.join(self.root, "pristine"), "old")
        os.makedirs(os.path.join(self.root, "a"))
        for name in os.listdir(os.path.join(self.root, "pristine")):
            os.link(os.path.join(self.root, "pristine", name), os.path.join(self.root, "a", name))
        os.symlink("a", os.path.join(self.root, "current"))
        self.make_set(os.path.join(self.root, f"candidate-{self.DATE}"), "new")

    def test_mld_switch(self):
        self.stand()
        r = self.run_switch("mld")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read("pristine", "uzbekistan.osrm.ebg"), "new ebg")
        self.assertEqual(self.read("current", "uzbekistan.osrm.ebg"), "new ebg")
        self.assertEqual(self.read(f"pristine.prev-{self.DATE}", "uzbekistan.osrm.ebg"), "old ebg")
        self.assertFalse(os.path.exists(os.path.join(self.root, f"candidate-{self.DATE}")))
        self.assertFalse(os.path.exists(os.path.join(self.root, ".lock")))

    def test_mld_rollback(self):
        self.stand()
        self.env["OK_MLD"] = "old"            # новый граф не отвечает
        r = self.run_switch("mld")
        self.assertEqual(r.returncode, 1)
        self.assertIn("откат", r.stderr)
        self.assertEqual(self.read("pristine", "uzbekistan.osrm.ebg"), "old ebg")
        self.assertEqual(self.read("current", "uzbekistan.osrm.ebg"), "old ebg")
        self.assertTrue(os.path.isdir(os.path.join(self.root, f"candidate-{self.DATE}.failed")))
        self.assertFalse(os.path.exists(os.path.join(self.root, ".lock")))

    def test_mld_bad_sha_touches_nothing(self):
        self.stand()
        with open(os.path.join(self.root, f"candidate-{self.DATE}", "uzbekistan.osrm.ebg"), "w") as f:
            f.write("порча")
        r = self.run_switch("mld")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.read("pristine", "uzbekistan.osrm.ebg"), "old ebg")
        self.assertFalse(os.path.exists(os.path.join(self.state, "log")))

    def ch_stand(self):
        os.makedirs(os.path.join(self.tmp, "osrm-29e"))
        with open(os.path.join(self.state, "mounted"), "w") as f:
            f.write(os.path.join(self.tmp, "osrm-29e") + "\n")
        self.make_set(os.path.join(self.root, f"ch-candidate-{self.DATE}"), "new")

    def test_ch_switch(self):
        self.ch_stand()
        self.env["OK_CH"] = "osrm-ch-"
        r = self.run_switch("ch")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(self.state, "mounted")) as f:
            self.assertEqual(f.read().strip(), os.path.join(self.tmp, f"osrm-ch-{self.DATE}"))
        self.assertTrue(os.path.exists(os.path.join(self.tmp, f"radarmap-osrm.inspect-{self.DATE}.json")))
        self.assertFalse(os.path.exists(os.path.join(self.root, ".lock")))

    def test_ch_rollback(self):
        self.ch_stand()
        self.env["OK_CH"] = "osrm-29e"        # новый не отвечает, прежний — да
        r = self.run_switch("ch")
        self.assertEqual(r.returncode, 1)
        with open(os.path.join(self.state, "mounted")) as f:
            self.assertEqual(f.read().strip(), os.path.join(self.tmp, "osrm-29e"))
        with open(os.path.join(self.state, "log")) as f:
            self.assertIn("osrm-routed --algorithm ch --mmap 1 /data/uzbekistan.osrm", f.read())
        self.assertTrue(os.path.isdir(os.path.join(self.root, f"ch-candidate-{self.DATE}.failed")))
        self.assertFalse(os.path.exists(os.path.join(self.root, ".lock")))


if __name__ == "__main__":
    unittest.main()
