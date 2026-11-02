#!/usr/bin/env python3
"""Тесты migrate_api_user.sh (38A): удалённая часть скрипта гоняется во
временном корне, systemctl/chown/stat/fuser/curl — заглушки. Проверяется то,
что нельзя сломать: каталог кода не отдаётся api на запись, базы переезжают
вместе с -wal/-shm и остаются доступны по старым путям, откат возвращает
права байт в байт, несошедшееся здоровье откатывает само.
Запуск: python3 server/test_migrate_api_user.py
"""
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "migrate_api_user.sh")
DROPINS = ("systemd-radarmap-user-api.conf", "systemd-radarmap-user-admin.conf",
           "systemd-radarmap-user-bot.conf")

STUBS = {
    # Юниты: состояние — файлы в $FAKE/units; MainPID — имя юнита (его читает ps).
    "systemctl": r'''#!/bin/bash
echo "systemctl $*" >> "$FAKE/calls"
case "$1" in
  is-active) shift; q=0; [ "$1" = -q ] && { q=1; shift; }
    if [ -f "$FAKE/units/$1" ]; then [ $q = 1 ] || echo active; exit 0; fi
    [ $q = 1 ] || echo inactive; exit 3 ;;
  stop) shift; for u in "$@"; do rm -f "$FAKE/units/$u"; done ;;
  start) shift; for u in "$@"; do touch "$FAKE/units/$u"; done ;;
  show) echo "${@: -1}" ;;
esac
exit 0
''',
    # Пользователь процесса — radarmap, если у юнита есть drop-in user.conf.
    "ps": r'''#!/bin/bash
u="${@: -1}"
[ -f "$FAKE_UNITDIR/$u.service.d/user.conf" ] && echo radarmap || echo root
''',
    "curl": r'''#!/bin/bash
[ -n "${FAKE_CURL_FAIL:-}" ] && { case "$*" in *http_code*) echo 500 ;; esac; exit 22; }
case "$*" in *http_code*) echo 200 ;; *) echo '{"ok": true}' ;; esac
''',
    "chown": r'''#!/bin/bash
echo "$1 $(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")" >> "$FAKE/owners"
for f in "${@:3}"; do echo "$1 $(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")" >> "$FAKE/owners"; done
''',
    # GNU stat -c по журналу chown-заглушки: последний chown пути главнее.
    "stat": r'''#!/usr/bin/env python3
import os, sys
fmt, path = sys.argv[2], sys.argv[3]
owners = {}
try:
    for line in open(os.path.join(os.environ["FAKE"], "owners")):
        who, p = line.rstrip("\n").split(" ", 1)
        owners[p] = who.split(":") + [""]
except FileNotFoundError:
    pass
real = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
user, group = (owners.get(real) or ["root", "root"])[:2]
st = os.lstat(path)
out = (fmt.replace("%U", user).replace("%G", group or user).replace("%a", "%o" % (st.st_mode & 0o7777))
          .replace("%n", path).replace("%d", "1").replace("%s", str(st.st_size)))
print(out)
''',
    "fuser": "#!/bin/bash\nexit 1\n",
    "flock": "#!/bin/bash\nexit 0\n",
    "journalctl": "#!/bin/bash\nexit 0\n",
    "useradd": '#!/bin/bash\ntouch "$FAKE/user"\n',
    "id": '#!/bin/bash\n[ -f "$FAKE/user" ] && echo "uid=999(radarmap)" || exit 1\n',
    "runuser": '#!/bin/bash\nwhile [ "$1" != -- ]; do shift; done; shift; exec "$@"\n',
    "timeout": '#!/bin/bash\nshift; exec "$@"\n',
}


def remote_part():
    with open(SCRIPT, encoding="utf-8") as f:
        text = f.read()
    return text.split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0] + "\n"


class MigrationTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "opt")
        self.api = os.path.join(self.root, "api")
        self.data = os.path.join(self.root, "data")
        self.unitdir = os.path.join(self.tmp, "units.d")
        self.fake = os.path.join(self.tmp, "fake")
        self.stage = os.path.join(self.tmp, "stage")
        self.bin = os.path.join(self.tmp, "bin")
        for d in (self.api, os.path.join(self.root, "backups"), os.path.join(self.root, "osrm-mld"),
                  self.unitdir, os.path.join(self.fake, "units"), self.stage, self.bin):
            os.makedirs(d)
        for name, body in STUBS.items():
            path = os.path.join(self.bin, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        for name in DROPINS:
            shutil.copy(os.path.join(HERE, name), self.stage)
        for unit in ("radarmap-api", "radarmap-admin", "radarmap-bot"):
            open(os.path.join(self.fake, "units", unit), "w").close()
        # Базы как на VPS: reports в WAL с -wal/-shm, bot — тоже, family нет.
        for db in ("reports.db", "traffic.db", "bot.db"):
            conn = sqlite3.connect(os.path.join(self.api, db))
            conn.execute("PRAGMA journal_mode = WAL")
            conn.execute("CREATE TABLE t(a)")
            conn.execute("INSERT INTO t VALUES (1)")
            conn.commit()
            conn.close()
        for name, mode in (("api.py", 0o644), ("status.py", 0o644), ("traffic_build.py", 0o644),
                           ("reports.db.before-quality-1", 0o644)):
            with open(os.path.join(self.api, name), "w") as f:
                f.write("")
            os.chmod(os.path.join(self.api, name), mode)
        for name in ("admin.conf", "telegram_bot.conf"):
            with open(os.path.join(self.root, name), "w") as f:
                f.write("k=v\n")
            os.chmod(os.path.join(self.root, name), 0o600)
        with open(os.path.join(self.root, "backups", "reports-1.db.gz"), "w") as f:
            f.write("x")
        os.chmod(os.path.join(self.root, "backups", "reports-1.db.gz"), 0o644)
        os.chmod(self.api, 0o755)
        self.script = os.path.join(self.tmp, "remote.sh")
        with open(self.script, "w") as f:
            f.write(remote_part())

    def tearDown(self):
        for dirpath, dirnames, _ in os.walk(self.tmp):
            for d in dirnames:
                os.chmod(os.path.join(dirpath, d), 0o755)
        shutil.rmtree(self.tmp)

    def run_mode(self, mode, **env):
        full = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE=self.fake,
                    FAKE_UNITDIR=self.unitdir, **env)
        return subprocess.run(["bash", self.script, mode, self.stage, self.root, self.unitdir],
                              capture_output=True, text=True, env=full, timeout=120)

    def owners(self):
        out = {}
        path = os.path.join(self.fake, "owners")
        if os.path.exists(path):
            for line in open(path):
                who, p = line.rstrip("\n").split(" ", 1)
                out[p] = who
        return out

    def real(self, path):
        return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))

    def mode(self, path):
        return stat.S_IMODE(os.lstat(path).st_mode)

    def rows(self, path):
        conn = sqlite3.connect(path)
        try:
            return conn.execute("SELECT a FROM t").fetchall()
        finally:
            conn.close()

    def test_apply_moves_databases_and_keeps_code_out_of_reach(self):
        done = self.run_mode("apply")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("✓ api, панель и бот — от radarmap", done.stdout)
        for db in ("reports.db", "traffic.db", "family.db", "bot.db"):
            link = os.path.join(self.api, db)
            self.assertTrue(os.path.islink(link), f"{db}: на старом месте — ссылка")
            self.assertEqual(os.readlink(link), os.path.join(self.data, db))
        self.assertEqual(self.rows(os.path.join(self.api, "reports.db")), [(1,)], "данные на месте")
        self.assertFalse([n for n in os.listdir(self.api) if n.endswith(("-wal", "-shm"))],
                         "журналы WAL уехали вместе с базой")
        owners = self.owners()
        self.assertEqual(owners[self.real(self.data)], "radarmap:radarmap")
        self.assertEqual(owners[self.real(self.api)], "root:radarmap", "код — root, api только читает")
        for path, who in owners.items():
            if path.startswith(self.real(self.api) + os.sep) or path == self.real(self.api):
                self.assertFalse(who.startswith("radarmap"), f"{path} отдан api: {who}")
        self.assertEqual(self.mode(self.api), 0o750)
        self.assertEqual(self.mode(self.data), 0o750)
        for name in os.listdir(self.data):
            self.assertEqual(self.mode(os.path.join(self.data, name)), 0o640, name)
            self.assertEqual(owners[self.real(os.path.join(self.data, name))], "radarmap:radarmap")
        self.assertEqual(owners[self.real(os.path.join(self.root, "admin.conf"))], "radarmap:radarmap")
        self.assertEqual(self.mode(os.path.join(self.root, "admin.conf")), 0o600)
        self.assertEqual(owners[self.real(os.path.join(self.root, "telegram_bot.conf"))], "root:radarmap")
        self.assertEqual(self.mode(os.path.join(self.root, "telegram_bot.conf")), 0o640)
        self.assertEqual(self.mode(os.path.join(self.root, "backups")), 0o700)
        self.assertEqual(self.mode(os.path.join(self.root, "backups", "reports-1.db.gz")), 0o600)
        self.assertEqual(self.mode(os.path.join(self.api, "reports.db.before-quality-1")), 0o600)
        for unit in ("api", "admin", "bot"):
            self.assertTrue(os.path.exists(os.path.join(self.unitdir, f"radarmap-{unit}.service.d", "user.conf")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "osrm-mld", ".lock")), "замок цикла снят")
        # Повторный запуск ничего не ломает.
        again = self.run_mode("apply")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("уже перенесена", again.stdout)

    def test_rollback_restores_everything_as_it_was(self):
        before = {name: self.mode(os.path.join(self.api, name)) for name in os.listdir(self.api)}
        self.assertEqual(self.run_mode("apply").returncode, 0)
        done = self.run_mode("rollback")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("✓ Откат", done.stdout)
        self.assertFalse(os.path.exists(self.data))
        for db in ("reports.db", "traffic.db", "bot.db"):
            path = os.path.join(self.api, db)
            self.assertFalse(os.path.islink(path))
            self.assertEqual(self.rows(path), [(1,)])
        self.assertFalse(os.path.lexists(os.path.join(self.api, "family.db")), "ссылки на несуществующее нет")
        self.assertEqual(self.mode(self.api), 0o755)
        for name, mode in before.items():
            if os.path.exists(os.path.join(self.api, name)):
                self.assertEqual(self.mode(os.path.join(self.api, name)), mode, name)
        self.assertEqual(self.mode(os.path.join(self.root, "admin.conf")), 0o600)
        self.assertEqual(self.mode(os.path.join(self.root, "backups")), 0o755)
        self.assertEqual(self.owners()[self.real(os.path.join(self.root, "admin.conf"))], "root:root")
        for unit in ("api", "admin", "bot"):
            self.assertFalse(os.path.exists(os.path.join(self.unitdir, f"radarmap-{unit}.service.d", "user.conf")))
        self.assertFalse(os.path.exists(os.path.join(self.root, ".migrate_api_user.state")))

    def test_failed_health_rolls_back_by_itself(self):
        done = self.run_mode("apply", FAKE_CURL_FAIL="1")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("откатываю", done.stdout)
        self.assertFalse(os.path.islink(os.path.join(self.api, "reports.db")))
        self.assertFalse(os.path.exists(os.path.join(self.unitdir, "radarmap-api.service.d", "user.conf")))

    def test_check_changes_nothing(self):
        done = self.run_mode("check")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("переедет", done.stdout)
        self.assertFalse(os.path.exists(self.data))
        self.assertFalse(os.path.exists(os.path.join(self.fake, "owners")))
        self.assertFalse(os.path.exists(os.path.join(self.fake, "user")))

    def test_rollback_without_migration_refuses(self):
        done = self.run_mode("rollback")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("откатывать нечего", done.stdout)


