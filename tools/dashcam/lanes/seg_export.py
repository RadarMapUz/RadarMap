"""Веса PyTorch → Core ML (.mlpackage) + сверка с PyTorch.

    ~/RadarMapBuild/dashcam/lanes/venv-coreml/bin/python seg_export.py <seg_<tag>.pt> [кадр.jpg ...]

Отдельный скрипт и отдельное окружение: у coremltools 9.0 нет собранных
библиотек под Python 3.14 (основной venv) — ставится только исходник, и
запись mlprogram падает «BlobWriter not loaded». venv-coreml — Python 3.9
из Command Line Tools + torch 2.5.1 + coremltools 8.3 (готовые колёса,
без brew). seg_train.py зовёт этот скрипт сам, если окружение есть.

Вход модели — картинка RGB 1280×192 (строки 337–528 кадра JPEG 1280×529)
в 0…255, нормировка внутри; выход «logits» — 1×8×192×1280, класс —
argmax по оси 1 (порядок классов — в metadata «classes»).
"""
import json
import os
import sys

import numpy as np

from seg_common import CLASSES
from seg_model import CROP_H, MEAN, STD, Y0, build


def export(pt_path, out_path):
    import coremltools as ct
    import torch
    ck = torch.load(pt_path, map_location="cpu", weights_only=False)
    net = build(ck.get("base", 16))
    net.load_state_dict(ck["state"])
    net.eval()

    class Wrapped(torch.nn.Module):
        """Нормировка внутри: Core ML получает картинку 0…255 как есть."""

        def __init__(self, n):
            super().__init__()
            self.n = n

        def forward(self, x):
            return self.n((x / 255.0 - float(MEAN[0])) / float(STD[0]))

    ex = torch.rand(1, 3, CROP_H, 1280) * 255
    traced = torch.jit.trace(Wrapped(net).eval(), ex)
    ml = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=ex.shape,
                                                 color_layout=ct.colorlayout.RGB)],
                    outputs=[ct.TensorType(name="logits")],
                    minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram")
    ml.short_description = ("RadarMap: разметка, бордюр, проезжая, машины; "
                            f"строки {Y0}–{Y0 + CROP_H - 1} кадра 1280×529")
    ml.user_defined_metadata["classes"] = ",".join(CLASSES)
    ml.user_defined_metadata["y0"] = str(Y0)
    ml.save(out_path)
    return ml, net


def check(ml, net, jpgs):
    """Доля пикселей, где класс Core ML совпал с PyTorch, по каждому кадру."""
    import torch
    from PIL import Image
    out = []
    for p in jpgs:
        im = np.asarray(Image.open(p).convert("RGB"))[Y0:Y0 + CROP_H]
        cm = ml.predict({"image": Image.fromarray(im)})["logits"][0].argmax(0)
        x = (im.astype(np.float32) / 255.0 - MEAN) / STD
        with torch.no_grad():
            ref = net(torch.from_numpy(x.transpose(2, 0, 1).copy())[None])[0].argmax(0).numpy()
        out.append(round(float((cm == ref).mean()), 4))
    return out


def main():
    pt = sys.argv[1]
    out = os.path.splitext(pt)[0] + ".mlpackage"
    ml, net = export(pt, out)
    agree = check(ml, net, sys.argv[2:]) if len(sys.argv) > 2 else []
    print(json.dumps({"mlpackage": out, "agree": agree}, ensure_ascii=False))


if __name__ == "__main__":
    main()
