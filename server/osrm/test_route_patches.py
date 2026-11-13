#!/usr/bin/env python3
"""Слой поправок маршрутов (91) на синтетических картах.

    python3 server/osrm/test_route_patches.py

Без Docker идут проверки слоя (pyosmium: опора, очередь, «OSM догнал»,
разрез путей, перецепка чужих relation, выгрузка для JOSM, карточки
перекрёстков). С Docker — то же на движке: запрет, кирпич и снятый барьер
меняют маршрут OSRM (car_radarmap.lua, образ как на VPS).
"""
import json
import math
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import route_patches as rp  # noqa: E402

try:
    import osmium  # noqa: F401
    HAVE_OSMIUM = True
except ImportError:  # pragma: no cover
    HAVE_OSMIUM = False

IMAGE = os.environ.get(
    "RADARMAP_OSRM_IMAGE",
    "ghcr.io/project-osrm/osrm-backend@sha256:a7091038e39a73659767f34ef2d389909b42ea80b09bd2bdca482dce2991cbad")
PROFILE = os.path.join(HERE, "car_radarmap.lua")
LAT0, LON0 = 41.30, 69.25
M_LAT = 1 / 111320.0
M_LON = 1 / (111320.0 * math.cos(math.radians(LAT0)))
STEP = 200


def ll(x, y):
    return LAT0 + y * M_LAT, LON0 + x * M_LON


def grid_map(barrier_on=None, extra_rel=(), extra_nodes=None, extra_ways=(), node_tags=None):
    """Сетка 3×3 через 200 м; пути — целые ряды и столбцы (перекрёстки внутри
    путей, как в Ташкенте). Узел id = 1 + ряд·3 + столбец, ряд 0 — юг.
    Ряды — пути 100…102, столбцы — 200…202. Между 1 и 2 — узел 12, между 5
    и 8 — узел 13."""
    nodes = {1 + r * 3 + c: (c * STEP, r * STEP, {}) for r in range(3) for c in range(3)}
    nodes[12] = (STEP / 2, 0, {})
    nodes[13] = (STEP, STEP * 1.25, {})
    for nid, tags in (node_tags or {}).items():
        nodes[nid] = (nodes[nid][0], nodes[nid][1], tags)
    if barrier_on:
        x, y, _ = nodes[barrier_on]
        nodes[barrier_on] = (x, y, {"barrier": "yes"})
    nodes.update(extra_nodes or {})
    ways = [(100, [1, 12, 2, 3], {"highway": "secondary", "name": "Юг"}),
            (101, [4, 5, 6], {"highway": "secondary", "name": "Середина"}),
            (102, [7, 8, 9], {"highway": "secondary", "name": "Север"}),
            (200, [1, 4, 7], {"highway": "secondary", "name": "Запад"}),
            (201, [2, 5, 13, 8], {"highway": "secondary", "name": "Центр"}),
            (202, [3, 6, 9], {"highway": "secondary", "name": "Восток"})]
    ways += list(extra_ways)
    return osm_xml(nodes, ways, extra_rel)


def osm_xml(nodes, ways, relations=()):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<osm version="0.6" generator="test">']
    for nid, (x, y, tags) in sorted(nodes.items()):
        lat, lon = ll(x, y)
        body = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
        out.append(f'<node id="{nid}" version="3" lat="{lat:.7f}" lon="{lon:.7f}">{body}</node>')
    for wid, refs, tags in sorted(ways):
        nds = "".join(f'<nd ref="{r}"/>' for r in refs)
        body = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
        out.append(f'<way id="{wid}" version="2">{nds}{body}</way>')
    kinds = {"n": "node", "w": "way"}
    for rid, members, tags in sorted(relations, key=lambda r: r[0]):
        mem = "".join(f'<member type="{kinds[t]}" ref="{ref}" role="{role}"/>' for t, ref, role in members)
        body = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
        out.append(f'<relation id="{rid}" version="4">{mem}{body}</relation>')
    out.append("</osm>")
    return "\n".join(out)


