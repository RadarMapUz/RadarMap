#!/usr/bin/env python3
"""Проверка профиля car_radarmap.lua (29.E) на крошечных синтетических картах.

    python3 server/osrm/test_car_radarmap.py

Нужен Docker (образ OSRM той же версии, что на VPS); без него проверки
движка пропускаются, остаются статические. Каждая карта — пять-десять узлов:
собирается за секунды, и видно ровно одно правило:

  * махалля: прямой living_street с maxspeed=60 против объезда по
    проспекту — стоковый профиль режет махаллей, наш едет проспектом;
  * светофор: та же дорога со светофором дороже стоковой на
    traffic_signal_seconds − 2 с;
  * левый поворот через главную без светофора дороже, со светофором —
    как обычный;
  * UZ:urban — 70 км/ч, а не 50.

Ничего не трогает на сервере: только локальный docker run --rm.
"""
import json
import math
import os
import re
import shutil
import socket
import subprocess
import tempfile
import unittest
import urllib.request
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILE = os.path.join(HERE, "car_radarmap.lua")
IMAGE = os.environ.get(
    "RADARMAP_OSRM_IMAGE",
    "ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad")
LAT0, LON0 = 41.30, 69.25
M_LAT = 1 / 111320.0
M_LON = 1 / (111320.0 * math.cos(math.radians(LAT0)))


