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
GHOST = 10.0    # отклик неподвижной структуры, выше которого пиксель — нить отражения
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


def static_gain(resp, med, floor=2.0, max_gain=3.0):
    """Насколько сильно неподвижная структура (медиана поездки) проступает
    в этом кадре: МНК-коэффициент resp ≈ a·med по пикселям, где медиана
    заметна. Отражение сетки то ярче (солнце сбоку), то пропадает (тень),
    поэтому вычитаем a·med, а не саму медиану."""
    m = med > floor
    if m.sum() < 500:
        return 1.0
    a = float((resp[m] * med[m]).sum() / ((med[m] ** 2).sum() + 1e-6))
    return min(max(a, 0.0), max_gain)


def marking_masks(rgb, static=None, return_ghost=False):
    """→ (white, yellow, gray): булевы маски белой и жёлтой разметки
    и яркость. Выше строки 350 — всегда False (там дорога уже не видна).
    static — (медиана top-hat яркости, жёлтости) по поездке (reflect.py):
    неподвижные отражения вычитаются из отклика до порога."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    gray = 0.299 * r + 0.587 * g + 0.114 * b
    yel = (r + g) / 2 - b
    th = tophat_rows(gray)
    thy = tophat_rows(np.clip(yel, 0, None))
    ghost = None
    if static is not None:
        a = static_gain(th, static[0])
        th = th - a * static[0]
        thy = thy - static_gain(thy, static[1]) * static[1]
        # Сами нити сетки (где отражение заметно и в этом кадре) из маски
        # убираем: вычитание медианы оставляет на них остаток, который «стоит»
        # в кадре и тянет за собой профиль настоящей линии. Просветы между
        # нитями остаются — линия через сетку видна по ним.
        ghost = a * static[0] > GHOST
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
    if ghost is not None:
        white &= ~ghost
        yellow &= ~ghost
    # Одиночные пиксели — шум JPEG.
    white = ndimage.binary_opening(white, structure=np.ones((2, 1), bool))
    if return_ghost:
        return white, yellow, gray, ghost
    return white, yellow, gray


# Маска из обученной модели (seg_model.py) — вместо порогов. Модель
# говорит, ГДЕ линия (класс «прерывистая» у неё сплошной полосой через
# разрывы, как в разметке), а сами штрихи краски внутри её полосы
# выделяет мягкий порог top-hat: вдвое ниже порогового режима, ведь
# отражения и бока машин модель уже убрала. Без этого v2 не увидел бы
# разрывов, и «штрихи бегут» молчал бы. Бордюр модели идёт в маску целиком:
# v2 сам признаёт его краем (асфальт с одной стороны).
MODEL_K = 3.5
MODEL_MIN = 7.0


def model_masks(rgb, return_ghost=False):
    """→ (white, yellow, gray[, ghost=None]) — как marking_masks, но по модели."""
    from seg_common import CLS
    from seg_model import LINE_IDS, predictor
    cls = predictor().classes(rgb)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    gray = 0.299 * r + 0.587 * g + 0.114 * b
    yel = (r + g) / 2 - b
    th = tophat_rows(gray)
    line = np.isin(cls, LINE_IDS)
    paint = np.zeros(gray.shape, bool)
    for y0, y1, _ in ROW_BANDS:
        t = th[y0:y1]
        med = np.median(t)
        mad = np.median(np.abs(t - med)) + 1e-3
        paint[y0:y1] = t > max(MODEL_MIN, med + MODEL_K * mad)
    m = (line & paint) | (cls == CLS["curb"])
    m[:ROW_BANDS[0][0]] = False
    yellow = m & (yel > 18)
    white = m & ~yellow
    if return_ghost:
        return white, yellow, gray, None
    return white, yellow, gray
