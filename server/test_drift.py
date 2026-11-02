#!/usr/bin/env python3
"""Тесты сверки с сервером (drift.sh) и ворот перед выкаткой (--gate), без сети.

ssh подменяется заглушкой (RADARMAP_DRIFT_SSH или ssh в PATH), которая печатает
заранее заданный «ответ сервера»: md5, git-хэш и путь каждого файла. История
git — во временном репозитории, куда копируется drift.sh, либо настоящая (для
проверки, что deploy-скрипты останавливаются до первой заливки).

Главное, что здесь закреплено: выкатка не затирает серверную копию, которой нет
в истории этой ветки, а версия из истории (сервер просто старее) ворот не
закрывает — иначе ворота мешали бы каждой обычной выкатке.
Запуск: python3 server/test_drift.py
"""
import hashlib
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DRIFT = os.path.join(HERE, "drift.sh")

BOT = "/opt/radarmap/api/telegram_bot.py"
TRAFFIC_API = "/opt/radarmap/api/traffic_config.py"
TRAFFIC_STAND = "/opt/radarmap/osrm-mld/bin/traffic_config.py"
CRON_ACTIVE = "17 3 * * * /opt/radarmap/api/backup_db.sh >> /var/log/radarmap-backup.log 2>&1\n"


def md5(data):
    return hashlib.md5(data).hexdigest()


def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def remote_line(path, data):
    return f"{md5(data)} {blob(data)} {path}" if data is not None else f"- - {path}"