def read_osm(path):
    import osmium
    nodes, ways, rels = {}, {}, {}
    for o in osmium.FileProcessor(path):
        if o.is_node():
            nodes[o.id] = {"tags": dict(o.tags), "version": o.version}
        elif o.is_way():
            ways[o.id] = {"nodes": [n.ref for n in o.nodes], "tags": dict(o.tags), "version": o.version}
        else:
            rels[o.id] = {"members": [(m.type, m.ref, m.role) for m in o.members], "tags": dict(o.tags),
                          "version": o.version}
    return nodes, ways, rels


def way_with(ways, a, b):
    for wid, w in ways.items():
        if any({x, y} == {a, b} for x, y in zip(w["nodes"], w["nodes"][1:])):
            return wid
    return None


class Layer:
    """Карта → слой → (решения, узлы, пути, relation выхода)."""

    def __init__(self, xml, repo=(), panel=()):
        self.dir = tempfile.mkdtemp(prefix="rp91_")
        self.src = os.path.join(self.dir, "in.osm")
        with open(self.src, "w") as f:
            f.write(xml)
        self.repo = os.path.join(self.dir, "repo.json")
        with open(self.repo, "w") as f:
            json.dump({"version": 1, "patches": list(repo)}, f)
        self.out = os.path.join(self.dir, "out.osm.pbf")
        self.report = rp.apply_layer(self.src, self.out, os.path.join(self.dir, "report"), self.repo,
                                     list(panel), date="2026-11-13")
        self.by_id = {d["id"]: d for d in self.report["patches"]}
        self.nodes, self.ways, self.rels = read_osm(self.out)

    def verdict(self, pid):
        return self.by_id[pid]["verdict"]

    def text(self, name):
        with open(os.path.join(self.dir, "report", name)) as f:
            return f.read()

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def at(nid, nodes=None):
    if nid == 12:
        return list(ll(STEP / 2, 0))
    if nid == 13:
        return list(ll(STEP, STEP * 1.25))
    r, c = divmod(nid - 1, 3)
    return list(ll(c * STEP, r * STEP))


BAN = {"id": "ban", "kind": "turn_ban", "restriction": "no_left_turn", "path": [4, 5, 13],
       "expect": {"at": [at(4), at(5), at(13)]}}


@unittest.skipUnless(HAVE_OSMIUM, "нет pyosmium")
class Barrier(unittest.TestCase):
    def test_applied_and_node_freed(self):
        layer = Layer(grid_map(barrier_on=12), repo=[
            {"id": "b", "kind": "unbarrier", "node": 12, "expect": {"at": at(12), "tags": {"barrier": "yes"}}}])
        try:
            self.assertEqual(layer.verdict("b"), rp.APPLIED)
            self.assertNotIn("barrier", layer.nodes[12]["tags"])
            self.assertEqual(layer.nodes[12]["version"], 4)
            self.assertEqual(layer.by_id["b"]["check"], {"through": 12})
            self.assertTrue(layer.by_id["b"]["probes"])
        finally:
            layer.close()

    def test_osm_caught_up_is_not_duplicated(self):
        layer = Layer(grid_map(), repo=[
            {"id": "b", "kind": "unbarrier", "node": 12, "expect": {"at": at(12), "tags": {"barrier": "yes"}}}])
        try:
            self.assertEqual(layer.verdict("b"), rp.CAUGHT_UP)
            self.assertEqual(layer.nodes[12]["version"], 3)
            self.assertNotIn("<node", layer.text("changes.osc"))
        finally:
            layer.close()

    def test_lost_anchor_goes_to_queue_not_silently(self):
        layer = Layer(grid_map(barrier_on=12), repo=[
            {"id": "b", "kind": "unbarrier", "node": 999, "expect": {"at": at(12)}}])
        try:
            self.assertEqual(layer.verdict("b"), rp.CHECK)
            self.assertIn("999", layer.by_id["b"]["reason"])
            self.assertEqual(layer.nodes[12]["tags"], {"barrier": "yes"})
            self.assertIn("Очередь «проверить» (1)", layer.text("report.md"))
        finally:
            layer.close()

    def test_moved_anchor_and_changed_tags_go_to_queue(self):
        far = [at(12)[0] + 30 * M_LAT, at(12)[1]]
        layer = Layer(grid_map(barrier_on=12), repo=[
            {"id": "moved", "kind": "unbarrier", "node": 12, "expect": {"at": far}},
            {"id": "tags", "kind": "unbarrier", "node": 12, "expect": {"at": at(12), "tags": {"barrier": "kerb"}}}])
        try:
            self.assertEqual(layer.verdict("moved"), rp.CHECK)
            self.assertIn("сдвинулся", layer.by_id["moved"]["reason"])
            self.assertEqual(layer.verdict("tags"), rp.CHECK)
            self.assertEqual(layer.nodes[12]["tags"], {"barrier": "yes"})
        finally:
            layer.close()

    def test_panel_barrier_by_place(self):
        point = at(12)
        layer = Layer(grid_map(barrier_on=12), panel=[
            {"id": 7, "kind": "unbarrier", "raw": [point[1] + 3 * M_LON, point[0]], "props": {}}])
        try:
            self.assertEqual(layer.verdict("panel-7"), rp.APPLIED)
            self.assertEqual(layer.by_id["panel-7"]["node"], 12)
            self.assertNotIn("barrier", layer.nodes[12]["tags"])
        finally:
            layer.close()


