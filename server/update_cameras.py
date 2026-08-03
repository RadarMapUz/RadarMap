#!/usr/bin/env python3
"""RadarMap camera DB auto-updater (server cron, stdlib only).

Pulls the MVD open-data set 1-008-0027 from data.egov.uz, dedups + normalizes,
and if the result changed, writes /opt/radarmap/www/cameras.json (minified) and
bumps version.json. Safe to run on a schedule; no-op when data is unchanged.
"""
import json, re, hashlib, urllib.request, os, sys, time

GUID = "62735473d44f5eea297cef3d"
API = f"https://data.egov.uz/apiClient/Main/GetMainData?GuidId={GUID}"
WWW = "/opt/radarmap/www"
LOG = "/opt/radarmap/api/update.log"

LOWER = {
 "shahri","shahar","tumani","tuman","viloyati","viloyat","respublikasi",
 "ko'chasi","ko'chalari","ko'cha","kochasi","kuchasi","kesishgan","kesishmasi",
 "chorrahasi","chorraha","yo'li","yo'lining","yoli","yo'l","avtomobil","mavzesi",
 "va","bilan","oldi","oldida","oldidagi","qarshisida","ro'parasida","atrofi",
 "mahallasi","mfy","katta","kichik","yangi","eski","km","metro",
 "bekati","bekat","piyodalar","yo'lakchasi","o'tish","joyi","maktab","maktabi",
 "zavodi","bozori","bozor","masjidi","kasalxonasi","shifoxonasi","markazi",
 "qishlog'i","qishloq","posyolkasi","tomonga","tomon","yonida","orqali","hududi",
}
TYPE_MAP = {"Statsionar kamera":"Стационар камера","Statsionar radar":"Стационар радар",
            "Intellektual + radar":"Интеллектуал + радар"}
PRIORITY = {"Интеллектуал + радар":3,"Стационар камера":2,"Стационар радар":1}

def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line)
    try:
        with open(LOG,"a") as f: f.write(line+"\n")
    except OSError: pass

def is_code(tok):
    t = re.sub(r"[-.,()\"']","",tok)
    return bool(re.search(r"\d",t)) and bool(re.search(r"[A-Za-z]",t))
def cap(w):
    lw=w.lower()
    if re.sub(r"[^\w']","",lw) in LOWER: return lw
    if is_code(w): return w.upper()
    for i,ch in enumerate(lw):
        if ch.isalpha(): return lw[:i]+ch.upper()+lw[i+1:]
    return lw
def smart(s):
    s=re.sub(r"\s+"," ",s).strip()
    return " ".join(cap(w) for w in s.split(" ") if w)
def coord(s):
    s=s.replace(",",".").strip()
    if "." not in s and len(s)>=3: s=s[:2]+"."+s[2:]
    return round(float(s),6)

def fetch():
    body = json.dumps({"guidId":GUID,"fields":{},"limit":6000,"offset":0}).encode()
    req = urllib.request.Request(API, data=body, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["result"]["data"]

def build(rows):
    def val(r,k): return (r["tableColumn"][k]["data"] or "").strip()
    points={}
    for r in rows:
        vil=val(r,"Viloyat")
        if vil.startswith("Viloyat"): continue
        try:
            a=coord(val(r,"Kenglik")); b=coord(val(r,"Uzunlik"))
        except ValueError: continue
        # Автодетект перестановки колонок: 03.08.2026 реестр внезапно поменял
        # Kenglik/Uzunlik местами, и жёсткая проверка границ отбрасывала всё.
        if 37<=a<=46 and 55<=b<=74: la,lo=a,b
        elif 37<=b<=46 and 55<=a<=74: la,lo=b,a
        else: continue
        typ=TYPE_MAP.get(val(r,"Turi"), val(r,"Turi"))
        rec={"region":vil.split("/")[0].strip(),"city":smart(val(r,"Tuman")),
             "location":smart(val(r,"Joylashganjoyi")),"lat":la,"lon":lo,"type":typ}
        key=(la,lo)
        if key not in points or PRIORITY.get(typ,0)>PRIORITY.get(points[key]["type"],0):
            points[key]=rec
    cams=sorted(points.values(), key=lambda r:(r["region"],r["city"],r["location"],r["lat"],r["lon"]))
    for i,c in enumerate(cams,1): c["id"]=i
    return [{"id":c["id"],"region":c["region"],"city":c["city"],"location":c["location"],
             "lat":c["lat"],"lon":c["lon"],"type":c["type"]} for c in cams]

ACCIDENT_GUID = "60fb99752a2e256d868e8259"

def probe_accidents():
    """Датасет МВД «ДТП без личной идентификации» существует, но ПУСТ (0 строк
    на 03.08.2026). Если его когда-нибудь наполнят координатами — это готовый
    слой «аварийно-опасные участки» для карты. Дешёвая проба при каждом
    ручном прогоне: наполнился — кричим в лог."""
    try:
        body = json.dumps({"guidId": ACCIDENT_GUID, "fields": {}, "limit": 1,
                           "offset": 0}).encode()
        req = urllib.request.Request(
            f"https://data.egov.uz/apiClient/Main/GetMainData?GuidId={ACCIDENT_GUID}",
            data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            count = json.load(r)["result"].get("count", 0)
        if count:
            log(f"!!! ДТП-датасет НАПОЛНИЛСЯ: {count} строк — можно делать слой аварийности")
    except Exception as e:
        log(f"проба ДТП-датасета не удалась (не страшно): {e}")


def main():
    try:
        rows = fetch()
    except Exception as e:
        log(f"FETCH FAILED: {e}"); sys.exit(1)
    cams = build(rows)
    if len(cams) < 500:
        log(f"REFUSING: only {len(cams)} cameras parsed (source problem?)"); sys.exit(1)

    payload = json.dumps(cams, ensure_ascii=False, separators=(",",":"))
    new_hash = hashlib.sha256(payload.encode()).hexdigest()

    # Живые cameras.json/version.json теперь публикуются ТОЛЬКО владельцем с
    # Ed25519-подписью (deploy_db.sh): приложение отвергает базу без подписи,
    # а ключ подписи на сервере не хранится (компрометация VPS не должна давать
    # возможность подсовывать камеры). Крон складывает свежий дамп кандидатом.
    cam_path = os.path.join(WWW,"cameras_candidate.json")
    old_hash = None
    try:
        with open(os.path.join(WWW,".camhash")) as f: old_hash=f.read().strip()
    except OSError: pass

    probe_accidents()
    if new_hash == old_hash:
        log(f"UNCHANGED: {len(cams)} cameras, hash {new_hash[:12]}"); return

    tmp=cam_path+".tmp"
    with open(tmp,"w",encoding="utf-8") as f: f.write(payload)
    os.replace(tmp,cam_path)
    with open(os.path.join(WWW,".camhash"),"w") as f: f.write(new_hash)
    log(f"CANDIDATE UPDATED: {len(cams)} cameras, hash {new_hash[:12]} — review+sign via deploy_db.sh")

if __name__ == "__main__":
    main()
