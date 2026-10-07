"""Маска разметки в координатах кадра JPEG (1280×529).

Разметка — узкая полоса светлее асфальта рядом. Ищем её «цилиндром»
(top-hat): яркость минус морфологическое открытие по горизонтали, ширина
окна растёт к низу кадра вместе с шириной линии. Жёлтая разметка — тот же
top-hat по каналу «жёлтость» (R+G)/2 − B. Порог — относительно шума
асфальта в той же строке, а не абсолютный: утром и в тени асфальт разный.
"""
import numpy as np
from scipy import ndimage

# Полосы строк JPEG и ширина окна открытия (px) — линия 10–20 см
# на 6–40 м занимает от ~14 до ~2 px.
ROW_BANDS = ((350, 385, 7), (385, 410, 11), (410, 445, 17), (445, 529, 27))


def load_rgb(path):
    from PIL import Image
    return np.asarray(Image.open(path).convert("RGB"), np.float32)


def tophat_rows(ch):
    out = np.zeros_like(ch)
    for y0, y1, w in ROW_BANDS:
        band = ch[y0:y1]
        opened = ndimage.grey_opening(band, size=(1, w))
        out[y0:y1] = band - opened
    return out


def marking_masks(rgb):
    """→ (white, yellow, gray): булевы маски белой и жёлтой разметки
    и яркость. Выше строки 350 — всегда False (там дорога уже не видна)."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    gray = 0.299 * r + 0.587 * g + 0.114 * b
    yel = (r + g) / 2 - b
    th = tophat_rows(gray)
    thy = tophat_rows(np.clip(yel, 0, None))
    white = np.zeros(gray.shape, bool)
    yellow = np.zeros(gray.shape, bool)
    for y0, y1, _ in ROW_BANDS:
        t = th[y0:y1]
        # Шум асфальта: медиана + MAD top-hat по строке полосы.
        med = np.median(t)
        mad = np.median(np.abs(t - med)) + 1e-3
        thr = max(14.0, med + 7 * mad)
        white[y0:y1] = t > thr
        ty = thy[y0:y1]
        medy = np.median(ty)
        mady = np.median(np.abs(ty - medy)) + 1e-3
        yellow[y0:y1] = (ty > max(10.0, medy + 7 * mady)) & (yel[y0:y1] > 18) & (t > 6)
    white &= ~yellow
    # Одиночные пиксели — шум JPEG.
    white = ndimage.binary_opening(white, structure=np.ones((2, 1), bool))
    return white, yellow, gray