@unittest.skipUnless(HAVE_OSMIUM, "нет pyosmium")
class TurnBan(unittest.TestCase):
    def test_interior_via_is_split_and_relation_points_at_chunks(self):
        layer = Layer(grid_map(), repo=[BAN])
        try:
            self.assertEqual(layer.verdict("ban"), rp.APPLIED)
            self.assertEqual(layer.by_id["ban"]["maneuver"], "left")
            new = [r for r in layer.rels.values() if r["tags"].get("radarmap:patch") == "ban"]
            self.assertEqual(len(new), 1)
            members = new[0]["members"]
            self.assertEqual(new[0]["tags"]["restriction"], "no_left_turn")
            (_, fw, _), (_, via, _), (_, tw, _) = members
            self.assertEqual(via, 5)
            for wid in (fw, tw):
                self.assertIn(5, (layer.ways[wid]["nodes"][0], layer.ways[wid]["nodes"][-1]))
            self.assertEqual(way_with(layer.ways, 4, 5), fw)
            self.assertEqual(way_with(layer.ways, 5, 13), tw)
            self.assertGreaterEqual(min(fw, tw), 101)
            self.assertGreater(max(w for w in layer.ways), rp.NEW_ID)
            # Разрезанный путь собран из кусков без потери узлов.
            row = [layer.ways[w]["nodes"] for w in layer.ways if layer.ways[w]["tags"]["name"] == "Середина"]
            self.assertEqual(sorted(n for chunk in row for n in chunk), [4, 5, 5, 6])
        finally:
            layer.close()

    def test_foreign_restriction_follows_its_chunk(self):
        # Запрет OSM: с 102 (север) через 9 (конец пути) на 202. Путь 202 режется
        # под наш запрет в 6 — relation обязан уйти на кусок, где 9 — конец.
        rel = (77, [("w", 102, "from"), ("n", 9, "via"), ("w", 202, "to")], {"type": "restriction",
                                                                             "restriction": "no_right_turn"})
        ban = {"id": "ban6", "kind": "turn_ban", "restriction": "no_right_turn", "path": [5, 6, 3],
               "expect": {"at": [at(5), at(6), at(3)]}}
        layer = Layer(grid_map(extra_rel=[rel]), repo=[ban])
        try:
            self.assertEqual(layer.verdict("ban6"), rp.APPLIED)
            members = layer.rels[77]["members"]
            to = [ref for t, ref, role in members if role == "to"][0]
            self.assertIn(9, (layer.ways[to]["nodes"][0], layer.ways[to]["nodes"][-1]))
            self.assertEqual(layer.rels[77]["version"], 5)
        finally:
            layer.close()

    def test_osm_already_bans_it(self):
        rel = (70, [("w", 101, "from"), ("n", 5, "via"), ("w", 201, "to")],
               {"type": "restriction", "restriction": "no_left_turn"})
        layer = Layer(grid_map(extra_rel=[rel]), repo=[BAN])
        try:
            self.assertEqual(layer.verdict("ban"), rp.CAUGHT_UP)
            self.assertIn("70", layer.by_id["ban"]["reason"])
            self.assertFalse([r for r in layer.rels.values() if "radarmap:patch" in r["tags"]])
            # via внутри путей — OSRM такой выбросит: пути режутся, relation перецеплен.
            members = layer.rels[70]["members"]
            for t, ref, role in members:
                if t == "w":
                    self.assertIn(5, (layer.ways[ref]["nodes"][0], layer.ways[ref]["nodes"][-1]))
        finally:
            layer.close()

    def test_only_turn_in_osm_conflicts(self):
        rel = (71, [("w", 101, "from"), ("n", 5, "via"), ("w", 201, "to")],
               {"type": "restriction", "restriction": "only_left_turn"})
        layer = Layer(grid_map(extra_rel=[rel]), repo=[BAN])
        try:
            self.assertEqual(layer.verdict("ban"), rp.CHECK)
            self.assertIn("противоречит", layer.by_id["ban"]["reason"])
        finally:
            layer.close()

    def test_lost_node_and_broken_adjacency(self):
        lost = dict(BAN, id="lost", path=[4, 5, 99], expect={"at": [at(4), at(5), at(9)]})
        far = dict(BAN, id="far", path=[4, 8, 5], expect={"at": [at(4), at(8), at(5)]})
        layer = Layer(grid_map(), repo=[lost, far])
        try:
            self.assertEqual(layer.verdict("lost"), rp.CHECK)
            self.assertEqual(layer.verdict("far"), rp.CHECK)
            self.assertIn("не соседи", layer.by_id["far"]["reason"])
            self.assertEqual(len(layer.ways), 6)
        finally:
            layer.close()

    def test_impossible_turn_is_caught_up(self):
        xml = grid_map().replace('<tag k="name" v="Центр"/>', '<tag k="name" v="Центр"/><tag k="oneway" v="-1"/>')
        layer = Layer(xml, repo=[BAN])
        try:
            self.assertEqual(layer.verdict("ban"), rp.CAUGHT_UP)
        finally:
            layer.close()

    def test_panel_ban_by_place_and_bearings(self):
        c = at(5)
        layer = Layer(grid_map(), panel=[
            {"id": 3, "kind": "turn_ban", "raw": [c[1], c[0]],
             "props": {"restriction": "no_left_turn", "from_bearing": 90, "to_bearing": 0, "evidence": "yandex"}}])
        try:
            self.assertEqual(layer.verdict("panel-3"), rp.APPLIED)
            self.assertEqual(layer.by_id["panel-3"]["path"], [4, 5, 13])
            # Проверено по Яндексу — в граф да, в OSM нет.
            self.assertNotIn('k="restriction"', layer.text("osm_josm.osm"))
            self.assertIn("НЕ в файле", layer.text("osm_checklist.md"))
        finally:
            layer.close()

    def test_panel_ban_ambiguous_goes_to_queue(self):
        # Дублёр в 2 м восточнее центрального столбца: два въезда с юга.
        nodes = {50: (STEP + 3, 0, {}), 51: (STEP + 3, STEP, {}), 52: (STEP + 3, 2 * STEP, {})}
        ways = [(300, [50, 51, 52], {"highway": "secondary", "name": "Дублёр"})]
        xml = grid_map(extra_nodes=nodes, extra_ways=ways)
        xml = xml.replace('<nd ref="4"/><nd ref="5"/><nd ref="6"/>', '<nd ref="4"/><nd ref="5"/><nd ref="51"/><nd ref="6"/>')
        c = at(5)
        layer = Layer(xml, panel=[{"id": 4, "kind": "turn_ban", "raw": [c[1], c[0]],
                                   "props": {"restriction": "no_right_turn", "from_bearing": 0,
                                             "to_bearing": 90}}])
        try:
            self.assertEqual(layer.verdict("panel-4"), rp.CHECK)
            self.assertIn("неоднозначно", layer.by_id["panel-4"]["reason"])
        finally:
            layer.close()

    def test_same_ban_from_repo_and_panel_once(self):
        c = at(5)
        layer = Layer(grid_map(), repo=[BAN], panel=[
            {"id": 5, "kind": "turn_ban", "raw": [c[1], c[0]],
             "props": {"restriction": "no_left_turn", "from_bearing": 90, "to_bearing": 0}}])
        try:
            self.assertEqual(sum(1 for r in layer.rels.values() if "radarmap:patch" in r["tags"]), 1)
            self.assertIn("то же, что", layer.by_id["panel-5"]["reason"])
        finally:
            layer.close()

    def test_josm_file_for_osm(self):
        layer = Layer(grid_map(), repo=[dict(BAN, evidence="survey")])
        try:
            text = layer.text("osm_josm.osm")
            self.assertIn('action="modify"', text)
            self.assertIn('<relation id="-', text)
            self.assertNotIn("radarmap:", text)
            self.assertIn('<way id="101" version="2" action="modify">', text)
            self.assertNotIn(str(rp.NEW_ID)[:6], text)
        finally:
            layer.close()