def docker_ok():
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True,
                              timeout=20).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def osm_xml(nodes, ways):
    """nodes: {id: (x_m, y_m, tags)}; ways: [(id, [node ids], tags)]."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<osm version="0.6" generator="test">']
    for nid, (x, y, tags) in nodes.items():
        lat, lon = LAT0 + y * M_LAT, LON0 + x * M_LON
        body = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
        out.append(f'<node id="{nid}" version="1" lat="{lat:.7f}" lon="{lon:.7f}">{body}</node>')
    for wid, refs, tags in ways:
        nds = "".join(f'<nd ref="{r}"/>' for r in refs)
        body = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
        out.append(f'<way id="{wid}" version="1">{nds}{body}</way>')
    out.append("</osm>")
    return "\n".join(out)


class Engine:
    """Собрать карту профилем и спросить маршрут (CH, osrm-routed на время теста)."""

    def __init__(self, xml, profile):
        self.dir = tempfile.mkdtemp(prefix="osrm29e_")
        with open(os.path.join(self.dir, "t.osm"), "w") as f:
            f.write(xml)
        mount = []
        if profile == "stock":
            lua = "/opt/car.lua"
        else:
            lua = "/opt/car_radarmap.lua"
            mount = ["-v", f"{PROFILE}:{lua}:ro"]
        base = ["docker", "run", "--rm", "-v", f"{self.dir}:/data", *mount, IMAGE]
        subprocess.run(base + ["osrm-extract", "-p", lua, "/data/t.osm"], check=True,
                       capture_output=True, timeout=120)
        subprocess.run(base + ["osrm-contract", "/data/t.osrm"], check=True,
                       capture_output=True, timeout=120)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.container = subprocess.run(
            ["docker", "run", "-d", "--rm", "-p", f"127.0.0.1:{self.port}:5000", "-v", f"{self.dir}:/data",
             IMAGE, "osrm-routed", "--algorithm", "ch", "/data/t.osrm"],
            check=True, capture_output=True, text=True).stdout.strip()
        for _ in range(50):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/nearest/v1/driving/{LON0},{LAT0}", timeout=1)
                break
            except OSError:
                time.sleep(0.2)

    def route(self, a, b):
        (ax, ay), (bx, by) = a, b
        url = (f"http://127.0.0.1:{self.port}/route/v1/driving/"
               f"{LON0 + ax * M_LON:.7f},{LAT0 + ay * M_LAT:.7f};{LON0 + bx * M_LON:.7f},{LAT0 + by * M_LAT:.7f}"
               "?overview=false&steps=true")
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)["routes"][0]

    def close(self):
        subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
        shutil.rmtree(self.dir, ignore_errors=True)


def names(route):
    return [s["name"] for leg in route["legs"] for s in leg["steps"] if s["name"]]


class StaticTest(unittest.TestCase):
    """Без Docker: профиль — стоковый плюс наш блок, ручки в одном месте."""

    def setUp(self):
        with open(PROFILE) as f:
            self.text = f.read()

    def test_knobs_live_in_one_table(self):
        for knob in ("class_speed_caps", "living_street_rate", "traffic_signal_seconds",
                     "left_turn_major_seconds", "left_turn_min_degrees", "major_priority_max"):
            self.assertIn(knob, self.text)
        self.assertRegex(self.text, r"living_street\s*=\s*15")
        self.assertIn('["uz:urban"] = 70', self.text)

    def test_stock_api_and_turn_restrictions_kept(self):
        self.assertIn("api_version = 4", self.text)
        self.assertRegex(self.text, r"use_turn_restrictions\s*=\s*true")
        self.assertRegex(self.text, r"left_hand_driving\s*=\s*false")
        self.assertRegex(self.text, r"weight_name\s*=\s*'routability'")

    def test_class_cap_runs_after_maxspeed_and_before_penalties(self):
        order = [m.group(1) for m in re.finditer(r"^\s*(WayHandlers\.\w+|RadarMap\w+),", self.text, re.M)]
        self.assertLess(order.index("WayHandlers.maxspeed"), order.index("RadarMapClassCaps"))
        self.assertLess(order.index("RadarMapClassCaps"), order.index("WayHandlers.penalties"))
        self.assertLess(order.index("WayHandlers.penalties"), order.index("RadarMapLivingStreetRate"))


@unittest.skipUnless(docker_ok(), "нет Docker или образа OSRM — проверки движка пропущены")
class EngineTest(unittest.TestCase):

    def both(self, xml, a, b):
        out = {}
        for profile in ("stock", "radarmap"):
            engine = Engine(xml, profile)
            try:
                out[profile] = engine.route(a, b)
            finally:
                engine.close()
        return out["stock"], out["radarmap"]

    def test_mahalla_with_maxspeed_60_is_not_a_through_route(self):
        # W —primary— A —living_street maxspeed=60 (1000 м)— B —primary— E,
        # объезд A → N1 → N2 → B по проспекту (1800 м).
        nodes = {1: (-200, 0, {}), 2: (0, 0, {}), 3: (1000, 0, {}), 4: (1200, 0, {}),
                 5: (0, 400, {}), 6: (1000, 400, {})}
        ways = [(10, [1, 2], {"highway": "primary", "maxspeed": "60", "name": "West"}),
                (11, [2, 3], {"highway": "living_street", "maxspeed": "60", "name": "Mahalla"}),
                (12, [3, 4], {"highway": "primary", "maxspeed": "60", "name": "East"}),
                (13, [2, 5, 6, 3], {"highway": "primary", "maxspeed": "60", "name": "Avenue"})]
        stock, ours = self.both(osm_xml(nodes, ways), (-150, 0), (1150, 0))
        self.assertIn("Mahalla", names(stock), "стоковый профиль режет махаллей — дефект аудита")
        self.assertNotIn("Mahalla", names(ours))
        self.assertIn("Avenue", names(ours))

    def test_traffic_signal_costs_its_wait(self):
        nodes = {1: (0, 0, {}), 2: (500, 0, {"highway": "traffic_signals"}), 3: (1000, 0, {})}
        ways = [(10, [1, 2, 3], {"highway": "primary", "maxspeed": "60", "name": "Road"})]
        stock, ours = self.both(osm_xml(nodes, ways), (50, 0), (950, 0))
        self.assertAlmostEqual(ours["duration"] - stock["duration"], 8 - 2, delta=0.6)

    def test_left_across_a_major_road_waits_for_a_gap_unless_signalled(self):
        # Второстепенная с юга на перекрёсток проспекта (запад—восток), налево
        # (на запад). Без светофора — дольше на left_turn_major_seconds.
        def plan(signal):
            tags = {"highway": "traffic_signals"} if signal else {}
            nodes = {1: (-800, 0, {}), 2: (0, 0, tags), 3: (800, 0, {}), 4: (0, -600, {})}
            ways = [(10, [1, 2, 3], {"highway": "primary", "maxspeed": "60", "name": "Prospekt"}),
                    (11, [4, 2], {"highway": "residential", "name": "Side"})]
            return osm_xml(nodes, ways)
        engine = Engine(plan(False), "radarmap")
        try:
            plain = engine.route((0, -550), (-750, 0))
            right = engine.route((0, -550), (750, 0))
        finally:
            engine.close()
        engine = Engine(plan(True), "radarmap")
        try:
            lit = engine.route((0, -550), (-750, 0))
        finally:
            engine.close()
        # Налево и направо — зеркальны по длине; разница — штраф налево
        # (сигмоида угла даёт ещё пару секунд в пользу правого).
        self.assertGreater(plain["duration"] - right["duration"], 14)
        self.assertLess(lit["duration"], plain["duration"], "со светофором — ждём сигнал, не разрыв")

    def test_uz_urban_is_70(self):
        nodes = {1: (0, 0, {}), 2: (2000, 0, {})}
        ways = [(10, [1, 2], {"highway": "primary", "maxspeed": "UZ:urban", "name": "Road"})]
        stock, ours = self.both(osm_xml(nodes, ways), (0, 0), (2000, 0))
        self.assertAlmostEqual(2000 / ours["duration"] * 3.6, 70 * 0.8, delta=1.5)
        self.assertAlmostEqual(2000 / stock["duration"] * 3.6, 50 * 0.8, delta=1.5)


if __name__ == "__main__":
    unittest.main()
