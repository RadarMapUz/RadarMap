#!/usr/bin/env python3
"""Еженедельное обновление графа OSRM из свежей OSM (87, 10.11.2026).

Граф страны собирается на маке (на VPS osrm-extract не помещается: пик ~3 ГБ
при 1,5 ГБ свободных), проверяется аудитом против боевого и едет на VPS
кандидатом рядом с живыми файлами. Подмену делает владелец.

    python3 server/osrm/graph_refresh.py build  [--date Д] [--pbf файл] [--threads N]
    python3 server/osrm/graph_refresh.py audit  [--date Д] [--old-mld каталог] [--old-ch каталог]
    python3 server/osrm/graph_refresh.py gate                      # ворота нагрузки VPS, только чтение
    python3 server/osrm/graph_refresh.py upload [--date Д] [--dry-run] [--wait МИН] [--limit КБИТ/С]
    python3 server/osrm/graph_refresh.py switch [--date Д] --kind mld|ch [--i-am-owner]

build   свежая выгрузка Geofabrik (md5) → build_osrm_mld.sh: MLD и отдельно CH,
        оба с car_radarmap.lua; пики памяти, время, размеры → build.json.
audit   четыре osrm-routed в локальном docker (старый/новый × MLD/CH), пары
        audit_pairs.json запросом приложения, разбор route_audit.py, ворота
        (GATE) → audit.json и audit.md. Боевой граф находится сам: локальный
        набор, чьи sha совпали с манифестом на VPS.
gate    снимок VPS (время по Ташкенту, load, MemAvailable, замок цикла
        пробок, диск, inode) и вердикт.
upload  только прошедшие аудит наборы, только в ночное окно на свободном
        сервере: scp -l в candidate-Д.part, sha256sum -c, переименование в
        candidate-Д; хранится не больше одного прежнего кандидата. Живые
        каталоги (pristine, a, b, current, смонтированные) не трогаются.
switch  печатает шаги подмены с откатом; выполняет только с --i-am-owner.

Коды выхода: 0 — готово, 1 — ошибка или ворота аудита не пройдены,
75 — сейчас нельзя (сервер занят или не ночь), повторить позже.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.dirname(HERE)
BUILD_SCRIPT = os.path.join(SERVER, "build_osrm_mld.sh")
PROFILE = os.path.join(HERE, "car_radarmap.lua")
WORK = os.environ.get("RADARMAP_REFRESH_WORK", os.path.expanduser("~/RadarMapBuild/osrm/refresh"))
# Наборы, собранные до этого сценария: среди них ищется боевой граф.
LEGACY_SETS = [os.path.expanduser(p) for p in (
    "~/RadarMapBuild/osrm/mld-32d/mld-uzbekistan", "~/RadarMapBuild/osrm/ch-uzbekistan")]
GEOFABRIK = "https://download.geofabrik.de/asia/uzbekistan-latest.osm.pbf"
MIN_PBF_BYTES = 50_000_000
NAME = "uzbekistan"
PLATFORM = "linux/amd64"

VPS = os.environ.get("RADARMAP_VPS", "radarmap-vps")
MLD_ROOT = "/opt/radarmap/osrm-mld"
CH_CONTAINER = "radarmap-osrm"
MLD_CONTAINER = "radarmap-osrm-mld"
# Живые каталоги стенда: upload и чистка их не трогают ни при каком раскладе.
LIVE_ENTRIES = {"pristine", "a", "b", "a.new", "b.new", "current", "bin", "test"}
# Проба после подмены — та же пара, что у traffic_customize.sh, и межгород.
PROBES = ("/route/v1/driving/69.19617,41.28151;69.28866,41.36612?overview=false",
          "/route/v1/driving/69.27970,41.31110;66.97570,39.65500?overview=false")

# Ворота нагрузки VPS (upload). Окно — ночь по Ташкенту, когда пользователей
# почти нет и cron-задачи тяжёлые только в 03:17 (бэкап) и вс 04:17 (дороги).
WINDOW = ("02:00", "05:30")
LOAD_MAX = 0.5            # load average за минуту — на старте
LOAD_MAX_DURING = 1.0     # между файлами: своя заливка тоже даёт нагрузку
MEM_MIN_MB = 800          # MemAvailable
DISK_RESERVE_MB = 2048    # сверх размера набора
INODES_MIN = 100_000
SCP_LIMIT_KBIT = 40_000   # ~5 МБ/с: 1,7 ГБ за ~6 мин, канал соседям остаётся

# Ворота аудита: новый граф не хуже боевого.
GATE = {
    "slower_factor": 1.20,      # «резкий рост времени» первого варианта пары
    "slower_share_max": 0.10,   # доля таких пар (2 из 20)
    "restrictions_drop_max": 0.10,   # запретов в графе меньше на 10 % — битая выгрузка
    "edges_change_max": 0.10,        # рёбер графа ±10 % за неделю не бывает
    # Альтернативы MLD зависят от разбиения на ячейки и от недели к неделе
    # гуляют (10.11: 36 → 32 на 20 парах); провал — когда их заметно меньше.
    "variants_drop_max": 0.20,
}

PORTS = {("mld", "old"): 5871, ("mld", "new"): 5872, ("ch", "old"): 5873, ("ch", "new"): 5874}


# ------------------------------------------------------------ чистая логика

def image_digest(script=BUILD_SCRIPT):
    """Образ OSRM — из build_osrm_mld.sh, чтобы версия жила в одном месте."""
    with open(script) as f:
        m = re.search(r'IMAGE="\$\{RADARMAP_OSRM_IMAGE:-([^}]+)\}"', f.read())
    return os.environ.get("RADARMAP_OSRM_IMAGE") or m.group(1)


def parse_osrm_log(text):
    """Пик памяти, размер графа и запреты поворотов из журнала шага OSRM."""
    out = {}
    peaks = re.findall(r"RAM: peak bytes used: (\d+)", text)
    if peaks:
        out["peak_mb"] = round(int(peaks[-1]) / 1048576)
    m = re.search(r"Raw input contains (\d+) nodes, (\d+) ways, and (\d+) relations, (\d+) restrictions", text)
    if m:
        out.update(osm_nodes=int(m[1]), osm_ways=int(m[2]), osm_relations=int(m[3]), restrictions_raw=int(m[4]))
    m = re.search(r"removed (\d+) invalid turn restrictions", text)
    if m:
        out["restrictions_invalid"] = int(m[1])
    m = re.search(r"Constructing restriction graph on (\d+) restrictions", text)
    if m:
        out["restrictions_used"] = int(m[1])
    m = re.search(r"Node-based graph contains (\d+) edges", text)
    if m:
        out["node_edges"] = int(m[1])
    m = re.search(r"Generated (\d+) nodes .*?and (\d+) segments in edge-expanded graph", text)
    if m:
        out.update(ebg_nodes=int(m[1]), ebg_segments=int(m[2]))
    return out


def sha_lines(manifest_text):
    """Строки «sha  файл» набора из manifest.txt (без шапки)."""
    return sorted(line.strip() for line in manifest_text.splitlines()
                  if re.match(r"^[0-9a-f]{64}  \S+$", line.strip()))


def in_window(hhmm, window=WINDOW):
    return window[0] <= hhmm <= window[1]


def parse_snapshot(text):
    """Снимок VPS: строки key=value, повторяющиеся entry= и mount= — списки."""
    snap = {"entries": [], "mounts": []}
    for line in text.splitlines():
        key, _, value = line.strip().partition("=")
        if key == "entry":
            snap["entries"].append(value)
        elif key == "mount":
            snap["mounts"].append(value)
        elif key in ("load1", "load5"):
            snap[key] = float(value)
        elif key in ("mem_avail_mb", "disk_free_mb", "inodes_free"):
            snap[key] = int(value or 0)
        elif key == "customize_lock":
            snap[key] = value == "1"
        elif key:
            snap[key] = value
    return snap


def gate_reasons(snap, during=False, need_mb=0):
    """Почему сейчас нельзя лить на VPS; пустой список — можно."""
    reasons = []
    if not in_window(snap.get("hhmm", "")):
        reasons.append(f"не ночь: {snap.get('hhmm', '?')} по Ташкенту, окно {WINDOW[0]}–{WINDOW[1]}")
    limit = LOAD_MAX_DURING if during else LOAD_MAX
    if snap.get("load1", 99.0) >= limit:
        reasons.append(f"load average {snap.get('load1')} ≥ {limit}")
    if snap.get("mem_avail_mb", 0) <= MEM_MIN_MB:
        reasons.append(f"свободно памяти {snap.get('mem_avail_mb')} МБ ≤ {MEM_MIN_MB}")
    if snap.get("customize_lock"):
        reasons.append("идёт цикл пробок (замок osrm-mld/.lock)")
    if need_mb:
        if snap.get("disk_free_mb", 0) < need_mb + DISK_RESERVE_MB:
            reasons.append(f"диск: свободно {snap.get('disk_free_mb')} МБ, нужно {need_mb + DISK_RESERVE_MB}")
        if snap.get("inodes_free", 0) < INODES_MIN:
            reasons.append(f"inode: свободно {snap.get('inodes_free')}, нужно {INODES_MIN}")
    return reasons


CANDIDATE_RE = re.compile(r"^(ch-)?candidate-(\d{4}-\d{2}-\d{2})(\.part)?$")


def candidate_name(kind, date, part=False):
    return f"{'ch-' if kind == 'ch' else ''}candidate-{date}{'.part' if part else ''}"


def prune_plan(entries, kind, keep_date, mounts=(), root=MLD_ROOT):
    """Какие кандидаты этого вида удалить: остаются свежий (keep_date) и один
    прежний готовый; недолитые .part чужих дат — в удаление. Живое и
    смонтированное не удаляется никогда."""
    mine = []
    for e in entries:
        m = CANDIDATE_RE.match(e)
        if not m or e in LIVE_ENTRIES or (m[1] == "ch-") != (kind == "ch"):
            continue
        mine.append((m[2], bool(m[3]), e))
    drop = [e for date, part, e in mine if part and date != keep_date]
    done = sorted((date, e) for date, part, e in mine if not part and date != keep_date)
    drop += [e for _, e in done[:-1]]
    mounted = {m.rstrip("/") for m in mounts}
    return sorted(e for e in drop if f"{root}/{e}" not in mounted)


def local_prune_plan(dates, keep, newest=3):
    """Локальные сборки (каталоги-даты в WORK) к удалению: остаются три
    свежих и всё, что сейчас боевое (keep) — оно нужно аудиту как «старый»."""
    days = sorted(d for d in dates if re.match(r"^\d{4}-\d{2}-\d{2}$", d))
    return [d for d in days[:-newest] if d not in keep]


def first(entry):
    return entry["variants"][0] if entry.get("variants") else None


def compare(old, new, gate=GATE):
    """Сравнение разборов двух графов по парам; вердикт ворот аудита.

    old/new: {"pairs": {id: {"error"} | {"variants": [...]}}, "graph": parse_osrm_log}.
    Вариант — сокращённый analyze_route: distance, duration, restrictions (число).
    """
    rows, slower, fails = [], 0, []
    err_old = err_new = 0
    var_old = var_new = 0
    v_old_first = v_new_first = v_old_all = v_new_all = 0
    for pid in sorted(set(old["pairs"]) | set(new["pairs"])):
        o, n = old["pairs"].get(pid, {"error": "нет"}), new["pairs"].get(pid, {"error": "нет"})
        err_old += "error" in o
        err_new += "error" in n
        fo, fn = first(o), first(n)
        row = {"id": pid, "old": fo and {k: fo[k] for k in ("distance", "duration", "restrictions")},
               "new": fn and {k: fn[k] for k in ("distance", "duration", "restrictions")},
               "variants_old": len(o.get("variants", [])), "variants_new": len(n.get("variants", []))}
        if fo and fn:
            row["time_ratio"] = round(fn["duration"] / max(fo["duration"], 1), 3)
            row["dist_ratio"] = round(fn["distance"] / max(fo["distance"], 1), 3)
            if row["time_ratio"] > gate["slower_factor"]:
                slower += 1
        v_old_first += fo["restrictions"] if fo else 0
        v_new_first += fn["restrictions"] if fn else 0
        var_old += row["variants_old"]
        var_new += row["variants_new"]
        v_old_all += sum(v["restrictions"] for v in o.get("variants", []))
        v_new_all += sum(v["restrictions"] for v in n.get("variants", []))
        rows.append(row)
    pairs = len(rows) or 1
    if err_new > err_old:
        fails.append(f"пар без маршрута стало {err_new} (было {err_old})")
    if v_new_first > v_old_first:
        fails.append(f"нарушений запретов в первых вариантах {v_new_first} (было {v_old_first})")
    if v_new_all > v_old_all:
        fails.append(f"нарушений запретов во всех вариантах {v_new_all} (было {v_old_all})")
    if var_new < var_old * (1 - gate["variants_drop_max"]):
        fails.append(f"вариантов {var_new} (было {var_old})")
    if slower / pairs > gate["slower_share_max"]:
        fails.append(f"резко медленнее (×{gate['slower_factor']}) {slower} пар из {pairs}")
    go, gn = old.get("graph", {}), new.get("graph", {})
    if go.get("restrictions_used") and gn.get("restrictions_used") is not None:
        if gn["restrictions_used"] < go["restrictions_used"] * (1 - gate["restrictions_drop_max"]):
            fails.append(f"запретов в графе {gn['restrictions_used']} (было {go['restrictions_used']})")
    if go.get("node_edges") and gn.get("node_edges"):
        change = abs(gn["node_edges"] / go["node_edges"] - 1)
        if change > gate["edges_change_max"]:
            fails.append(f"рёбер графа {gn['node_edges']} против {go['node_edges']} ({change:.0%})")
    return {"pass": not fails, "fails": fails, "rows": rows, "slower_pairs": slower,
            "errors": [err_old, err_new], "variants": [var_old, var_new], "violations_first": [v_old_first, v_new_first],
            "violations_all": [v_old_all, v_new_all]}


# ----------------------------------------------------------------- оболочка

def log(*args):
    print(*args, flush=True)


def set_dir(date, kind):
    return os.path.join(WORK, date, f"{kind}-{NAME}")


def today():
    return datetime.date.today().isoformat()


def ssh(command, check=True, timeout=120):
    """Команда на VPS; возвращает stdout."""
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", VPS, command],
                       capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"ssh: {command[:60]}… → код {r.returncode}: {r.stderr.strip()[:300]}")
    return r.stdout


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_pbf(target):
    log(f"→ выгрузка {GEOFABRIK}")
    subprocess.run(["curl", "-sSfL", "-o", target + ".new", GEOFABRIK], check=True)
    with urllib.request.urlopen(GEOFABRIK + ".md5", timeout=60) as r:
        want = r.read().decode().split()[0]
    if md5_file(target + ".new") != want:
        raise SystemExit("md5 выгрузки не сошёлся")
    if os.path.getsize(target + ".new") < MIN_PBF_BYTES:
        raise SystemExit("выгрузка подозрительно мала")
    os.replace(target + ".new", target)


def pbf_timestamp(path):
    try:
        import osmium
        return osmium.io.Reader(path, osmium.osm.osm_entity_bits.NOTHING).header().get(
            "osmosis_replication_timestamp")
    except Exception as e:  # pyosmium нужен только для подписи, не для сборки
        return f"неизвестно ({e.__class__.__name__})"


def summarize_set(path):
    out = {"files": {}, "steps": {}}
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        if name.startswith(NAME + ".osrm"):
            out["files"][name] = os.path.getsize(full)
        elif name.endswith(".log") and name.startswith("osrm-"):
            with open(full, errors="replace") as f:
                out["steps"][name[:-4]] = parse_osrm_log(f.read())
    out["total_mb"] = round(sum(out["files"].values()) / 1048576, 1)
    graph = {}
    for step in out["steps"].values():
        graph.update({k: v for k, v in step.items() if k != "peak_mb"})
    out["graph"] = graph
    return out


def write_sums(path):
    """SHA256SUMS для sha256sum -c на сервере — из манифеста сборки."""
    with open(os.path.join(path, "manifest.txt")) as f:
        lines = sha_lines(f.read())
    if not lines:
        raise SystemExit(f"в {path}/manifest.txt нет sha файлов")
    with open(os.path.join(path, "SHA256SUMS"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)


def cmd_build(args):
    day = os.path.join(WORK, args.date)
    os.makedirs(day, exist_ok=True)
    pbf = os.path.join(day, f"{NAME}-latest.osm.pbf")
    if args.pbf:
        subprocess.run(["cp", args.pbf, pbf], check=True)
    elif not os.path.exists(pbf):
        fetch_pbf(pbf)
    info = {"date": args.date, "image": image_digest(), "threads": args.threads,
            "pbf": {"md5": md5_file(pbf), "bytes": os.path.getsize(pbf), "osm_timestamp": pbf_timestamp(pbf)}}
    log(f"→ выгрузка: {info['pbf']['bytes'] / 1048576:.0f} МБ, данные на {info['pbf']['osm_timestamp']}")
    env = dict(os.environ, RADARMAP_OSRM_THREADS=str(args.threads))
    for kind in ("mld", "ch"):
        cmd = ["nice", "-n", "15", "bash", BUILD_SCRIPT, "--work", day, "--pbf", pbf, "--profile", PROFILE]
        if kind == "ch":
            cmd.append("--ch")
        log("+ " + shlex.join(cmd))
        start = time.monotonic()
        subprocess.run(cmd, check=True, env=env, stdout=subprocess.DEVNULL if args.quiet else None)
        path = set_dir(args.date, kind)
        summary = summarize_set(path)
        summary["minutes"] = round((time.monotonic() - start) / 60, 1)
        summary["files_count"] = write_sums(path)
        with open(PROFILE, "rb") as f:
            summary["profile_sha256"] = hashlib.sha256(f.read()).hexdigest()
        info[kind] = summary
    with open(os.path.join(day, "build.json"), "w") as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    for kind in ("mld", "ch"):
        s = info[kind]
        peaks = ", ".join(f"{k.replace('osrm-', '')} {v.get('peak_mb', '?')} МБ" for k, v in s["steps"].items())
        log(f"✓ {kind}: {s['minutes']} мин, {s['total_mb']} МБ, {s['files_count']} файлов; пики: {peaks}")
        g = s["graph"]
        log(f"  запретов: в выгрузке {g.get('restrictions_raw')}, отброшено {g.get('restrictions_invalid')}, "
            f"в графе {g.get('restrictions_used')}; рёбер {g.get('node_edges')}")
    log(f"→ {day}/build.json")


# -------------------------------------------------------------------- audit

def vps_manifest(kind):
    """Манифест живого графа на VPS (только чтение)."""
    if kind == "mld":
        return ssh(f"cat {MLD_ROOT}/pristine/manifest.txt")
    src = ssh("docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Source}}{{end}}{{end}}' "
              + CH_CONTAINER).strip()
    return ssh(f"cat {shlex.quote(src)}/manifest.txt")


def find_baseline(kind, exclude_date):
    want = sha_lines(vps_manifest(kind))
    cands = list(LEGACY_SETS)
    if os.path.isdir(WORK):
        cands += [set_dir(d, kind) for d in sorted(os.listdir(WORK), reverse=True) if d != exclude_date]
    for path in cands:
        m = os.path.join(path, "manifest.txt")
        if os.path.exists(m) and f"algorithm {kind}" in open(m).read() and sha_lines(open(m).read()) == want:
            return path
    raise SystemExit(f"нет локальной копии боевого {kind}: задайте --old-{kind} каталог")


def docker_up(name, path, kind, port):
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    cmd = ["docker", "run", "-d", "--rm", "--name", name, "--platform", PLATFORM,
           "-p", f"127.0.0.1:{port}:5000", "-v", f"{path}:/data:ro", image_digest(),
           "osrm-routed", "--algorithm", kind, "--mmap", "1"]
    if kind == "mld":
        cmd += ["--max-alternatives", "3"]
    subprocess.run(cmd + [f"/data/{NAME}.osrm"], check=True, capture_output=True)
    for _ in range(240):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{PROBES[0]}", timeout=5) as r:
                if json.load(r).get("code") == "Ok":
                    return
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit(f"{name} не поднялся за 4 мин")


def fetch_runs(port, out, pairs):
    import route_audit as ra
    os.makedirs(out, exist_ok=True)
    for pair in pairs:
        url = ra.route_url(f"http://127.0.0.1:{port}", pair, "3", "&approaches=unrestricted;curb")
        with urllib.request.urlopen(url, timeout=120) as r:
            body = r.read()
        with open(os.path.join(out, pair["id"] + ".json"), "wb") as f:
            f.write(body)


def analyze_runs(run_dir, tags, pairs):
    import route_audit as ra
    result = {}
    for pair in pairs:
        with open(os.path.join(run_dir, pair["id"] + ".json")) as f:
            resp = json.load(f)
        if resp.get("code") != "Ok":
            result[pair["id"]] = {"error": resp.get("code")}
            continue
        variants = []
        for i, route in enumerate(resp["routes"][:3]):
            a = ra.analyze_route(route, tags, i)
            variants.append({"distance": a["distance"], "duration": a["duration"],
                             "restrictions": len(a["restrictions"]), "yard_mid": a["yard_mid"],
                             "loops": len(a["loops"]), "uturns": len(a["uturns"]),
                             "bad_lefts": sum(1 for l in a["lefts"] if l["major"] and not l["signal"])})
        result[pair["id"]] = {"variants": variants}
    return result


def write_report(day, report):
    pairs = {p["id"]: p["name"] for p in report["pairs_meta"]}
    lines = [f"# Аудит графа {report['date']}", "",
             f"Новая выгрузка: данные на {report['pbf_new']}, отношений-запретов в ней "
             f"{report['pbf_restrictions_new']} (pyosmium). Боевые наборы: "
             + ", ".join(f"{k} — `{v}`" for k, v in report["baseline"].items()), ""]
    for kind in ("mld", "ch"):
        c = report[kind]
        lines += [f"## {kind.upper()}: {'пройдено' if c['pass'] else 'НЕ пройдено'}", ""]
        lines += [f"- {f}" for f in c["fails"]] or ["- ворота: всё в пределах"]
        go, gn = report["graph"][kind]
        lines += ["", f"Запретов в графе {go.get('restrictions_used')} → {gn.get('restrictions_used')} "
                      f"(в выгрузке {go.get('restrictions_raw')} → {gn.get('restrictions_raw')}), "
                      f"рёбер {go.get('node_edges')} → {gn.get('node_edges')}; нарушений запретов "
                      f"(первые / все варианты) {c['violations_first'][0]}/{c['violations_all'][0]} → "
                      f"{c['violations_first'][1]}/{c['violations_all'][1]}; пар без маршрута "
                      f"{c['errors'][0]} → {c['errors'][1]}; вариантов {c['variants'][0]} → {c['variants'][1]}.", "",
                  "| Пара | км было | км стало | мин было | мин стало | Δ время | вар. |", "|---|---|---|---|---|---|---|"]
        for r in c["rows"]:
            o, n = r["old"], r["new"]
            if not (o and n):
                lines.append(f"| {pairs.get(r['id'], r['id'])} | ошибка | | | | | |")
                continue
            lines.append(f"| {pairs.get(r['id'], r['id'])} | {o['distance'] / 1000:.1f} | {n['distance'] / 1000:.1f} | "
                         f"{o['duration'] / 60:.1f} | {n['duration'] / 60:.1f} | {(r['time_ratio'] - 1) * 100:+.1f} % | "
                         f"{r['variants_old']}→{r['variants_new']} |")
        lines.append("")
    with open(os.path.join(day, "audit.md"), "w") as f:
        f.write("\n".join(lines))


def cmd_audit(args):
    sys.path.insert(0, HERE)
    import route_audit as ra
    day = os.path.join(WORK, args.date)
    with open(os.path.join(day, "build.json")) as f:
        build = json.load(f)
    baseline = {"mld": args.old_mld or find_baseline("mld", args.date),
                "ch": args.old_ch or find_baseline("ch", args.date)}
    log("→ боевые наборы: " + ", ".join(f"{k} {v}" for k, v in baseline.items()))
    pairs = ra.load_pairs(args.pairs)
    runs = os.path.join(day, "audit")
    names = []
    try:
        for kind in ("mld", "ch"):
            for side, path in (("old", baseline[kind]), ("new", set_dir(args.date, kind))):
                name = f"radarmap-refresh-{kind}-{side}"
                names.append(name)
                docker_up(name, path, kind, PORTS[(kind, side)])
                fetch_runs(PORTS[(kind, side)], os.path.join(runs, f"{kind}-{side}"), pairs)
                subprocess.run(["docker", "rm", "-f", name], capture_output=True)
                log(f"  {kind}-{side}: {len(pairs)} пар")
    finally:
        for name in names:
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    tags_path = os.path.join(runs, "tags.json")
    ra.cmd_index(argparse.Namespace(pbf=os.path.join(day, f"{NAME}-latest.osm.pbf"),
                                    runs=[os.path.join(runs, d) for d in ("mld-old", "mld-new", "ch-old", "ch-new")],
                                    out=tags_path))
    with open(tags_path) as f:
        raw = json.load(f)
    tags = ra.Tags(raw)
    report = {"date": args.date, "baseline": baseline, "gate": GATE, "pairs_meta": pairs,
              "pbf_new": build["pbf"]["osm_timestamp"], "pbf_restrictions_new": len(raw["restrictions"]),
              "graph": {}}
    for kind in ("mld", "ch"):
        old_graph = summarize_set(baseline[kind])["graph"]
        new_graph = build[kind]["graph"]
        report["graph"][kind] = [old_graph, new_graph]
        report[kind] = compare({"pairs": analyze_runs(os.path.join(runs, f"{kind}-old"), tags, pairs), "graph": old_graph},
                               {"pairs": analyze_runs(os.path.join(runs, f"{kind}-new"), tags, pairs), "graph": new_graph})
    with open(os.path.join(day, "audit.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    write_report(day, report)
    keep = {os.path.basename(os.path.dirname(p)) for p in baseline.values()}
    for d in local_prune_plan(os.listdir(WORK), keep):
        subprocess.run(["rm", "-rf", os.path.join(WORK, d)], check=True)
        log(f"  − локальная сборка {d}")
    for kind in ("mld", "ch"):
        c = report[kind]
        log(f"{'✓' if c['pass'] else '✗'} {kind}: медленнее ×{GATE['slower_factor']} {c['slower_pairs']} пар, "
            f"нарушений {c['violations_first']} / {c['violations_all']}, без маршрута {c['errors']}, "
            f"вариантов {c['variants']}"
            + ("" if c["pass"] else "; " + "; ".join(c["fails"])))
    log(f"→ {day}/audit.md")
    return 0 if report["mld"]["pass"] and report["ch"]["pass"] else 1


# ------------------------------------------------------------- upload, gate

SNAPSHOT = r"""
echo hhmm=$(TZ=Asia/Tashkent date +%H:%M)
read l1 l5 _ < /proc/loadavg; echo load1=$l1; echo load5=$l5
awk '/^MemAvailable/ {print "mem_avail_mb=" int($2/1024)}' /proc/meminfo
echo disk_free_mb=$(df -BM --output=avail ROOT | tail -1 | tr -dc 0-9)
echo inodes_free=$(df --output=iavail ROOT | tail -1 | tr -dc 0-9)
[ -d ROOT/.lock ] && echo customize_lock=1 || echo customize_lock=0
ls -1 ROOT | sed 's/^/entry=/'
docker ps -q | xargs -r docker inspect -f '{{range .Mounts}}mount={{.Source}}{{"\n"}}{{end}}' | grep . || true
""".replace("ROOT", MLD_ROOT)


def snapshot():
    return parse_snapshot(ssh(SNAPSHOT))


def show_snapshot(s):
    log(f"VPS: {s.get('hhmm')} по Ташкенту, load {s.get('load1')}/{s.get('load5')}, "
        f"свободно памяти {s.get('mem_avail_mb')} МБ, диска {s.get('disk_free_mb')} МБ, "
        f"inode {s.get('inodes_free')}, цикл пробок {'идёт' if s.get('customize_lock') else 'не идёт'}")


def cmd_gate(args):
    s = snapshot()
    show_snapshot(s)
    reasons = gate_reasons(s, need_mb=args.need_mb)
    log("ворота: можно" if not reasons else "ворота: нельзя — " + "; ".join(reasons))
    return 0 if not reasons else 75


def wait_gate(deadline, need_mb=0, during=False):
    """Ждёт свободный сервер; (снимок, None) — дождались, (снимок, причины) — нет.
    На старте ждёт до deadline (--wait). Между файлами ждёт, пока причина
    временная (load, память, цикл пробок), и сдаётся, как только кончилась ночь."""
    step = 30 if during else 300
    while True:
        s = snapshot()
        reasons = gate_reasons(s, during=during, need_mb=need_mb)
        if not reasons:
            return s, None
        night_over = during and not in_window(s.get("hhmm", ""))
        if night_over or (not during and time.time() + step > deadline):
            return s, reasons
        log(f"  жду: {'; '.join(reasons)}")
        time.sleep(step)


def upload_files(path):
    return sorted(n for n in os.listdir(path) if n.startswith(NAME + ".osrm")) + ["manifest.txt", "SHA256SUMS"]


def cmd_upload(args):
    day = os.path.join(WORK, args.date)
    with open(os.path.join(day, "audit.json")) as f:
        audit = json.load(f)
    kinds = [k for k in ("mld", "ch") if audit[k]["pass"]]
    for k in ("mld", "ch"):
        if k not in kinds:
            log(f"✗ {k}: аудит не пройден — не заливается ({'; '.join(audit[k]['fails'])})")
    if not kinds:
        return 1
    need_mb = round(sum(sum(os.path.getsize(os.path.join(set_dir(args.date, k), n)) for n in upload_files(set_dir(args.date, k)))
                        for k in kinds) / 1048576)
    deadline = time.time() + args.wait * 60
    s, reasons = wait_gate(deadline, need_mb=need_mb)
    show_snapshot(s)
    if reasons:
        msg = "сервер сейчас нельзя нагружать: " + "; ".join(reasons)
        if args.dry_run:
            log(f"(dry-run) {msg} — ночью upload ждал бы или вышел с кодом 75")
        else:
            log(f"✗ {msg}. Повторить ночью ({WINDOW[0]}–{WINDOW[1]} по Ташкенту), ничего не залито.")
            return 75
    for kind in kinds:
        rc = upload_kind(args, kind, s, deadline)
        if rc:
            return rc
    return 0


def upload_kind(args, kind, snap, deadline):
    local = set_dir(args.date, kind)
    final = f"{MLD_ROOT}/{candidate_name(kind, args.date)}"
    part = f"{MLD_ROOT}/{candidate_name(kind, args.date, part=True)}"
    nice = "nice -n 19 ionice -c3"
    if candidate_name(kind, args.date) in snap["entries"]:
        log(f"= {kind}: {final} уже на месте — проверка sha")
        if not args.dry_run:
            ssh(f"cd {final} && {nice} sha256sum -c --quiet SHA256SUMS", timeout=900)
            log(f"✓ {kind}: sha сошлись")
    else:
        files = upload_files(local)
        sizes = {}
        if not args.dry_run:
            ssh(f"mkdir -p {part}")
            for line in ssh(f"cd {part} && stat -c '%n %s' * 2>/dev/null || true").splitlines():
                name, _, size = line.rpartition(" ")
                sizes[name] = int(size)
        for name in files:
            src = os.path.join(local, name)
            if sizes.get(name) == os.path.getsize(src):
                log(f"  = {name} (уже залит)")
                continue
            cmd = ["scp", "-q", "-l", str(args.limit), "-o", "BatchMode=yes", src, f"{VPS}:{part}/{name}"]
            if args.dry_run:
                log("+ " + shlex.join(cmd))
                continue
            _, reasons = wait_gate(deadline, during=True)
            if reasons:
                log(f"✗ {kind}: остановлено перед {name}: {'; '.join(reasons)}. Недолитое — в {part}, "
                    "следующий запуск продолжит с этого файла.")
                return 75
            start = time.monotonic()
            subprocess.run(cmd, check=True)
            log(f"  ↑ {name}: {os.path.getsize(src) / 1048576:.1f} МБ за {time.monotonic() - start:.0f} с")
        verify = f"cd {part} && {nice} sha256sum -c --quiet SHA256SUMS && mv {part} {final}"
        if args.dry_run:
            log(f"+ ssh {VPS} {shlex.quote(verify)}")
        else:
            r = subprocess.run(["ssh", "-o", "BatchMode=yes", VPS, verify], capture_output=True, text=True, timeout=900)
            if r.returncode != 0:
                bad = [l.split(":")[0] for l in r.stdout.splitlines() if "FAILED" in l]
                if bad:
                    ssh(f"cd {part} && rm -f " + " ".join(shlex.quote(b) for b in bad))
                raise SystemExit(f"✗ {kind}: sha не сошлись ({', '.join(bad) or r.stderr.strip()}) — "
                                 "битые файлы удалены, повторите upload")
            log(f"✓ {kind}: {final}, sha сошлись")
    entries = snap["entries"] if args.dry_run else parse_snapshot(ssh(SNAPSHOT))["entries"]
    drop = prune_plan(entries, kind, args.date, snap["mounts"])
    for e in drop:
        cmd = f"{nice} rm -rf {MLD_ROOT}/{e}"
        if args.dry_run:
            log(f"+ ssh {VPS} {shlex.quote(cmd)}")
        else:
            ssh(cmd, timeout=600)
            log(f"  − старый кандидат {e}")
    if not drop:
        log(f"  {kind}: старых кандидатов сверх одного нет")
    return 0


# -------------------------------------------------------------------- switch

def switch_script(kind, date):
    """Шаги подмены на VPS с откатом (bash). Сам по себе ничего не запускает."""
    probes = " ".join(shlex.quote(p) for p in PROBES)
    head = f"""set -euo pipefail