@unittest.skipUnless(HAVE_OSMIUM, "нет pyosmium")
class OnewayAndEntry(unittest.TestCase):
    def test_no_entry_makes_block_oneway_out(self):
        # Кирпич: въезд с юга (из 3) на восточный столбец на север.
        p = at(3)
        layer = Layer(grid_map(), panel=[{"id": 9, "kind": "no_entry", "raw": [p[1], p[0] + 20 * M_LAT],
                                          "props": {"bearing": 0}}])
        try:
            d = layer.by_id["panel-9"]
            self.assertEqual(d["verdict"], rp.APPLIED)
            self.assertEqual(d["path"], [6, 3])
            wid = way_with(layer.ways, 3, 6)
            w = layer.ways[wid]
            forward = w["nodes"].index(6) < w["nodes"].index(3)
            self.assertEqual(w["tags"]["oneway"], "yes" if forward else "-1")
            self.assertNotIn("oneway", layer.ways[way_with(layer.ways, 6, 9)]["tags"])
            self.assertEqual(d["check"]["forbidden_pairs"], [[3, 6]])
        finally:
            layer.close()

    def test_oneway_by_ids_caught_up_and_conflict(self):
        xml = grid_map().replace('<tag k="name" v="Север"/>', '<tag k="name" v="Север"/><tag k="oneway" v="yes"/>')

        def oneway(pid, path):
            return {"id": pid, "kind": "oneway", "path": path, "expect": {"at": [at(n) for n in path]}}
        same, against = oneway("same", [7, 8, 9]), oneway("against", [9, 8])
        a, b = oneway("a", [4, 5]), oneway("b", [5, 4])
        layer = Layer(xml, repo=[same, against, a, b])
        try:
            self.assertEqual(layer.verdict("same"), rp.CAUGHT_UP)
            self.assertEqual(layer.verdict("against"), rp.CHECK)
            self.assertEqual(layer.verdict("a"), rp.CHECK)
            self.assertEqual(layer.verdict("b"), rp.CHECK)
            self.assertNotIn("oneway", layer.ways[101]["tags"])
        finally:
            layer.close()


