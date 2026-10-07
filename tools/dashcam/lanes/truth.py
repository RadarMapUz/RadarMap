"""Истина по полосам: 100 кадров, размеченных глазами (truth_labels.txt).

    python3 truth.py        → truth.json (рядом и в ~/RadarMapBuild/dashcam/lanes/)

Строка разметки: n | полос | своя (номер слева) | слева | справа | судим |
уверенно | заметка. «Слева» — что ограничивает наше направление слева
(бордюр/газон/ограждение — физическая разделительная, сплошная — осевая
краской, парковка), «справа» — бордюр/газон/ограждение/парковка. «Не
судим» — перекрёсток, переход вплотную, пробка, нет разметки на широкой
дороге: там и человек не скажет число рядов по одному кадру. «Уверенно» —
разметка видна целиком; иначе число рядов — по машинам и ширине.
Кадры 0–49 — половина настройки, 50–99 — проверки (деление по поездкам,
truth_pick.py).
"""
import json
import os

from framesdb import OUT

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(HERE, "truth_labels.txt")
PICK = os.path.join(OUT, "truth_pick.json")


def parse_labels(lines):
    """Строки truth_labels.txt → {n: dict}."""
    out = {}
    for l in lines:
        l = l.rstrip("\n")
        if not l.strip() or l.startswith("#"):
            continue
        n, la, own, left, right, j, c, note = l.split("|")
        out[int(n)] = {
            "lanes": None if la == "-" else int(la),
            "own": None if own == "-" else int(own),
            "left": None if left == "-" else left,
            "right": None if right == "-" else right,
            "judge": j == "1", "conf": c == "1", "note": note,
        }
    return out


def load(path=None):
    path = path or os.path.join(HERE, "truth.json")
    with open(path) as f:
        return json.load(f)


def main():
    with open(PICK) as f:
        pick = json.load(f)
    with open(LABELS) as f:
        lab = parse_labels(f)
    missing = set(range(len(pick))) - set(lab)
    if missing:
        raise SystemExit(f"нет разметки для {sorted(missing)}")
    out = []
    for i, r in enumerate(pick):
        d = {k: r[k] for k in ("id", "trip", "half", "clip_id", "clip", "pos", "t",
                               "kmh", "jpg")}
        d["n"] = i
        d.update(lab[i])
        out.append(d)
    for p in (os.path.join(HERE, "truth.json"), os.path.join(OUT, "truth.json")):
        with open(p, "w") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
    for h in ("tune", "test"):
        s = [o for o in out if o["half"] == h]
        j = [o for o in s if o["judge"]]
        print(f"{h}: кадров {len(s)}, судим {len(j)}, уверенно {sum(o['conf'] for o in j)}")


if __name__ == "__main__":
    main()
