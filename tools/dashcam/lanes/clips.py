"""Отрезки полного fps вокруг кадров истины: копия ролика → кадры → удалить.

    python3 clips.py [truth.json] [--half 4.0]

Для каждого кадра истины вынимаем все кадры ролика в окне pos ± HALF с
(у BYD ~25,6 к/с, частота плавает — время берём из pts, а не из номера).
Кадр режется так же, как frames.py (строки 70…864 → 1280×529), чтобы
калибровка и маски работали без изменений. Ролики с карты копируются
через fat32.py только на чтение, не больше BATCH штук сразу, и удаляются
сразу после извлечения.

Итог: ~/RadarMapBuild/dashcam/lanes/windows/<id кадра>/f_0001.jpg… и
pts.json — время каждого кадра в секундах ролика.
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from framesdb import OUT  # noqa: E402

FFMPEG = "/opt/homebrew/bin/ffmpeg"
DEVICE = "/dev/disk12s1"
WIN = os.path.join(OUT, "windows")
TMP = os.path.join(OUT, "tmp", "clips")
HALF = 2.0
BATCH = 8
_PTS = re.compile(r"n:\s*(\d+)\s+pts:\s*-?\d+\s+pts_time:([-0-9.]+)")


def extract_window(clip_path, pos, out_dir, half=HALF):
    """Все кадры ролика в [pos − half, pos + half] → out_dir; → список pts."""
    # -t до -i: с -copyts выходное -t считается от нуля, а метки кадров
    # начинаются с start — и не пишется ни один кадр.
    os.makedirs(out_dir, exist_ok=True)
    start = max(0.0, pos - half)
    vf = "crop=1920:794:0:70,scale=1280:529,showinfo"
    p = subprocess.run([FFMPEG, "-v", "info", "-nostdin", "-y", "-copyts",
                        "-ss", f"{start:.3f}", "-t", f"{2 * half:.3f}", "-i", clip_path,
                        "-vf", vf, "-fps_mode", "passthrough", "-q:v", "2",
                        os.path.join(out_dir, "f_%04d.jpg")],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-500:])
    pts = [float(m.group(2)) for m in _PTS.finditer(p.stderr)]
    made = sorted(n for n in os.listdir(out_dir) if n.startswith("f_"))
    if len(made) != len(pts):
        raise RuntimeError(f"кадров {len(made)}, а pts {len(pts)}")
    with open(os.path.join(out_dir, "pts.json"), "w") as f:
        json.dump({"pos": pos, "pts": pts}, f)
    return pts


def done(fid):
    return os.path.exists(os.path.join(WIN, str(fid), "pts.json"))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else os.path.join(HERE, "truth.json")
    half = HALF
    if "--half" in sys.argv:
        half = float(sys.argv[sys.argv.index("--half") + 1])
    with open(path) as f:
        rows = json.load(f)
    todo = [r for r in rows if not done(r["id"])]
    by_clip = {}
    for r in todo:
        by_clip.setdefault(r["clip"], []).append(r)
    clips = sorted(by_clip)
    print(f"окон к извлечению: {len(todo)}, роликов: {len(clips)}")
    card = None
    os.makedirs(TMP, exist_ok=True)
    try:
        for b in range(0, len(clips), BATCH):
            batch = clips[b:b + BATCH]
            local = {}
            for c in batch:
                if c.startswith("card:"):
                    if card is None:
                        import fat32
                        fs = fat32.FAT32(DEVICE)
                        index = {p: (cl, size) for p, isdir, cl, size, _ in fs.walk()
                                 if not isdir}
                        card = (fs, index)
                    fs, index = card
                    name = c[len("card:"):]
                    dst = os.path.join(TMP, os.path.basename(name))
                    cl, size = index[name]
                    fs.copy(cl, size, dst)
                    local[c] = (dst, True)
                else:
                    local[c] = (c, False)
            for c in batch:
                src, tmp = local[c]
                try:
                    for r in by_clip[c]:
                        out = os.path.join(WIN, str(r["id"]))
                        pts = extract_window(src, r["pos"], out, half)
                        print(f"  {r['id']}: {len(pts)} кадров", flush=True)
                finally:
                    if tmp and os.path.exists(src):
                        os.remove(src)
    finally:
        if card:
            card[0].close()
        shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    main()