@unittest.skipUnless(HAVE_OSMIUM, "нет pyosmium")
class RelationFix(unittest.TestCase):
    BROKEN = (60, [("w", 101, "from"), ("w", 201, "to")], {"type": "restriction", "restriction": "no_left_turn"})

    def fix(self, **extra):
        out = {"id": "fix", "kind": "relation_fix", "relation": 60,
               "members": [["w", 101, "from"], ["n", 5, "via"], ["w", 201, "to"]],
               "expect": {"version": 4}}
        out.update(extra)
        return out

    def test_add_via_and_split_by_turn_side(self):
        # to (211) начинается в via, from (101) проходит via насквозь: no_left_turn
        # однозначно задаёт подход с запада.
        rel = (60, [("w", 101, "from"), ("w", 211, "to")], {"type": "restriction", "restriction": "no_left_turn"})
        xml = grid_map(extra_rel=[rel]).replace('<nd ref="2"/><nd ref="5"/><nd ref="13"/><nd ref="8"/>',
                                                '<nd ref="2"/><nd ref="5"/>')
        xml = xml.replace("</osm>", '<way id="211" version="2"><nd ref="5"/><nd ref="13"/><nd ref="8"/>'
                                    '<tag k="highway" v="secondary"/></way></osm>')
        xml = xml.replace('<relation id="60"', '<!-- r --><relation id="60"')
        # путь 211 должен идти до relation: переставляем relation в конец
        body, rel_xml = xml.split("<!-- r -->")
        rel_xml, tail = rel_xml.split("</relation>")
        xml = body + tail.replace("</osm>", rel_xml + "</relation></osm>")
        fix = self.fix(members=[["w", 101, "from"], ["n", 5, "via"], ["w", 211, "to"]])
        layer = Layer(xml, repo=[fix])
        try:
            self.assertEqual(layer.verdict("fix"), rp.APPLIED)
            rel = layer.rels[60]
            self.assertIn(("n", 5, "via"), rel["members"])
            fw = [ref for t, ref, role in rel["members"] if role == "from"][0]
            self.assertEqual(way_with(layer.ways, 4, 5), fw)
            self.assertIn(("w", 211, "to"), rel["members"])
        finally:
            layer.close()

    def test_both_sides_inside_is_ambiguous(self):
        layer = Layer(grid_map(extra_rel=[self.BROKEN]), repo=[self.fix()])
        try:
            self.assertEqual(layer.verdict("fix"), rp.CHECK)
            self.assertIn("сторону не выбрать", layer.by_id["fix"]["reason"])
            self.assertEqual(layer.rels[60]["version"], 4)
        finally:
            layer.close()

    def test_version_changed_still_broken_is_queued(self):
        layer = Layer(grid_map(extra_rel=[self.BROKEN]), repo=[self.fix(expect={"version": 2})])
        try:
            self.assertEqual(layer.verdict("fix"), rp.CHECK)
            self.assertEqual(layer.rels[60]["version"], 4)
        finally:
            layer.close()

    def test_fixed_in_osm_or_deleted(self):
        good = (60, [("w", 101, "from"), ("n", 5, "via"), ("w", 201, "to")],
                {"type": "restriction", "restriction": "no_left_turn"})
        layer = Layer(grid_map(extra_rel=[good]), repo=[self.fix(expect={"version": 2})])
        try:
            self.assertEqual(layer.verdict("fix"), rp.CHECK)  # via внутри путей: OSRM его выбросит
        finally:
            layer.close()
        layer = Layer(grid_map(), repo=[self.fix()])
        try:
            self.assertEqual(layer.verdict("fix"), rp.CAUGHT_UP)
        finally:
            layer.close()

    def test_type_against_geometry(self):
        wrong = self.fix(members=[["w", 101, "from"], ["n", 5, "via"], ["w", 201, "to"]])
        rel = (60, [("w", 101, "from"), ("w", 201, "to")], {"type": "restriction", "restriction": "no_right_turn"})
        split = grid_map(extra_rel=[rel]).replace('<nd ref="4"/><nd ref="5"/><nd ref="6"/>',
                                                  '<nd ref="4"/><nd ref="5"/>')
        split = split.replace('<nd ref="2"/><nd ref="5"/><nd ref="13"/><nd ref="8"/>', '<nd ref="5"/><nd ref="13"/><nd ref="8"/>')
        layer = Layer(split, repo=[wrong])
        try:
            self.assertEqual(layer.verdict("fix"), rp.CHECK)
            self.assertIn("по геометрии", layer.by_id["fix"]["reason"])
        finally:
            layer.close()


