#!/usr/bin/env python3
"""Страница разметки полос: http://127.0.0.1:8781 (только этот адрес).

    ~/RadarMapBuild/dashcam/lanes/venv/bin/python label_ui/server.py [--port 8781]

Кадры — из отбора seg_select.py (labels/selection.json), предзаполнение —
seg_prefill.py, разметка пишется в labels/<ключ>.json (seg_common.save_label).
Кадр отдаётся только по номеру в отборе — путь из URL не берётся никогда.
Заголовок Host проверяется (защита от DNS rebinding), POST — только JSON
и только со своего origin: в кадрах номера машин, в сеть они не уходят.

Перенос с соседнего кадра: если в том же окне уже размечен кадр, его
ломаные переносятся на этот по общему сдвигу и наклонке кадров (из
треков v2, seg_common.transfer_lines) и показываются пунктиром —
подсказка; принять — клавиша T.
"""
import argparse
import json
import os
import statistics
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from seg_common import (LABELS, PREFILL, SELECTION, WIN, image_path,  # noqa: E402
                        load_label, save_label, transfer_lines)

HOST = "127.0.0.1"
DEFAULT_PORT = 8781
STATIC = {"index.html": "text/html; charset=utf-8", "app.js": "text/javascript; charset=utf-8"}
TRANSFER_MAX_S = 1.6     # переносим только с кадра не дальше этого по времени


class Store:
    def __init__(self, selection=SELECTION, labels=LABELS, prefill=PREFILL, cam=None):
        with open(selection) as f:
            self.items = json.load(f)
        self.by_key = {it["key"]: i for i, it in enumerate(self.items)}
        self.labels, self.prefill_dir = labels, prefill
        self._prefill, self._pts = {}, {}
        self._cam = cam

    @property
    def cam(self):
        if self._cam is None:
            from lanes import load_camera
            self._cam = load_camera()
        return self._cam

    def prefill(self, it):
        key = f"w{it['win']}" if it["src"] == "window" else f"d{it['frame_id']}"
        if key not in self._prefill:
            p = os.path.join(self.prefill_dir, key + ".json")
            self._prefill[key] = json.load(open(p)) if os.path.exists(p) else {}
        pf = self._prefill[key]
        if it["src"] == "window":
            return (pf.get("frames") or {}).get(it["name"])
        return pf if "lines" in pf else None

    def pts(self, win, name):
        if win not in self._pts:
            d = os.path.join(WIN, str(win))
            with open(os.path.join(d, "pts.json")) as f:
                meta = json.load(f)
            names = sorted(n for n in os.listdir(d) if n.startswith("f_"))
            self._pts[win] = dict(zip(names, meta["pts"]))
        return self._pts[win].get(name)

    def transfer(self, it):
        """Подсказка с ближайшего по времени размеченного кадра того же окна."""
        if it["src"] != "window":
            return None
        me = self.prefill(it)
        t_me = self.pts(it["win"], it["name"])
        if me is None or t_me is None:
            return None
        best = None
        for o in self.items:
            if o["src"] != "window" or o["win"] != it["win"] or o["key"] == it["key"]:
                continue
            lab = load_label(o["key"], self.labels)
            if lab is None or lab.get("skip"):
                continue
            dt = abs(self.pts(o["win"], o["name"]) - t_me)
            if dt <= TRANSFER_MAX_S and (best is None or dt < best[0]):
                best = (dt, o, lab)
        if best is None:
            return None
        dt, o, lab = best
        src = self.prefill(o)
        if src is None:
            return None
        lines = transfer_lines(self.cam, lab["lines"], me["cum"] - src["cum"], src["s"], me["s"])
        return {"from": o["key"], "dt": round(dt, 2), "lines": lines}

    def item(self, i):
        it = self.items[i]
        pf = self.prefill(it)
        lab = load_label(it["key"], self.labels)
        return {"i": i, "n": len(self.items), "item": it,
                "prefill": pf["lines"] if pf else [],
                "label": lab, "transfer": self.transfer(it)}

    def save(self, body):
        key = body.get("key")
        if key not in self.by_key:
            raise ValueError("кадра нет в отборе")
        it = self.items[self.by_key[key]]
        lab = dict(body)
        # Откуда кадр — только из отбора, не со страницы.
        for k in ("src", "trip", "win", "name", "frame_id"):
            lab[k] = it[k]
        save_label(lab, self.labels)
        return self.stats()

    def stats(self):
        done = skipped = 0
        secs = []
        status = []
        for it in self.items:
            lab = load_label(it["key"], self.labels)
            if lab is None:
                status.append(0)
                continue
            if lab.get("skip"):
                skipped += 1
                status.append(2)
                continue
            done += 1
            status.append(1)
            if lab.get("seconds"):
                secs.append(lab["seconds"])
        return {"total": len(self.items), "done": done, "skipped": skipped,
                "mean_s": round(statistics.mean(secs), 1) if secs else None,
                "median_s": round(statistics.median(secs), 1) if secs else None,
                "status": status}


def make_handler(store, port):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    origin_ok = {f"http://{h}" for h in allowed_hosts}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json; charset=utf-8"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _host_ok(self):
            if self.headers.get("Host") not in allowed_hosts:
                self._send(403, {"error": "host"})
                return False
            return True

        def do_GET(self):
            if not self._host_ok():
                return
            u = urlparse(self.path)
            q = parse_qs(u.query)
            name = u.path.lstrip("/") or "index.html"
            try:
                if name in STATIC:
                    with open(os.path.join(HERE, name), "rb") as f:
                        return self._send(200, f.read(), STATIC[name])
                if name == "api/item":
                    i = int(q["i"][0])
                    if not 0 <= i < len(store.items):
                        return self._send(404, {"error": "нет кадра"})
                    return self._send(200, store.item(i))
                if name == "api/stats":
                    return self._send(200, store.stats())
                if name == "img":
                    i = int(q["i"][0])
                    if not 0 <= i < len(store.items):
                        return self._send(404, {"error": "нет кадра"})
                    with open(image_path(store.items[i]), "rb") as f:
                        return self._send(200, f.read(), "image/jpeg")
            except (KeyError, ValueError) as e:
                return self._send(400, {"error": repr(e)})
            self._send(404, {"error": "нет такого"})

        def do_POST(self):
            if not self._host_ok():
                return
            origin = self.headers.get("Origin")
            if origin is not None and origin not in origin_ok:
                return self._send(403, {"error": "origin"})
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                return self._send(415, {"error": "только JSON"})
            n = int(self.headers.get("Content-Length") or 0)
            if n > 1 << 20:
                return self._send(413, {"error": "слишком большое"})
            try:
                body = json.loads(self.rfile.read(n))
                if urlparse(self.path).path == "/api/save":
                    return self._send(200, store.save(body))
            except (ValueError, json.JSONDecodeError) as e:
                return self._send(400, {"error": str(e)})
            self._send(404, {"error": "нет такого"})

    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    a = ap.parse_args()
    store = Store()
    srv = ThreadingHTTPServer((HOST, a.port), make_handler(store, a.port))
    s = store.stats()
    print(f"разметка: http://{HOST}:{a.port}  (кадров {s['total']}, размечено {s['done']})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
