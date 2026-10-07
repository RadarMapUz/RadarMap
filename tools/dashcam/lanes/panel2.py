"""Панель v2: опорный кадр окна с линиями-треками, вид сверху и
«поперечник во времени» (гистограммы кадров окна одна под другой: линия —
вертикальная полоса, прерывистая — пунктир, перестроение — наклон)."""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from camera import BEV_H, BEV_W, RES, X_MIN, Z_MAX, bev_map, src_to_jpg, warp
from lanes import Z_LINES, Z_NEAR, Z_REF
from track import track_x_at

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
COL = {"solid": (255, 60, 60), "dashed": (60, 220, 255), "edge": (255, 170, 0),
       None: (110, 110, 110)}
_maps = {}


def _font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def render(res, truth, cam):
    data, k_ref, cum = res["_data"], res["_k_ref"], res["_cum"]
    rgb = data[k_ref]["rgb"].astype(np.float32)
    s = data[k_ref]["s"]
    key = id(cam)
    if key not in _maps:
        _maps[key] = bev_map(cam)
    rows, cols = _maps[key]
    bev = Image.fromarray(np.nan_to_num(warp(rgb, rows, cols)).clip(0, 255).astype(np.uint8))
    bd = ImageDraw.Draw(bev)
    fimg = Image.fromarray(rgb.clip(0, 255).astype(np.uint8))
    fd = ImageDraw.Draw(fimg)

    def bev_px(x, z):
        return (x - X_MIN) / RES, (Z_MAX - z) / RES

    for x in range(-12, 13, 2):
        bd.line([bev_px(x, 6), bev_px(x, 40)], fill=(70, 70, 70) if x else (255, 255, 0), width=1)
    for z in range(10, 41, 5):
        bd.line([bev_px(-12, z), bev_px(12, z)], fill=(70, 70, 70), width=1)

    def draw_line(c, col, width_f=3, width_b=5, z0=Z_NEAR, z1=Z_LINES):
        bd.line([bev_px(c + s * (z0 - Z_REF), z0), bev_px(c + s * (z1 - Z_REF), z1)],
                fill=col, width=width_b)
        zs = np.linspace(z0, z1, 30)
        u, v = cam.ground_to_src(c + s * (zs - Z_REF), zs)
        x, y = src_to_jpg(u, v)
        pts = [(float(px), float(py)) for px, py in zip(x, y) if np.isfinite(px)]
        if len(pts) > 1:
            fd.line(pts, fill=col, width=width_f)

    for l in res["lines"]:
        if l["kind"] is None:
            draw_line(l["x_ref"], COL[None], 1, 1)
    for l in res["lines"]:
        if l["kind"] is not None:
            draw_line(l["x_ref"], COL[l["kind"]])
    for side in ("left_edge", "right_edge"):
        kind, x = res[side]
        if x is not None:
            draw_line(x, (255, 0, 255) if kind == "curb" else (150, 0, 150), 5, 6, 5.0, 16.0)
    X, Z = data[k_ref]["X"], data[k_ref]["Z"]
    for x, z in zip(X[::2], Z[::2]):
        bd.point(bev_px(x, z), fill=(0, 255, 0))
    bd.rectangle([bev_px(-0.9, 6.6), bev_px(0.9, 6.0)], fill=(255, 255, 255))

    # Поперечник во времени: по строке на кадр, X от −12,5 до 12,5.
    H = np.stack([f["h"] for f in data]).astype(np.float32)
    H = (255 * np.clip(H / (np.percentile(H, 99.5) + 1e-6), 0, 1)).astype(np.uint8)
    himg = Image.fromarray(H).resize((BEV_W, max(len(data) * 4, 120)), Image.NEAREST).convert("RGB")
    hd = ImageDraw.Draw(himg)
    yr = k_ref * himg.height / len(data)
    hd.line([(0, yr), (BEV_W, yr)], fill=(255, 255, 0))
    for l in res["_good"]:
        t = l["track"]
        pts = [((track_x_at(t, k, cum) + 12.5) / 25 * BEV_W, (k + 0.5) * himg.height / len(data))
               for k in t["k"]]
        if len(pts) > 1:
            hd.line(pts, fill=COL[l["kind"]], width=1)

    W = 1280 + 20 + BEV_W + 20 + BEV_W
    out = Image.new("RGB", (W, BEV_H + 70), (20, 20, 20))
    out.paste(fimg, (0, 70))
    out.paste(bev, (1300, 70))
    out.paste(himg, (1300 + BEV_W + 20, 70))
    d = ImageDraw.Draw(out)
    t = truth
    tt = (f"истина: {t['lanes']} полос, своя {t['own']}" if t["judge"] else "истина: не судим") + \
        f" · слева {t['left'] or '?'} · справа {t['right'] or '?'} · {t['note']}"
    lay = res["ref_layout"]
    at = (f"ответ: {res['lanes']} полос, своя {res['own']} (голосов {res['share']:.0%})"
          if res["lanes"] else f"ответ: не знаю (голосов {res['share']:.0%})")
    if lay:
        at += f" · опорный кадр: {lay['lanes']}/{lay['own']}, своя {lay['own_width']:.2f} м"
    at += f" · края: {res['left_edge'][0] or '?'} / {res['right_edge'][0] or '?'}"
    d.text((10, 6), f"#{t['n']} кадр {t['id']} · {t['trip']} · {res['kmh']:.0f} км/ч · {tt}",
           fill=(200, 200, 200), font=_font(18))
    ok = t["judge"] and res["lanes"] == t["lanes"]
    col = (120, 255, 120) if ok else ((255, 120, 120) if t["judge"] and res["lanes"] else (255, 255, 120))
    d.text((10, 34), at, fill=col, font=_font(22))
    lt = "  ".join(f"{l['x_ref']:+.1f}{dict(solid='С', dashed='П', edge='К')[l['kind']]}"
                   f"{'↓' if l['moving'] else ''}" for l in sorted(res["lines"], key=lambda l: l["x_ref"])
                   if l["kind"])
    d.text((10, 70 + 535), "линии (↓ — штрихи бегут): " + lt, fill=(220, 220, 220), font=_font(18))
    rej = "  ".join(f"{l['x_ref']:+.1f}:{l['why']}" for l in sorted(res["lines"], key=lambda l: l["x_ref"])
                    if not l["kind"] and abs(l["x_ref"]) < 9)
    d.text((10, 70 + 560), "отброшены: " + rej[:230], fill=(160, 160, 160), font=_font(15))
    return out
