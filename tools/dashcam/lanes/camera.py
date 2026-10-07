"""Модель камеры BYD и обратная перспектива (IPM, «вид сверху»).

Кадр детекторов (tools/dashcam/frames.py) — строки [70, 864) исходного
1920×1080, уменьшенные в 2/3 → 1280×529. Модель работает в координатах
исходного кадра и переводит в координаты JPEG только на выходе.

Модель: камера на высоте h над асфальтом, наклон θ (плюс — вниз), рыскание
ψ (плюс — ось камеры смотрит правее оси машины), пинхол с фокусом f и одной
радиальной дисторсией r_u = r_d·(1 + k·(r_d/1000)²) — бочка у k > 0.

Рабочие параметры — в ~/RadarMapBuild/dashcam/lanes/calib.json (calibrate.py
+ speedcal.py): горизонт 615 px исходного кадра, рыскание −27,5 px, k = 0,3,
f ≈ 1124 px по линейке скорости (первая догадка 700 px по «паспортным» 120°
давала дальности в 0,64 от истинных). Значения по умолчанию ниже — только
стартовые.

Боковой масштаб на земле почти не зависит от f: X ≈ h·(u − cx)/(v − v_гор),
поэтому ширина полосы — честная проверка калибровки высоты и горизонта,
а f влияет только на дальность (длину штрихов).
"""
from dataclasses import dataclass
import math

import numpy as np

SRC_W, SRC_H = 1920, 1080
CROP_TOP = 70
SCALE = 1280 / 1920
JPG_W, JPG_H = 1280, 529


@dataclass(frozen=True)
class Camera:
    f: float = 700.0          # фокус, px исходного кадра
    k: float = 0.30           # радиальная дисторсия, r в тысячах px
    pitch_deg: float = -6.0   # наклон вниз (минус — камера смотрит вверх)
    yaw_deg: float = 0.0      # рыскание
    h: float = 1.30           # высота над асфальтом, м
    cx: float = 960.0
    cy: float = 540.0

    def ground_to_src(self, X, Z):
        """Точки земли (X вправо, Z вперёд, м) → пиксели исходного кадра
        (u, v) с дисторсией; за камерой → nan."""
        X = np.asarray(X, float)
        Z = np.asarray(Z, float)
        th = math.radians(self.pitch_deg)
        ps = math.radians(self.yaw_deg)
        # Рыскание: поворот вокруг вертикали.
        Xc = X * math.cos(ps) - Z * math.sin(ps)
        Zc = X * math.sin(ps) + Z * math.cos(ps)
        Y = np.full_like(Xc, self.h)
        xc = Xc
        yc = Y * math.cos(th) - Zc * math.sin(th)
        zc = Y * math.sin(th) + Zc * math.cos(th)
        with np.errstate(divide="ignore", invalid="ignore"):
            xu = self.f * xc / zc
            yu = self.f * yc / zc
        bad = zc <= 0.1
        xd, yd = self.distort(xu, yu)
        u = self.cx + xd
        v = self.cy + yd
        u = np.where(bad, np.nan, u)
        v = np.where(bad, np.nan, v)
        return u, v

    def distort(self, xu, yu):
        """Неискажённые смещения от центра → искажённые (обращение
        r_u = r_d(1 + k r_d²) методом Ньютона, r в тысячах px)."""
        ru = np.hypot(xu, yu) / 1000.0
        rd = ru.copy()
        for _ in range(12):
            g = rd * (1 + self.k * rd * rd) - ru
            dg = 1 + 3 * self.k * rd * rd
            rd = rd - g / dg
            rd = np.clip(rd, 0, None)
        with np.errstate(divide="ignore", invalid="ignore"):
            s = np.where(ru > 1e-9, rd / ru, 1.0)
        return xu * s, yu * s

    def undistort(self, xd, yd):
        rd = np.hypot(xd, yd) / 1000.0
        s = 1 + self.k * rd * rd
        return xd * s, yd * s

    def src_to_ground(self, u, v):
        """Пиксель исходного кадра → (X, Z) на земле; выше горизонта → nan."""
        xu, yu = self.undistort(np.asarray(u, float) - self.cx,
                                np.asarray(v, float) - self.cy)
        th = math.radians(self.pitch_deg)
        ps = math.radians(self.yaw_deg)
        # Луч в камере (xu/f, yu/f, 1) → в мире без рыскания.
        rx = xu / self.f
        ry = yu / self.f
        Yw = ry * math.cos(th) + math.sin(th)
        Zw = -ry * math.sin(th) + math.cos(th)
        with np.errstate(divide="ignore", invalid="ignore"):
            t = np.where(Yw > 1e-6, self.h / Yw, np.nan)
        Xc = rx * t
        Zc = Zw * t
        X = Xc * math.cos(ps) + Zc * math.sin(ps)
        Z = -Xc * math.sin(ps) + Zc * math.cos(ps)
        return X, Z

    def horizon_v(self):
        """Строка горизонта по центру кадра (исходные px)."""
        return self.cy - self.f * math.tan(math.radians(self.pitch_deg))

    def hfov_deg(self):
        ru = 960 * (1 + self.k * 0.96 ** 2)
        return 2 * math.degrees(math.atan(ru / self.f))


def src_to_jpg(u, v):
    return u * SCALE, (v - CROP_TOP) * SCALE


def jpg_to_src(x, y):
    return x / SCALE, y / SCALE + CROP_TOP


# Окно вида сверху: ±12 м в стороны, 6–40 м вперёд, 5 см/пиксель.
X_MIN, X_MAX = -12.0, 12.0
Z_MIN, Z_MAX = 6.0, 40.0
RES = 0.05
BEV_W = int(round((X_MAX - X_MIN) / RES))   # 480
BEV_H = int(round((Z_MAX - Z_MIN) / RES))   # 680


def bev_axes():
    """Центры пикселей вида сверху: xs (м, слева направо), zs (м, сверху
    вниз — дальнее вверху, как на картинке)."""
    xs = X_MIN + (np.arange(BEV_W) + 0.5) * RES
    zs = Z_MAX - (np.arange(BEV_H) + 0.5) * RES
    return xs, zs


def bev_map(cam: Camera):
    """Для каждого пикселя вида сверху — координаты (row, col) в JPEG;
    невидимое → nan."""
    xs, zs = bev_axes()
    X, Z = np.meshgrid(xs, zs)
    u, v = cam.ground_to_src(X, Z)
    x, y = src_to_jpg(u, v)
    inside = (x >= 0) & (x <= JPG_W - 1) & (y >= 0) & (y <= JPG_H - 1)
    x = np.where(inside, x, np.nan)
    y = np.where(inside, y, np.nan)
    return y, x


def warp(img, rows, cols):
    """Билинейная выборка img (H×W или H×W×C, float) по карте bev_map."""
    from scipy.ndimage import map_coordinates
    valid = ~np.isnan(rows)
    r = np.where(valid, rows, 0)
    c = np.where(valid, cols, 0)
    if img.ndim == 2:
        out = map_coordinates(img, [r, c], order=1)
        out[~valid] = np.nan
        return out
    chans = [map_coordinates(img[..., i], [r, c], order=1) for i in range(img.shape[2])]
    out = np.stack(chans, -1)
    out[~valid] = np.nan
    return out