# Всё внутри main: bash -s читает сценарий со stdin, и дочерний процесс,
# прочитавший stdin, съел бы его хвост.
main() {{
DATE={date}
# Корни переопределяются только тестами (test_graph_refresh.py, заглушки docker/curl).
R=${{RADARMAP_OSRM_MLD:-{MLD_ROOT}}}
B=${{RADARMAP_BASE:-/opt/radarmap}}
probe() {{  # $1 — порт; все пробы — code Ok, иначе 1
    local p
    for p in {probes}; do
        curl -sf -m 15 "http://127.0.0.1:$1$p" | grep -q '"code":"Ok"' || return 1
    done
}}
wait_probe() {{
    local i
    for i in $(seq 1 "${{PROBE_TRIES:-60}}"); do probe "$1" && return 0; sleep 1; done
    return 1
}}
# Замок цикла пробок (тот же mkdir, что в traffic_customize.sh): пока он наш,
# cron-цикл пишет «прошлый цикл ещё идёт — пропуск». Чужой замок старше
# 30 минут цикл снимает сам — держим его только на время переименований.
HELD=0
lock() {{
    local i
    for i in $(seq 1 120); do
        if mkdir "$R/.lock" 2>/dev/null; then HELD=1; return 0; fi
        sleep 5
    done
    echo "замок $R/.lock занят 10 минут" >&2; return 1
}}
# Снимаем только свой замок: в fresh_slot его берёт сам цикл пробок.
unlock() {{ if [ "$HELD" = 1 ]; then rmdir "$R/.lock" 2>/dev/null || true; HELD=0; fi; }}
trap unlock EXIT
"""
    if kind == "mld":
        return head + f"""C=$R/candidate-$DATE
[ -d "$C" ] || {{ echo "нет кандидата $C" >&2; exit 1; }}
( cd "$C" && nice -n 19 ionice -c3 sha256sum -c --quiet SHA256SUMS )
# Тот же образ, что у стенда: граф другой версии osrm-routed не откроет.
WANT=$(docker image inspect -f '{{{{.Id}}}}' "$(sed -n 's/^image //p' "$C/manifest.txt")")
[ "$WANT" = "$(docker inspect -f '{{{{.Image}}}}' {MLD_CONTAINER})" ] || {{ echo "образ кандидата не тот, что у стенда" >&2; exit 1; }}

# Слот пересобран с эталона: жёсткая ссылка .ebg в current — тот же inode.
inode() {{ ls -di "$1" | awk '{{print $1}}'; }}
# Цикл, занятый cron-ом, пишет «пропуск» с кодом 0 — тогда повтор; код 1 —
# новый слот не ответил, и цикл сам вернул прошлый.
fresh_slot() {{
    local i
    for i in $(seq 1 10); do
        "$R/bin/traffic_customize.sh" --force || return 1
        [ "$(inode "$R/current/uzbekistan.osrm.ebg")" = "$(inode "$R/pristine/uzbekistan.osrm.ebg")" ] && return 0
        sleep "${{SLOT_RETRY_SECONDS:-20}}"
    done
    return 1
}}

lock
# Не больше одного прежнего эталона: слоты держат свои жёсткие ссылки,
# удаление каталога их не задевает.
for old in "$R"/pristine.prev-*; do
    if [ -e "$old" ]; then nice -n 19 ionice -c3 rm -rf "$old"; fi
done
PREV=$R/pristine.prev-$DATE
mv "$R/pristine" "$PREV"
mv "$C" "$R/pristine"
unlock

if fresh_slot && wait_probe 8094; then
    echo "✓ стенд на новом графе $DATE (слот $(readlink "$R/current")); прежний эталон — $PREV"
    exit 0
fi

echo "✗ новый граф не ответил — откат на прежний эталон" >&2
lock
mv "$R/pristine" "$R/candidate-$DATE.failed"
mv "$PREV" "$R/pristine"
unlock
fresh_slot && wait_probe 8094 && echo "↩ стенд на прежнем графе" >&2 || echo "!!! откат не поднялся — nginx отдаёт резерв CH (8092)" >&2
exit 1
}}
main < /dev/null
"""
    return head + f"""C=$R/ch-candidate-$DATE