class StaticTest(unittest.TestCase):
    """Что видно без запуска: drop-in, карта drift, все базы сервисов."""

    def read(self, name):
        with open(os.path.join(HERE, name), encoding="utf-8") as f:
            return f.read()

    def test_dropins_reset_the_sandbox_and_name_the_user(self):
        for name in DROPINS:
            lines = [line for line in self.read(name).splitlines() if line and not line.startswith("#")]
            self.assertIn("User=radarmap", lines, name)
            self.assertIn("Group=radarmap", lines, name)
            rw = [line for line in lines if line.startswith("ReadWritePaths=")]
            self.assertEqual(rw[0], "ReadWritePaths=", f"{name}: сначала сброс /opt/radarmap из sandbox.conf")
            self.assertTrue(all("/opt/radarmap/api" not in line for line in rw), f"{name}: код не на запись")
            self.assertIn("/opt/radarmap/data", rw[1])
        self.assertGreater("user.conf", "sandbox.conf", "drop-in читается после песочницы")
        self.assertGreater("user.conf", "tiles.conf")

    def test_dropins_are_on_the_drift_map(self):
        text = self.read("drift.sh")
        for unit in ("api", "admin", "bot"):
            self.assertRegex(text, rf"systemd-radarmap-user-{unit}\.conf\s+/etc/systemd/system/"
                                   rf"radarmap-{unit}\.service\.d/user\.conf")

    def test_every_service_database_moves(self):
        moved = set(re.search(r'DBS="([^"]+)"', remote_part()).group(1).split())
        written = set()
        for name, pattern in (("api.py", r'^(?:TRAFFIC_)?DB_PATH = "(/opt/radarmap/api/[\w.]+)"'),
                              ("family_notify.py", r'^DEFAULT_DB = "(/opt/radarmap/api/[\w.]+)"'),
                              ("telegram_bot.py", r'^DEFAULT_DB = "(/opt/radarmap/api/[\w.]+)"')):
            found = re.findall(pattern, self.read(name), re.M)
            self.assertTrue(found, name)
            written.update(os.path.basename(path) for path in found)
        self.assertEqual(written - moved, set(), "база, которую пишет сервис, осталась в каталоге кода")

    def test_wrapper_and_remote_part_parse(self):
        for body in (self.read("migrate_api_user.sh"), remote_part()):
            done = subprocess.run(["bash", "-n"], input=body, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__":
    unittest.main()
