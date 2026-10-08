"""Один запуск: размеченные кадры → маски → обучение → метрики → Core ML.

    python3 seg_train.py [--data labels|pseudo] [--epochs 30] [--val-trips N]
                         [--no-coreml] [--tag имя] [--hold-trips a,b]

--data labels — разметка человека (labels/), pseudo — псевдоразметка v2
(pseudo/, проверка трубы). Проверочная часть — ЦЕЛЫЕ ПОЕЗДКИ (последние N
по алфавиту, или ровно --hold-trips — для честного выбора варианта на окнах
настройки, которые сами есть в разметке), как и в истине: соседние кадры одной поездки почти
одинаковы, и деление по кадрам дало бы красивую, но ложную точность.

Итог в ~/RadarMapBuild/dashcam/lanes/models/:
  seg_<tag>.pt (+ seg_latest.pt) — веса; seg_<tag>.json — метрики (IoU по
  классам на проверочных поездках, время); seg_<tag>.mlpackage — Core ML
  (вход image 1280×192 RGB, выход — логиты классов 8×192×1280).

Аугментации (только обучение): яркость/контраст/гамма, оттенок, блики
(яркие размытые пятна и полосы — солнце в стекле), шум, размытие, сдвиг
по горизонтали (кадрирование по ширине) и по вертикали (±6 строк —
кивок машины), зеркало. Маска сдвигается вместе с кадром, вне кадра — 255.
"""
import argparse
import json
import os
import sys
import time

import numpy as np

from framesdb import OUT
from lanes import load_camera
from marking import load_rgb
from seg_common import CLASSES, IGNORE, LABELS, MODELS, PSEUDO, all_labels, image_path
from seg_masks import frame_mask
from seg_model import CROP_H, MEAN, N_CLASSES, STD, Y0, build

TRAIN_W = 640
HERE = os.path.dirname(os.path.abspath(__file__))
COREML_PY = os.path.join(OUT, "venv-coreml", "bin", "python")


def load_set(root, cam):
    labs = [l for l in all_labels(root) if not l.get("skip")]
    X = np.zeros((len(labs), CROP_H, 1280, 3), np.uint8)
    Y = np.zeros((len(labs), CROP_H, 1280), np.uint8)
    for i, lab in enumerate(labs):
        X[i] = load_rgb(image_path(lab))[Y0:Y0 + CROP_H].astype(np.uint8)
        Y[i] = frame_mask(lab, cam)[Y0:Y0 + CROP_H]
    return labs, X, Y


def split_by_trip(labs, n_val, hold=None):
    trips = sorted({l["trip"] for l in labs})
    if hold:
        val = set(hold)
    else:
        val = set(trips[-n_val:]) if len(trips) > n_val else set()
    tr = [i for i, l in enumerate(labs) if l["trip"] not in val]
    va = [i for i, l in enumerate(labs) if l["trip"] in val]
    return tr, va, sorted(val)


def augment(img, m, rng, width=TRAIN_W):
    """uint8 HWC + маска → float HWC и маска (кадрирование, свет, блики)."""
    h, w = m.shape
    x0 = int(rng.integers(0, w - width + 1))
    img = img[:, x0:x0 + width].astype(np.float32)
    m = m[:, x0:x0 + width].copy()
    dy = int(rng.integers(-6, 7))
    if dy:
        img = np.roll(img, dy, 0)
        m = np.roll(m, dy, 0)
        if dy > 0:
            img[:dy] = img[dy:dy + 1]
            m[:dy] = IGNORE
        else:
            img[dy:] = img[dy - 1:dy]
            m[dy:] = IGNORE
    if rng.random() < 0.5:
        img = img[:, ::-1]
        m = m[:, ::-1]
    # Свет: контраст, яркость, гамма, оттенок.
    img = img * rng.uniform(0.6, 1.35) + rng.uniform(-30, 30)
    img = img * rng.uniform(0.92, 1.08, size=3)
    img = 255 * (np.clip(img, 0, 255) / 255) ** rng.uniform(0.7, 1.4)
    # Блики: пятно и/или наклонная полоса.
    yy, xx = np.mgrid[0:h, 0:width].astype(np.float32)
    if rng.random() < 0.4:
        cy, cx = rng.uniform(-40, h), rng.uniform(0, width)
        s = rng.uniform(25, 160)
        img += rng.uniform(40, 140) * np.exp(-((yy - cy) ** 2 + (xx - cx) ** 2) / (2 * s * s))[..., None]
    if rng.random() < 0.25:
        a = rng.uniform(-1.5, 1.5)
        c = rng.uniform(0, width)
        d = np.abs(xx - (c + a * yy)) / np.sqrt(1 + a * a)
        img += rng.uniform(30, 90) * np.exp(-d ** 2 / (2 * rng.uniform(4, 25) ** 2))[..., None]
    if rng.random() < 0.3:
        img += rng.normal(0, rng.uniform(2, 8), img.shape)
    if rng.random() < 0.2:
        from scipy.ndimage import gaussian_filter
        img = gaussian_filter(img, (rng.uniform(0.5, 1.2), rng.uniform(0.5, 1.2), 0))
    img = np.clip(img, 0, 255)
    return np.ascontiguousarray(img), np.ascontiguousarray(m)


def to_tensor(imgs):
    import torch
    x = (np.asarray(imgs, np.float32) / 255.0 - MEAN) / STD
    return torch.from_numpy(x.transpose(0, 3, 1, 2).copy())


def class_weights(Y, idx):
    cnt = np.bincount(Y[idx].ravel(), minlength=256)[:N_CLASSES].astype(np.float64)
    freq = cnt / max(cnt.sum(), 1)
    w = 1.0 / np.sqrt(np.maximum(freq, 1e-4))
    return (w / w[0]).clip(1, 30)