NEW=$B/osrm-ch-$DATE
[ -d "$C" ] || {{ echo "нет кандидата $C" >&2; exit 1; }}
( cd "$C" && nice -n 19 ionice -c3 sha256sum -c --quiet SHA256SUMS )
# Как контейнер запущен сейчас — этим же он поднимается при откате.
PREV_SRC=$(docker inspect -f '{{{{range .Mounts}}}}{{{{if eq .Destination "/data"}}}}{{{{.Source}}}}{{{{end}}}}{{{{end}}}}' {CH_CONTAINER})
PREV_IMG=$(docker inspect -f '{{{{.Image}}}}' {CH_CONTAINER})
PREV_CMD=$(docker inspect -f '{{{{json .Config.Cmd}}}}' {CH_CONTAINER} | python3 -c 'import json, shlex, sys; print(shlex.join(json.load(sys.stdin)))')
docker inspect {CH_CONTAINER} > "$B/{CH_CONTAINER}.inspect-$DATE.json"
WANT=$(docker image inspect -f '{{{{.Id}}}}' "$(sed -n 's/^image //p' "$C/manifest.txt")")
[ "$WANT" = "$PREV_IMG" ] || {{ echo "образ кандидата не тот, что у {CH_CONTAINER}" >&2; exit 1; }}
[ "$PREV_SRC" != "$NEW" ] || {{ echo "$NEW уже боевой" >&2; exit 1; }}
mv "$C" "$NEW"