class Pure(unittest.TestCase):
    def test_repo_file_is_valid(self):
        settings, patches = rp.load_repo(rp.REPO_FILE)
        self.assertTrue(patches)
        ids = set()
        for raw in patches:
            patch, why = rp.normalize(raw, "repo")
            self.assertIsNone(why, raw.get("id"))
            self.assertNotIn(patch["id"], ids)
            ids.add(patch["id"])
            if patch["kind"] != "relation_fix":
                self.assertTrue(patch["expect"].get("at"), patch["id"])

    def test_normalize_rejects(self):
        bad = [{"id": "x", "kind": "teleport"},
               {"id": "x", "kind": "turn_ban", "restriction": "no_left_turn"},
               {"id": "x", "kind": "turn_ban", "restriction": "maybe", "path": [1, 2, 3]},
               {"id": "x", "kind": "turn_ban", "restriction": "only_left_turn", "path": [1, 2, 3, 4]},
               {"id": "x", "kind": "oneway", "path": [1]},
               {"id": "", "kind": "unbarrier", "node": 1},
               {"id": "x", "kind": "relation_fix", "relation": "abc"}]
        for raw in bad:
            self.assertIsNone(rp.normalize(raw, "repo")[0], raw)

    def test_bad_panel_patch_is_reported_not_dropped(self):
        patches, rejected, _ = rp.gather(None, [{"id": 1, "kind": "turn_ban", "raw": [69.2, 41.3], "props": {}}])
        self.assertEqual(patches, [])
        self.assertEqual(rejected[0]["verdict"], rp.CHECK)
        self.assertEqual(rejected[0]["id"], "panel-1")

    def test_violations(self):
        check = {"ban_paths": [[4, 5, 8]], "forbidden_pairs": [[3, 6]]}  # путь узлов, без карты
        self.assertEqual(rp.violations([1, 4, 5, 8, 9], check), 1)
        self.assertEqual(rp.violations([1, 4, 5, 6, 9], check), 0)
        self.assertEqual(rp.violations([2, 3, 6, 9], check), 1)
        self.assertEqual(rp.violations([9, 6, 3], check), 0)

    def test_check_runs(self):
        tmp = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(tmp, "probes"))

            def route(nodes):
                return {"code": "Ok", "routes": [{"distance": 100, "duration": 10,
                                                  "legs": [{"annotation": {"nodes": nodes}}]}]}
            with open(os.path.join(tmp, "pair.json"), "w") as f:
                json.dump(route([4, 5, 8]), f)
            with open(os.path.join(tmp, "probes", "b-1.json"), "w") as f:
                json.dump(route([1, 12, 2]), f)
            with open(os.path.join(tmp, "probes", "ban.json"), "w") as f:
                json.dump({"code": "NoSegment"}, f)
            report = {"patches": [
                {"id": "ban", "check": {"ban_paths": [[4, 5, 8]]}, "probes": [{"id": "ban", "expect": "avoid"}]},
                {"id": "b", "check": {"through": 12}, "probes": [{"id": "b-1", "expect": "through"}]}]}
            r = rp.check_runs(report, tmp)
            self.assertEqual(r["violations"], 1)
            self.assertEqual(r["by_patch"], {"ban": 1})
            self.assertTrue(r["probes"]["b-1"]["ok"])
            self.assertTrue(r["probes"]["ban"]["ok"])
        finally:
            shutil.rmtree(tmp)

    def test_probe_url(self):
        url = rp.probe_url("http://x", {"from": [41.3, 69.2], "to": [41.31, 69.21], "bearings": [90, None]})
        self.assertIn("bearings=90,60;", url)
        self.assertIn("annotations=nodes", url)

    def test_cards_put_route_lefts_first(self):
        # Перекрёсток A (центр сетки) — без маршрутов; B (восточнее) — маршрут налево.
        def coords(nid):
            return list(at(nid))
        nodes = {i: coords(i) for i in range(1, 10)}
        nodes.update({20 + i: [nodes[i][0], nodes[i][1] + 1200 * M_LON] for i in range(1, 10)})
        ways = {}
        for base in (0, 20):
            for k, refs in enumerate(([1, 2, 3], [4, 5, 6], [7, 8, 9], [1, 4, 7], [2, 5, 8], [3, 6, 9])):
                refs = [r + base for r in refs]
                ways[str(1000 + base + k)] = {"tags": {"highway": "primary", "name": f"У{base + k}"},
                                              "nodes": refs, "coords": [nodes[r] for r in refs]}
        scan = {"ways": ways, "nodes": {}}
        audit = {"junctions": [
            {"at": nodes[5], "nodes": [5], "streets": ["A"], "signal": True, "score": 50, "restrictions": 0},
            {"at": nodes[25], "nodes": [25], "streets": ["B"], "signal": True, "score": 40, "restrictions": 0},
            {"at": nodes[2], "nodes": [2], "streets": ["C"], "score": 90, "restrictions": 2}]}
        tmp = tempfile.mkdtemp()
        try:
            with open(os.path.join(tmp, "p.json"), "w") as f:
                json.dump({"routes": [{"legs": [{"annotation": {"nodes": [24, 25, 28]}}]}]}, f)
            cards = rp.junction_cards(scan, audit, [tmp])
        finally:
            shutil.rmtree(tmp)
        self.assertEqual([c["streets"] for c in cards], [["B"], ["A"]])
        self.assertEqual(cards[0]["route_lefts"], 1)
        left = [m for m in cards[0]["moves"] if m["path"] == [24, 25, 28]]
        self.assertEqual(left[0]["kind"], "left")
        self.assertEqual(left[0]["routes"], 1)
        kinds = {m["kind"] for m in cards[1]["moves"]}
        self.assertEqual(kinds, {"left", "uturn"})


