"""Маленькая U-Net для сегментации разметки, бордюров, проезжей и машин.

Вход — КАДР, а не вид сверху (полоса строк Y0…Y0+CROP_H кадра JPEG, вся
ширина 1280). Почему кадр:
- вид сверху зависит от калибровки (наклон «гуляет» на кочках, у другого
  крепления/машины он другой), а ошибка калибровки на входе — это ошибка
  в каждом пикселе обучения; в кадре калибровка нужна только ПОСЛЕ модели,
  при переводе маски в метры (как и сейчас в v2);
- на виде сверху дальняя зона — растянутые 0,3-метровые пиксели, машины —
  «лучи» вдаль: модель училась бы на артефактах перспективы;
- телефон в будущем — другая камера: модель в кадре переносится, а
  калибровку под новый объектив считаем отдельно;
- маска модели напрямую заменяет пороговую (marking.marking_masks) —
  весь v2 (треки, «штрихи бегут», края) остаётся как есть.
Полоса строк 337…528 — от чуть выше горизонта (≈363) до низа кадра:
выше дороги нет, а по высоте 192 = 16·12 (четыре понижения U-Net).
"""
import os

import numpy as np

from seg_common import CLASSES, CLS, MODELS

Y0, CROP_H = 337, 192
N_CLASSES = len(CLASSES)
LINE_IDS = (CLS["solid"], CLS["dashed"], CLS["double"])
MEAN = np.array([0.45, 0.45, 0.45], np.float32)
STD = np.array([0.25, 0.25, 0.25], np.float32)


def build(base=16):
    import torch
    from torch import nn

    def block(ci, co):
        return nn.Sequential(
            nn.Conv2d(ci, co, 3, padding=1, bias=False), nn.BatchNorm2d(co), nn.ReLU(inplace=True),
            nn.Conv2d(co, co, 3, padding=1, bias=False), nn.BatchNorm2d(co), nn.ReLU(inplace=True))

    class UNet(nn.Module):
        def __init__(self):
            super().__init__()
            c = [base, base * 2, base * 4, base * 8, base * 8]
            self.e0 = block(3, c[0])
            self.e1 = block(c[0], c[1])
            self.e2 = block(c[1], c[2])
            self.e3 = block(c[2], c[3])
            self.mid = block(c[3], c[4])
            self.pool = nn.MaxPool2d(2)
            self.u3 = nn.ConvTranspose2d(c[4], c[3], 2, stride=2)
            self.d3 = block(c[3] * 2, c[3])
            self.u2 = nn.ConvTranspose2d(c[3], c[2], 2, stride=2)
            self.d2 = block(c[2] * 2, c[2])
            self.u1 = nn.ConvTranspose2d(c[2], c[1], 2, stride=2)
            self.d1 = block(c[1] * 2, c[1])
            self.u0 = nn.ConvTranspose2d(c[1], c[0], 2, stride=2)
            self.d0 = block(c[0] * 2, c[0])
            self.head = nn.Conv2d(c[0], N_CLASSES, 1)

        def forward(self, x):
            x0 = self.e0(x)
            x1 = self.e1(self.pool(x0))
            x2 = self.e2(self.pool(x1))
            x3 = self.e3(self.pool(x2))
            m = self.mid(self.pool(x3))
            y = self.d3(torch.cat([self.u3(m), x3], 1))
            y = self.d2(torch.cat([self.u2(y), x2], 1))
            y = self.d1(torch.cat([self.u1(y), x1], 1))
            y = self.d0(torch.cat([self.u0(y), x0], 1))
            return self.head(y)

    return UNet()


def to_input(rgb):
    """RGB float/uint8 кадра 529×1280 → нормированный CHW полосы строк."""
    crop = np.asarray(rgb, np.float32)[Y0:Y0 + CROP_H] / 255.0
    return ((crop - MEAN) / STD).transpose(2, 0, 1).copy()


class Predictor:
    """Модель → карта классов кадра (529×1280; выше полосы — фон)."""

    def __init__(self, path=None, device="cpu", threads=None):
        import torch
        if threads:
            torch.set_num_threads(threads)
        path = path or os.path.join(MODELS, "seg_latest.pt")
        ck = torch.load(path, map_location="cpu", weights_only=False)
        self.net = build(ck.get("base", 16))
        self.net.load_state_dict(ck["state"])
        self.net.eval().to(device)
        self.device = device
        self.torch = torch

    def classes(self, rgb):
        x = self.torch.from_numpy(to_input(rgb))[None].to(self.device)
        with self.torch.no_grad():
            p = self.net(x).argmax(1)[0].cpu().numpy().astype(np.uint8)
        out = np.zeros((rgb.shape[0], rgb.shape[1]), np.uint8)
        out[Y0:Y0 + CROP_H] = p
        return out


_pred = None


def predictor():
    """Один предиктор на процесс (воркеры evaluate.py — по потоку на каждого)."""
    global _pred
    if _pred is None:
        _pred = Predictor(os.environ.get("LANES_SEG_MODEL"), threads=1)
    return _pred