run() {{  # $1 — каталог графа, $2 — команда osrm-routed
    docker rm -f {CH_CONTAINER} >/dev/null 2>&1 || true
    docker run -d --name {CH_CONTAINER} --restart unless-stopped -p 127.0.0.1:8092:5000 \\
        -v "$1:/data" "$PREV_IMG" $2 >/dev/null
}}
# Простой — секунды: маршруты идут на стенд MLD, traffic_build.py повторит match
# через 2 мин. Замок цикла пробок — чтобы стенд не перезапустился в эти же
# секунды и nginx не остался без обоих апстримов.
lock
run "$NEW" "osrm-routed --algorithm ch --mmap 1 /data/uzbekistan.osrm"
if wait_probe 8092; then
    echo "✓ резерв CH на новом графе $NEW; прежний — $PREV_SRC (его не удалять до следующей недели)"
    exit 0
fi
echo "✗ новый CH не ответил — откат на $PREV_SRC" >&2
run "$PREV_SRC" "$PREV_CMD"
mv "$NEW" "$C.failed"
wait_probe 8092 && echo "↩ резерв CH на прежнем графе" >&2 || echo "!!! откат CH не поднялся: docker logs {CH_CONTAINER}" >&2
exit 1
}}
main < /dev/null
"""


def cmd_switch(args):
    script = switch_script(args.kind, args.date)
    if not args.i_am_owner:
        log(f"# Подмена {args.kind.upper()} на граф {args.date} — шаги для владельца, ничего не выполнено.")
        log(f"# Выполнить: python3 server/osrm/graph_refresh.py switch --date {args.date} --kind {args.kind} --i-am-owner")
        log(f"# или вручную: ssh {VPS} 'bash -s' < файл_с_этим_текстом\n")
        print(script)
        return 0
    r = subprocess.run(["ssh", VPS, "bash -s"], input=script, text=True)
    return r.returncode


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--date", default=today())
    b.add_argument("--pbf", help="готовая выгрузка вместо Geofabrik")
    b.add_argument("--threads", type=int, default=2)
    b.add_argument("--quiet", action="store_true")
    a = sub.add_parser("audit")
    a.add_argument("--date", default=today())
    a.add_argument("--old-mld")
    a.add_argument("--old-ch")
    a.add_argument("--pairs", default=os.path.join(HERE, "audit_pairs.json"))
    g = sub.add_parser("gate")
    g.add_argument("--need-mb", type=int, default=0)
    u = sub.add_parser("upload")
    u.add_argument("--date", default=today())
    u.add_argument("--dry-run", action="store_true")
    u.add_argument("--wait", type=int, default=0, help="ждать свободный сервер, минут")
    u.add_argument("--limit", type=int, default=SCP_LIMIT_KBIT, help="scp -l, Кбит/с")
    s = sub.add_parser("switch")
    s.add_argument("--date", default=today())
    s.add_argument("--kind", choices=("mld", "ch"), required=True)
    s.add_argument("--i-am-owner", action="store_true")
    args = p.parse_args()
    return {"build": cmd_build, "audit": cmd_audit, "gate": cmd_gate,
            "upload": cmd_upload, "switch": cmd_switch}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