def cron_line(text):
    active = "".join(l + "\n" for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#"))
    return f"{md5(active.encode())} - crontab"


def write_stub(directory, name="ssh"):
    """ssh-заглушка: на сверку (bash -s) отвечает файлом FAKE_REMOTE, прочие
    вызовы и scp/curl только записывает в CALLS — сети нет."""
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write('#!/bin/bash\n'
                'echo "$(basename "$0") $*" >> "$CALLS"\n'
                'case "$*" in *"bash -s"*) cat "$FAKE_REMOTE" ;; esac\n'
                'exit 0\n')
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    return path


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t"))


class GateTest(unittest.TestCase):
    """Ворота и причины расхождения на временном репозитории."""

    V1 = b"print('v1')\n"
    V2 = b"print('v2')\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = os.path.join(self.tmp, "repo")
        self.server = os.path.join(self.repo, "server")
        os.makedirs(self.server)
        shutil.copy(DRIFT, self.server)
        self.write("crontab.txt", "# комментарий\n" + CRON_ACTIVE)
        git(self.repo, "init", "-q", "-b", "main")
        self.write("telegram_bot.py", self.V1)
        self.write("traffic_config.py", self.V1)
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "v1")
        self.write("telegram_bot.py", self.V2)
        self.write("traffic_config.py", self.V2)
        git(self.repo, "commit", "-q", "-am", "v2")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.ssh = write_stub(self.bin)
        self.calls = os.path.join(self.tmp, "calls")
        self.fake = os.path.join(self.tmp, "remote")

    def write(self, name, data):
        mode = "wb" if isinstance(data, bytes) else "w"
        with open(os.path.join(self.server, name), mode) as f:
            f.write(data)

    def run_drift(self, *args, remote=None, allow=False):
        with open(self.fake, "w") as f:
            f.write("\n".join(remote) + "\n" if remote else "")
        env = dict(os.environ, RADARMAP_DRIFT_SSH=self.ssh, FAKE_REMOTE=self.fake,
                   CALLS=self.calls, RADARMAP_HOST="test-host")
        env.pop("RADARMAP_ALLOW_DRIFT", None)
        if allow:
            env["RADARMAP_ALLOW_DRIFT"] = "1"
        done = subprocess.run(["bash", os.path.join(self.server, "drift.sh"), *args],
                              capture_output=True, text=True, env=env, timeout=60)
        return done.returncode, done.stdout + done.stderr

    def remote(self, bot, traffic_api=None, traffic_stand=None, cron="# x\n" + CRON_ACTIVE):
        lines = [remote_line(BOT, bot)]
        if traffic_api is not None:
            lines.append(remote_line(TRAFFIC_API, traffic_api))
        if traffic_stand is not None:
            lines.append(remote_line(TRAFFIC_STAND, traffic_stand))
        return lines + [cron_line(cron)]

    def test_same_as_repo_opens(self):
        code, out = self.run_drift("--gate", "telegram_bot.py", remote=self.remote(self.V2))
        self.assertEqual(code, 0, out)
        self.assertIn("перезапись безопасна", out)

    def test_older_version_from_this_branch_opens(self):
        # Обычная выкатка: на сервере прошлая версия из git — не правка.
        code, out = self.run_drift("--gate", "telegram_bot.py", remote=self.remote(self.V1))
        self.assertEqual(code, 0, out)
        self.assertIn("сервер старее репо", out)

    def test_hot_edit_on_server_closes(self):
        code, out = self.run_drift("--gate", "telegram_bot.py",
                                   remote=self.remote(b"print('hotfix on server')\n"))
        self.assertEqual(code, 3, out)
        self.assertIn("серверной версии нет в git", out)
        self.assertIn("RADARMAP_ALLOW_DRIFT=1", out, "обход назван в выводе")

    def test_allow_drift_overrides_and_says_so(self):
        code, out = self.run_drift("--gate", "telegram_bot.py",
                                   remote=self.remote(b"print('hotfix on server')\n"), allow=True)
        self.assertEqual(code, 0, out)
        self.assertIn("RADARMAP_ALLOW_DRIFT=1", out)
        self.assertIn("будет потеряно", out)

    def test_version_from_another_branch_closes(self):
        # Выкатывали с ветки, которая сюда не слита: перезапись откатила бы её.
        git(self.repo, "checkout", "-q", "-b", "other")
        other = b"print('other branch')\n"
        self.write("telegram_bot.py", other)
        git(self.repo, "commit", "-q", "-am", "other")
        git(self.repo, "checkout", "-q", "main")
        code, out = self.run_drift("--gate", "telegram_bot.py", remote=self.remote(other))
        self.assertEqual(code, 3, out)
        self.assertIn("другой ветки", out)

    def test_uncommitted_deploy_is_not_history(self):
        # Выкатили незакоммиченное, потом поправили ещё: прошлой версии в git нет.
        self.write("telegram_bot.py", b"print('v3 local')\n")
        code, out = self.run_drift("--gate", "telegram_bot.py",
                                   remote=self.remote(b"print('v2.5 never committed')\n"))
        self.assertEqual(code, 3, out)

    def test_new_file_opens(self):
        code, out = self.run_drift("--gate", "telegram_bot.py", remote=self.remote(None))
        self.assertEqual(code, 0, out)

    def test_only_named_files_are_gated(self):
        hot = b"print('hot')\n"
        code, out = self.run_drift("--gate", "telegram_bot.py",
                                   remote=self.remote(self.V2, traffic_api=hot, traffic_stand=hot))
        self.assertEqual(code, 0, out)
        self.assertNotIn("traffic_config", out)

    def test_every_server_copy_of_a_file_is_gated(self):
        # traffic_config.py лежит в двух местах — правка в любом закрывает ворота.
        code, out = self.run_drift("--gate", "traffic_config.py",
                                   remote=self.remote(self.V2, traffic_api=self.V2,
                                                      traffic_stand=b"print('stand hotfix')\n"))
        self.assertEqual(code, 3, out)
        self.assertIn(TRAFFIC_STAND, out)

    def test_file_missing_from_map_is_an_error(self):
        code, out = self.run_drift("--gate", "nonexistent.py", remote=self.remote(self.V2))
        self.assertEqual(code, 4, out)
        self.assertIn("нет в карте", out)

    def test_silent_server_closes(self):
        code, out = self.run_drift("--gate", "telegram_bot.py", remote=None)
        self.assertEqual(code, 2, out)

    def test_full_report_names_the_reason(self):
        code, out = self.run_drift("--quiet", remote=self.remote(self.V1))
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"РАЗНЫЕ\s+telegram_bot\.py.*сервер старее репо")

    def test_crontab_compares_active_lines_only(self):
        code, out = self.run_drift("--quiet", remote=self.remote(self.V2, cron="# другие комментарии\n\n" + CRON_ACTIVE))
        self.assertNotIn("crontab.txt", out, out)
        code, out = self.run_drift("--quiet", remote=self.remote(self.V2, cron=CRON_ACTIVE + "*/5 * * * * extra\n"))
        self.assertIn("РАЗНЫЕ", out)
        self.assertIn("crontab.txt", out)

    def test_commented_out_job_differs_from_active_one(self):
        code, out = self.run_drift("--quiet", remote=self.remote(self.V2, cron="# " + CRON_ACTIVE))
        self.assertIn("crontab.txt", out)


