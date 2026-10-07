"""Панель для проверки глазами: кадр с найденными линиями + вид сверху."""
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from camera import BEV_H, BEV_W, RES, X_MIN, Z_MAX, bev_map, src_to_jpg, warp
from lanes import Z_LINES, Z_NEAR, Z_REF

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
COL = {"solid": (255, 60, 60), "dashed": (60, 220, 255), "edge": (255, 170, 0)}

_maps = {}


def _font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def render(rgb, cam, res, title):
    key = id(cam)
    if key not in _maps:
        _maps[key] = bev_map(cam)
    rows, cols = _maps[key]
    bev = np.nan_to_num(warp(rgb, rows, cols)).clip(0, 255).astype(np.uint8)
    bimg = Image.fromarray(bev)
    bd = ImageDraw.Draw(bimg)
    fimg = Image.fromarray(rgb.clip(0, 255).astype(np.uint8))
    fd = ImageDraw.Draw(fimg)
    s = res["slope"]

    def bev_px(x, z):
        return (x - X_MIN) / RES, (Z_MAX - z) / RES

    # Сетка: метры по X через 2 м, Z через 5 м.
    for x in range(-12, 13, 2):
        bd.line([bev_px(x, 6), bev_px(x, 40)], fill=(70, 70, 70) if x else (255, 255, 0), width=1)
    for z in range(10, 41, 5):
        bd.line([bev_px(-12, z), bev_px(12, z)], fill=(70, 70, 70), width=1)
    for c, kind, fill, yellow in res["lines"]:
        a = bev_px(c + s * (Z_NEAR - Z_REF), Z_NEAR)
        b = bev_px(c + s * (Z_LINES - Z_REF), Z_LINES)
        bd.line([a, b], fill=COL[kind], width=5)
        zs = np.linspace(Z_NEAR, Z_LINES, 30)
        u, v = cam.ground_to_src(c + s * (zs - Z_REF), zs)
        x, y = src_to_jpg(u, v)
        pts = [(float(px), float(py)) for px, py in zip(x, y) if np.isfinite(px)]
        if len(pts) > 1:
            fd.line(pts, fill=COL[kind], width=3)
    # Точки разметки (тонко, зелёным).
    X, Z = res["points"]
    sel = (Z >= 6) & (Z < 40) & (np.abs(X) < 12)
    for x, z in zip(X[sel][::3], Z[sel][::3]):
        px, py = bev_px(x, z)
        bd.point((px, py), fill=(0, 255, 0))
    # Края проезжей части (бордюр) — пурпурным, и в кадре тоже.
    for e in res.get("extent", (None, None)):
        if e is None:
            continue
        bd.line([bev_px(e + s * (6 - Z_REF), 6), bev_px(e + s * (16 - Z_REF), 16)],
                fill=(255, 0, 255), width=6)
        zs = np.linspace(5, 16, 20)
        u, v = cam.ground_to_src(e + s * (zs - Z_REF), zs)
        x, y = src_to_jpg(u, v)
        pts = [(float(px), float(py)) for px, py in zip(x, y) if np.isfinite(px)]
        if len(pts) > 1:
            fd.line(pts, fill=(255, 0, 255), width=5)
    # Машина.
    bd.rectangle([bev_px(-0.9, 6.6), bev_px(0.9, 6.0)], fill=(255, 255, 255))

    W = 1280 + 20 + BEV_W // 1
    H = max(529, BEV_H) + 60
    out = Image.new("RGB", (1280 + 20 + BEV_W, BEV_H + 60), (20, 20, 20))
    out.paste(fimg, (0, 60))
    out.paste(bimg, (1300, 60))
    d = ImageDraw.Draw(out)
    lay = res["layout"]
    if lay:
        txt = (f"{lay['lanes']} полос(ы): слева {lay['left']}, справа {lay['right']}, "
               f"своя {lay['own_width']:.2f} м" + (f", без разметки {lay['unmarked']}" if lay.get('unmarked') else ""))
    else:
        txt = "полосы не определены"
    d.text((10, 6), title, fill=(200, 200, 200), font=_font(18))
    side = res.get("side") or {}
    w = side.get("width")
    txt2 = (f"ширина {w:.1f} м" if w else "ширина ?") + \
        f" · разделительная: {side.get('median') or '?'}" + \
        f" · тротуар справа: {'да' if side.get('sidewalk') else ('нет' if side.get('sidewalk') is False else '?')}" + \
        f" · за краями: {side.get('left_strip') or '?'} / {side.get('right_strip') or '?'}"
    d.text((10, 30), txt + f"   закрыто {res['occluded']:.0%}", fill=(255, 255, 120), font=_font(22))
    d.text((10, 60 + 560), txt2, fill=(255, 140, 255), font=_font(20))
    lines_txt = "  ".join(f"{c:+.1f}{dict(solid='С', dashed='П', edge='К')[k]}{'ж' if y else ''}"
                          for c, k, _, y in res["lines"])
    dl = [f"{c:+.1f}: штрих {'/'.join(f'{x:.1f}' for x in st)}"
          + (f" разрыв {'/'.join(f'{x:.1f}' for x in gp)}" if gp else "")
          for c, st, gp in res.get("dashes", [])]
    if dl:
        d.text((10, 60 + 590), "длины, м — " + ";  ".join(dl), fill=(160, 220, 255), font=_font(18))
    ext = res.get("extent", (None, None))
    lines_txt += "   края проезжей: " + " / ".join("—" if e is None else f"{e:+.1f}" for e in ext)
    d.text((10, 60 + 535), "линии: " + lines_txt, fill=(220, 220, 220), font=_font(18))
    return out