def docker_ok():
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class Engine:
    """Собрать карту нашим профилем (CH) и спрашивать маршруты."""

    def __init__(self, pbf):
        self.dir = tempfile.mkdtemp(prefix="rp91osrm_")
        shutil.copy(pbf, os.path.join(self.dir, "t.osm.pbf"))
        lua = "/opt/car_radarmap.lua"
        base = ["docker", "run", "--rm", "-v", f"{self.dir}:/data", "-v", f"{PROFILE}:{lua}:ro", IMAGE]
        r = subprocess.run(base + ["osrm-extract", "-p", lua, "/data/t.osm.pbf"], check=True,
                           capture_output=True, text=True, timeout=180)
        self.extract_log = r.stdout + r.stderr
        subprocess.run(base + ["osrm-contract", "/data/t.osrm"], check=True, capture_output=True, timeout=180)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.container = subprocess.run(
            ["docker", "run", "-d", "--rm", "-p", f"127.0.0.1:{self.port}:5000", "-v", f"{self.dir}:/data",
             IMAGE, "osrm-routed", "--algorithm", "ch", "/data/t.osrm"],
            check=True, capture_output=True, text=True).stdout.strip()
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/nearest/v1/driving/{LON0},{LAT0}", timeout=1)
                break
            except OSError:
                time.sleep(0.2)

    def nodes(self, a, b):
        (alat, alon), (blat, blon) = at(a), at(b)
        url = (f"http://127.0.0.1:{self.port}/route/v1/driving/{alon:.7f},{alat:.7f};{blon:.7f},{blat:.7f}"
               "?overview=false&annotations=nodes")
        with urllib.request.urlopen(url, timeout=10) as r:
            return rp.route_nodes(json.load(r)["routes"][0])

    def close(self):
        subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
        shutil.rmtree(self.dir, ignore_errors=True)