class DeployScriptsTest(unittest.TestCase):
    """Каждый deploy-скрипт, который везёт файлы из карты drift.sh, зовёт ворота
    по своим файлам ДО первой заливки и останавливается, когда они закрыты."""

    SCRIPTS = ("deploy_api.sh", "deploy_bot.sh", "deploy_traffic.sh",
               "deploy_road_weather.sh", "install_roads_pipeline.sh", "migrate_api_user.sh")

    def read(self, name):
        with open(os.path.join(HERE, name), encoding="utf-8") as f:
            return f.read()

    def map_files(self):
        text = self.read("drift.sh")
        block = text.split('MAP="', 1)[1].split('"', 1)[0]
        return {line.split()[0] for line in block.splitlines() if len(line.split()) == 2}

    def test_gate_comes_before_the_first_upload(self):
        for name in self.SCRIPTS:
            text = self.read(name)
            gate = text.find('drift.sh" --gate')
            self.assertGreater(gate, 0, f"{name}: нет ворот")
            first_scp = min(i for i in (text.find('"${SCP[@]}"'), text.find("\nscp ")) if i >= 0)
            self.assertLess(gate, first_scp, f"{name}: ворота после заливки")

    def test_shipped_files_are_on_the_map(self):
        on_map = self.map_files()
        for name in self.SCRIPTS:
            for shipped in re.findall(r'\$DIR/([\w./-]+\.(?:py|sh|js|css|json|service))"', self.read(name)):
                if shipped.startswith(("review/", "static/vendor/glyphs")) or shipped == "drift.sh":
                    continue
                self.assertIn(shipped, on_map, f"{name} везёт {shipped}, а drift.sh его не сверяет")

    def run_blocked(self, script, hot_path):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        for tool in ("ssh", "scp", "curl"):
            write_stub(tmp, tool)
        fake, calls = os.path.join(tmp, "remote"), os.path.join(tmp, "calls")
        with open(fake, "w") as f:
            f.write(remote_line(hot_path, b"# hot edit made on the server by hand\n") + "\n")
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                   FAKE_REMOTE=fake, CALLS=calls)
        for k in ("RADARMAP_ALLOW_DRIFT", "RADARMAP_DRIFT_SSH", "RADARMAP_SSH_KEY"):
            env.pop(k, None)
        done = subprocess.run(["bash", os.path.join(HERE, script)], capture_output=True,
                              text=True, env=env, timeout=120)
        log = ""
        if os.path.exists(calls):
            with open(calls) as f:
                log = f.read()
        return done.returncode, done.stdout + done.stderr, log

    def test_deploy_api_stops_before_upload(self):
        code, out, log = self.run_blocked("deploy_api.sh", "/opt/radarmap/api/admin.py")
        self.assertNotEqual(code, 0, out)
        self.assertIn("ворота drift", out)
        self.assertNotIn("scp ", log, "ни одного файла не залито")
        self.assertNotIn("curl ", log)

    def test_deploy_bot_stops_before_upload(self):
        code, out, log = self.run_blocked("deploy_bot.sh", "/opt/radarmap/api/telegram_bot.py")
        self.assertNotEqual(code, 0, out)
        self.assertNotIn("scp ", log)

    def test_migrate_api_user_stops_before_upload(self):
        code, out, log = self.run_blocked("migrate_api_user.sh",
                                          "/etc/systemd/system/radarmap-api.service.d/user.conf")
        self.assertNotEqual(code, 0, out)
        self.assertNotIn("scp ", log)

    def test_road_weather_stops_before_upload(self):
        code, out, log = self.run_blocked("deploy_road_weather.sh", "/opt/radarmap/api/build_road_weather.py")
        self.assertNotEqual(code, 0, out)
        self.assertNotIn("scp ", log)


if __name__ == "__main__":
    unittest.main()
