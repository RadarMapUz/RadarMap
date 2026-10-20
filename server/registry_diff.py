#!/usr/bin/env python3
"""registry_diff.py — свежий реестр data.egov.uz против базы (план 11.4).

Только чтение: тянет реестр тем же кодом, что update_cameras.py (fetch +
build), и пишет CSV для ручного разбора — ни базы, ни сервера не трогает.

  «нет в реестре»  — камера базы, у которой в 300 м нет точки реестра (координаты
                     базы прижаты к оси дороги, поэтому порог не 50 м). НЕ удалять
                     по этому списку: исчезновение из реестра не значит, что камеры
                     нет на дороге, а молчание о камере хуже лишнего предупреждения.
                     Колонка «близнец» — камеры базы в 60 м (встречные пары).
  «новая в реестре» — точка реестра без камеры базы в 300 м: кандидат на
                     дописывание в конец базы (id продолжают нумерацию, профиль —
                     тем же snap_cameras по выгрузке вокруг точки).

Запуск:  python3 -I server/registry_diff.py server RadarMap/Resources/cameras.json out.csv
"""
import sys, json, csv, math
sys.path.insert(0, sys.argv[1])
import update_cameras as uc
db = json.load(open(sys.argv[2]))
rows = uc.fetch()
reg = uc.build(rows)
print("реестр:", len(rows), "строк →", len(reg), "точек; база:", len(db))
def dist(a, b):
    k = 111320 * math.cos(math.radians(a["lat"]))
    return math.hypot((a["lat"] - b["lat"]) * 110540, (a["lon"] - b["lon"]) * k)
cell = {}
for r in reg:
    cell.setdefault((int(r["lat"] / 0.01), int(r["lon"] / 0.01)), []).append(r)
def near(p, pool_cell, limit):
    best = None
    ci, cj = int(p["lat"] / 0.01), int(p["lon"] / 0.01)
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            for q in pool_cell.get((ci + di, cj + dj), []):
                d = dist(p, q)
                if d <= limit and (best is None or d < best[1]): best = (q, d)
    return best
gone = []
for c in db:
    m = near(c, cell, 300)
    if m is None: gone.append(c)
dbcell = {}
for c in db: dbcell.setdefault((int(c["lat"] / 0.01), int(c["lon"] / 0.01)), []).append(c)
new = [r for r in reg if near(r, dbcell, 300) is None]
out = sys.argv[3]
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["что", "id_базы", "тип", "регион", "город", "адрес", "lat", "lon", "близнец_в_базе"])
    for c in gone:
        twin = [o for o in dbcell.get((int(c["lat"]/0.01), int(c["lon"]/0.01)), []) if o is not c and dist(o, c) < 60]
        w.writerow(["нет в реестре", c["id"], c["type"], c["region"], c["city"], c["location"], c["lat"], c["lon"],
                    ";".join(str(o["id"]) for o in twin)])
    for r in new:
        w.writerow(["новая в реестре", "", r["type"], r["region"], r["city"], r["location"], r["lat"], r["lon"], ""])
print("нет в реестре:", len(gone), " новые в реестре:", len(new))
print("ids:", [c["id"] for c in gone][:60])