def iou(pred, gt):
    """IoU по классам (пиксели 255 не считаются); класс, которого нет ни в
    истине, ни в ответе, — None."""
    ok = gt != IGNORE
    out = {}
    for c, name in enumerate(CLASSES):
        p, g = (pred == c) & ok, (gt == c) & ok
        u = (p | g).sum()
        out[name] = None if u == 0 else round(float((p & g).sum() / u), 3)
    lp = np.isin(pred, (1, 2, 3)) & ok
    lg = np.isin(gt, (1, 2, 3)) & ok
    u = (lp | lg).sum()
    out["линии_все"] = None if u == 0 else round(float((lp & lg).sum() / u), 3)
    return out


def evaluate(net, X, Y, idx, device):
    import torch
    net.eval()
    preds = []
    with torch.no_grad():
        for i in range(0, len(idx), 8):
            b = idx[i:i + 8]
            p = net(to_tensor(X[b]).to(device)).argmax(1).cpu().numpy().astype(np.uint8)
            preds.append(p)
    pred = np.concatenate(preds) if preds else np.zeros((0,) + Y.shape[1:], np.uint8)
    return iou(pred, Y[idx]), pred


def export_coreml(pt, jpgs):
    """Core ML — отдельным процессом в venv-coreml (seg_export.py): у
    coremltools нет готовых библиотек под Python основного venv."""
    import subprocess
    py = COREML_PY if os.path.exists(COREML_PY) else sys.executable
    p = subprocess.run([py, os.path.join(HERE, "seg_export.py"), pt, *jpgs],
                       capture_output=True, text=True, cwd=HERE)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "seg_export упал")
    return json.loads(p.stdout.strip().splitlines()[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", choices=("labels", "pseudo"), default="labels")
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--val-trips", type=int, default=2)
    ap.add_argument("--base", type=int, default=16)
    ap.add_argument("--tag", default=None)
    ap.add_argument("--no-coreml", action="store_true")
    ap.add_argument("--hold-trips", default="", help="поездки проверки через запятую (вне обучения целиком)")
    a = ap.parse_args()
    import torch
    from torch import nn
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tag = a.tag or a.data
    root = PSEUDO if a.data == "pseudo" else LABELS
    cam = load_camera()
    t0 = time.time()
    labs, X, Y = load_set(root, cam)
    if len(labs) < 4:
        raise SystemExit(f"мало размеченных кадров в {root}: {len(labs)}")
    tr, va, val_trips = split_by_trip(labs, a.val_trips, [t for t in a.hold_trips.split(",") if t])
    print(f"кадров {len(labs)}: обучение {len(tr)}, проверка {len(va)} (поездки {val_trips}); "
          f"маски за {time.time() - t0:.0f} с; устройство {device}", flush=True)
    rng = np.random.default_rng(0)
    torch.manual_seed(0)
    net = build(a.base).to(device)
    w = torch.tensor(class_weights(Y, tr), dtype=torch.float32, device=device)
    loss_fn = nn.CrossEntropyLoss(weight=w, ignore_index=IGNORE)
    opt = torch.optim.AdamW(net.parameters(), lr=2e-3, weight_decay=1e-4)
    steps = a.epochs * max(1, len(tr) // a.batch)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps)
    history = []
    t1 = time.time()
    for ep in range(a.epochs):
        net.train()
        order = rng.permutation(tr)
        losses = []
        for i in range(0, len(order) - a.batch + 1, a.batch):
            b = order[i:i + a.batch]
            pairs = [augment(X[j], Y[j], rng) for j in b]
            x = to_tensor(np.stack([p[0] for p in pairs])).to(device)
            y = torch.from_numpy(np.stack([p[1] for p in pairs]).astype(np.int64)).to(device)
            loss = loss_fn(net(x), y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            losses.append(loss.item())
        rec = {"epoch": ep + 1, "loss": round(float(np.mean(losses)), 4)}
        if va and ((ep + 1) % 5 == 0 or ep + 1 == a.epochs):
            m, _ = evaluate(net, X, Y, va, device)
            rec["val"] = m
        history.append(rec)
        print(json.dumps(rec, ensure_ascii=False), flush=True)
    train_s = time.time() - t1
    final, _ = evaluate(net, X, Y, va, device) if va else ({}, None)
    train_m, _ = evaluate(net, X, Y, tr[:: max(1, len(tr) // 64)], device)
    os.makedirs(MODELS, exist_ok=True)
    ck = {"state": {k: v.cpu() for k, v in net.state_dict().items()}, "base": a.base,
          "classes": CLASSES, "y0": Y0, "crop_h": CROP_H, "data": a.data}
    pt = os.path.join(MODELS, f"seg_{tag}.pt")
    torch.save(ck, pt)
    torch.save(ck, os.path.join(MODELS, "seg_latest.pt"))
    report = {"data": a.data, "frames": len(labs), "train": len(tr), "val": len(va),
              "val_trips": val_trips, "epochs": a.epochs, "train_s": round(train_s),
              "device": device, "params": int(sum(p.numel() for p in net.parameters())),
              "val_iou": final, "train_iou_sample": train_m, "history": history}
    if not a.no_coreml:
        t2 = time.time()
        try:
            check = [image_path(labs[i]) for i in (va[:2] if va else tr[:2])]
            report["coreml"] = export_coreml(pt, check)
            report["coreml"]["s"] = round(time.time() - t2, 1)
        except Exception as e:  # Core ML — отдельная ступень: её сбой не теряет обученную модель
            report["coreml"] = {"error": repr(e)}
    with open(os.path.join(MODELS, f"seg_{tag}.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in report.items() if k != "history"}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