@unittest.skipUnless(HAVE_OSMIUM and docker_ok(), "нужны pyosmium и Docker с образом OSRM")
class EngineSeesPatches(unittest.TestCase):
    """Один и тот же город до и после слоя: запрет, кирпич и снятый барьер
    меняют маршрут OSRM."""

    @classmethod
    def setUpClass(cls):
        xml = grid_map(barrier_on=12)
        patches = [BAN,
                   {"id": "b", "kind": "unbarrier", "node": 12, "expect": {"at": at(12), "tags": {"barrier": "yes"}}},
                   {"id": "kirpich", "kind": "no_entry", "path": [3, 6], "expect": {"at": [at(3), at(6)]}}]
        cls.empty = Layer(xml)
        cls.layer = Layer(xml, repo=patches)
        cls.before = Engine(cls.empty.out)
        cls.after = Engine(cls.layer.out)

    @classmethod
    def tearDownClass(cls):
        for item in (cls.before, cls.after, cls.empty, cls.layer):
            item.close()

    def test_restriction_reaches_the_graph(self):
        self.assertIn("Constructing restriction graph on 0 restrictions", self.before.extract_log)
        self.assertIn("Constructing restriction graph on 1 restrictions", self.after.extract_log)

    def test_turn_ban_changes_route(self):
        check = self.layer.by_id["ban"]["check"]
        self.assertEqual(rp.violations(self.before.nodes(4, 13), check), 1)
        after = self.after.nodes(4, 13)
        self.assertEqual(rp.violations(after, check), 0)
        self.assertIn(13, after)

    def test_barrier_removed_opens_street(self):
        self.assertNotIn(12, self.before.nodes(1, 2))
        self.assertIn(12, self.after.nodes(1, 2))

    def test_no_entry_changes_route(self):
        check = self.layer.by_id["kirpich"]["check"]
        self.assertEqual(rp.violations(self.before.nodes(3, 6), check), 1)
        after = self.after.nodes(3, 6)
        self.assertEqual(rp.violations(after, check), 0)
        # Выезд из квартала по-прежнему открыт.
        self.assertEqual(self.after.nodes(6, 3)[:2], [6, 3])


if __name__ == "__main__":
    unittest.main()
