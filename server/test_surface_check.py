"""Тесты проверки поверхности и починок генерации (снимок моста Навои, 27.09.2026)."""
import math
import unittest

import build_mvt
import build_roads
import surface_check as sc

LAT, LON = 41.3209, 69.2603


def metres(dx, dy):
    """Точка (lon, lat) в dx, dy метрах от опорной."""
    return (LON + dx / (sc.LAT_METERS * math.cos(math.radians(LAT))),
            LAT + dy / sc.LAT_METERS)


def ring(*xy):
    return [metres(x, y) for x, y in xy]


class DefectTests(unittest.TestCase):
    def test_clean_square_passes(self):
        self.assertIsNone(sc.defect(ring((0, 0), (20, 0), (20, 20), (0, 20))))

    def test_bowtie_is_self_intersection(self):
        # Ровно «бабочка» разделительной со снимка.
        self.assertEqual(sc.defect(ring((0, 0), (30, 20), (30, 0), (0, 20))),
                         sc.REASON_SELF_INTERSECTION)

    def test_needle_is_a_spike(self):
        self.assertEqual(sc.defect(ring((0, 0), (40, 0), (40, 12), (0, 12), (-60, 7), (0, 6))),
                         sc.REASON_SPIKE)

    def test_thin_blade_is_a_sliver(self):
        self.assertEqual(sc.defect(ring((0, 0), (60, 0), (60, 0.6), (0, 0.6))),
                         sc.REASON_SLIVER)

    def test_road_piece_is_checked_for_integrity_only(self):
        # Короткий кусок полотна — «лезвие» по средней ширине, но не брак.
        short = ring((0, 0), (1, 0), (1, 7), (0, 7))
        self.assertEqual(sc.defect(short), sc.REASON_SLIVER)
        self.assertIsNone(sc.defect_of_kind(build_roads.AREA_ROAD, short))
        self.assertEqual(sc.defect_of_kind(build_roads.AREA_MEDIAN, short), sc.REASON_SLIVER)

    def test_degenerate(self):
        self.assertEqual(sc.defect(ring((0, 0), (10, 0))), sc.REASON_DEGENERATE)


class RoadSurfaceTests(unittest.TestCase):
    def test_sharp_inner_corner_no_longer_loops(self):
        # Широкая улица с поворотом на 100°: раньше кромка внутренней стороны
        # перехлёстывала сама себя, и заливка выедала дыру.
        axis = ring((0, 0), (60, 0), (50, 60))
        contour = build_roads.road_contour(axis, 24.0)
        self.assertIsNone(sc.defect(contour, shape_checks=False))

    def test_zigzag_is_split_into_clean_pieces(self):
        axis = ring(*[(i * 6, (8 if i % 2 else 0)) for i in range(12)])
        pieces = list(build_roads.surface_pieces(axis, 20.0))
        self.assertTrue(pieces)
        for piece in pieces:
            self.assertIsNone(sc.defect(piece, shape_checks=False))

    def test_straight_street_stays_one_piece(self):
        axis = ring((0, 0), (100, 5), (200, 0))
        self.assertEqual(len(list(build_roads.surface_pieces(axis, 14.0))), 1)


class LoopTests(unittest.TestCase):
    def test_roundabout_ring_is_built_not_dropped(self):
        # Кольцо — замкнутая лента: целиком её контур пересекает сам себя.
        ring_axis = [metres(25 * math.cos(math.radians(a)), 25 * math.sin(math.radians(a)))
                     for a in range(0, 361, 20)]
        rings = build_roads._surface_rings(ring_axis, 8.0)
        self.assertTrue(rings)
        for piece in rings:
            self.assertIsNone(sc.defect(build_roads.quantized(piece), shape_checks=False))


class MedianTests(unittest.TestCase):
    def test_backtracking_partner_does_not_make_a_bowtie(self):
        # Встречная лента у моста сворачивает и идёт назад: ближайшая точка
        # прыгает, и прежняя полоса выворачивалась «бабочкой».
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Navoiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 20), (150, 20), (120, 45), (200, 60)),
                 "Navoiy ko'chasi", 10.0)
        strip = build_roads._median_strip(one, other)
        if strip:
            self.assertIsNone(sc.defect(strip))

    def test_parallel_carriageways_still_get_a_median(self):
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Navoiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 22), (0, 22)), "Navoiy ko'chasi", 10.0)
        strip = build_roads._median_strip(one, other)
        self.assertTrue(strip)
        self.assertIsNone(sc.defect(strip))

    def test_median_resumes_after_a_junction(self):
        # Мукими у «Новзы»: первый же узел обрывал разделительную до конца проспекта.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (600, 0)), "Muqimiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((600, 22), (0, 22)), "Muqimiy ko'chasi", 10.0)
        junctions = [(metres(300, 11), 30.0)]
        strips = build_roads._median_strips(one, other, junctions)
        self.assertEqual(len(strips), 2, "по полосе с каждой стороны узла")
        for strip in strips:
            self.assertIsNone(sc.defect(strip))
            deeper = [(node, radius - 5.0) for node, radius in junctions]
            self.assertFalse(any(build_roads._at_junction(p, deeper) for p in strip),
                             "полоса доходит до края узла, но не лезет в его середину")

    def test_median_reaches_the_junction_edge(self):
        # Шаг 25 м: без уточнения полоса кончалась за 10–30 м до перехода.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (600, 0)), "Muqimiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((600, 22), (0, 22)), "Muqimiy ko'chasi", 10.0)
        junctions = [(metres(310, 11), 22.0)]      # край узла по оси: 310 ± ~19 м
        strips = build_roads._median_strips(one, other, junctions)
        self.assertEqual(len(strips), 2)
        kx = sc.LAT_METERS * math.cos(math.radians(LAT))
        west_end = min((max(p[0] for p in s) - LON) * kx for s in strips)
        # Ось входит в круг узла на 310 − √(22² − 11²) ≈ 291 м.
        self.assertGreater(west_end, 289, "до края узла меньше пары метров, а не шаг в 25 м")
        # Плюс скруглённый нос (не глубже MEDIAN_NOSE_MAX_METERS).
        self.assertLess(west_end, 291.5 + build_roads.MEDIAN_NOSE_MAX_METERS)
        for strip in strips:
            self.assertIsNone(sc.defect(strip))

    def test_strip_gate_checks_integrity_and_width_not_angles(self):
        # Полоса 2,5 × 200 м с острым торцом: для полосы это форма, не брак.
        strip = ring((0, 0), (200, 0), (203, 2.5), (0, 2.5))
        self.assertIsNone(sc.defect_of_kind(9, strip, sc.STRIP_FLAG))
        self.assertIsNone(sc.defect_of_kind(8, strip, sc.STRIP_FLAG))
        thread = ring((0, 0), (200, 0), (200, 0.6), (0, 0.6))
        self.assertEqual(sc.defect_of_kind(9, thread, sc.STRIP_FLAG), sc.REASON_SLIVER)
        bowtie = ring((0, 0), (20, 5), (20, 0), (0, 5))
        self.assertIsNotNone(sc.defect_of_kind(9, bowtie, sc.STRIP_FLAG))

    def u_turn(self, crossover_name=""):
        """Проспект из двух лент и связка разворота между ними."""
        name = "Muqimiy ko'chasi"
        west = [(3, 1, ring((-200, 0), (0, 0)), name), (3, 1, ring((0, 0), (200, 0)), name)]
        east = [(3, 1, ring((200, 20), (0, 20)), name), (3, 1, ring((0, 20), (-200, 20)), name)]
        link = [(3, 0, ring((0, 0), (0, 20)), crossover_name)]
        chains = build_roads.street_chains(west + east + link)
        return chains, build_roads.junction_arms(chains)

    def test_side_drive_on_one_carriageway_does_not_break_the_median(self):
        name = "Navoiy ko'chasi"
        west = [(3, 1, ring((-200, 0), (0, 0)), name), (3, 1, ring((0, 0), (200, 0)), name)]
        east = [(3, 1, ring((200, 20), (-200, 20)), name)]
        drive = [(7, 0, ring((0, 0), (0, -60)), "")]          # двор к одному направлению
        chains = build_roads.street_chains(west + east + drive)
        arms = build_roads.junction_arms(chains)
        self.assertEqual(build_roads.median_stops(arms, chains), [])

    def test_crossing_of_two_streets_breaks_the_median(self):
        name = "Navoiy ko'chasi"
        west = [(3, 1, ring((-200, 0), (0, 0)), name), (3, 1, ring((0, 0), (200, 0)), name)]
        east = [(3, 1, ring((200, 20), (-200, 20)), name)]
        cross = [(4, 0, ring((0, 0), (0, -100)), "Abay ko'chasi")]
        chains = build_roads.street_chains(west + east + cross)
        arms = build_roads.junction_arms(chains)
        self.assertEqual(len(build_roads.median_stops(arms, chains)), 1)

    def test_u_turn_gap_is_as_wide_as_the_crossover(self):
        chains, arms = self.u_turn()
        stops = build_roads.median_stops(arms, chains)
        old = dict((build_roads._node_key(n), r) for n, r in build_roads.junction_spots(arms))
        self.assertEqual(len(stops), 2)
        link_width = [s for s, _c in chains if not s[3]][0][4]
        for node, radius in stops:
            self.assertAlmostEqual(radius, link_width / 2 + build_roads.MEDIAN_STOP_MARGIN_METERS)
            self.assertLess(radius, old[build_roads._node_key(node)])

    def test_other_street_is_not_a_u_turn(self):
        # Короткая улица с ДРУГИМ именем между лентами — перекрёсток, радиус прежний.
        chains, arms = self.u_turn("Boshqa ko'cha")
        stops = dict((build_roads._node_key(n), r) for n, r in build_roads.median_stops(arms, chains))
        old = dict((build_roads._node_key(n), r) for n, r in build_roads.junction_spots(arms))
        self.assertEqual(stops, old)

    def test_median_ends_are_rounded_noses(self):
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Navoiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 22), (0, 22)), "Navoiy ko'chasi", 10.0)
        strip, = build_roads._median_strips(one, other)
        kx = sc.LAT_METERS * math.cos(math.radians(LAT))
        xs = [(p[0] - LON) * kx for p in strip]
        ys = [(p[1] - LAT) * sc.LAT_METERS for p in strip]
        # Полоса 5..17 м по y (ширина 12, половина 6 → нос глубиной 3 м).
        tip = max(range(len(xs)), key=lambda i: xs[i])
        self.assertAlmostEqual(ys[tip], 11.0, delta=0.6, msg="вершина носа — посередине полосы")
        flat_end = max(x for x, y in zip(xs, ys) if abs(y - 5) < 0.3 or abs(y - 17) < 0.3)
        self.assertAlmostEqual(xs[tip] - flat_end, build_roads.MEDIAN_NOSE_MAX_METERS, delta=0.3)
        self.assertIsNone(sc.defect_of_kind(9, strip, sc.STRIP_FLAG))

    def test_narrow_gap_gets_a_double_line_not_a_strip(self):
        # Беруни: между кромками ~1,5 м — у Яндекса двойная жёлтая, не полоса.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Beruniy shoh ko'chasi", 12.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 13.5), (0, 13.5)), "Beruniy shoh ko'chasi", 12.0)
        dividers = []
        strips = build_roads._median_strips(one, other, (), None, dividers)
        self.assertEqual(strips, [])
        self.assertEqual(len(dividers), 1)
        ys = [(p[1] - LAT) * sc.LAT_METERS for p in dividers[0]]
        self.assertTrue(all(abs(y - 6.75) < 0.2 for y in ys), "линия — посередине между лентами")
        made = build_roads.build_medians([(one, []), (other, [])])
        self.assertTrue(any(k == build_roads.AREA_DIVIDER and not f & 1 for k, f, _r in made))
        self.assertTrue(build_roads.surface_gate((build_roads.AREA_DIVIDER, 0, dividers[0])),
                        "ворота пропускают линию")

    def test_converging_wedge_loses_its_thread_tail(self):
        # Ленты сходятся: хвост клина уже 1,5 м не рисуется нитью бордюров.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Zarqaynar ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 30), (0, 10.5)), "Zarqaynar ko'chasi", 10.0)
        strips = build_roads._median_strips(one, other)
        self.assertTrue(strips)
        for strip in strips:
            kx = sc.LAT_METERS * math.cos(math.radians(LAT))
            xs = [(p[0] - LON) * kx for p in strip]
            # У x≈0 зазор между кромками ~0,5 м — туда полоса не доходит.
            self.assertGreater(min(xs), 10.0)

    def test_wide_gap_keeps_the_strip(self):
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Navoiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 22), (0, 22)), "Navoiy ko'chasi", 10.0)
        dividers = []
        self.assertTrue(build_roads._median_strips(one, other, (), None, dividers))
        self.assertEqual(dividers, [])

    def test_no_median_over_a_road_between_the_carriageways(self):
        # Фурката: между встречными лентами — пандус эстакады; разделительная
        # ложилась поверх его полос.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Furqat ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 30), (0, 30)), "Furqat ko'chasi", 10.0)
        ramp = (3, build_roads.FLAG_ONEWAY, ring((0, 15), (300, 15)), "", 8.0)
        made = build_roads.build_medians([(one, []), (other, []), (ramp, [])])
        self.assertFalse(any(k == build_roads.AREA_MEDIAN for k, _f, _r in made))
        made = build_roads.build_medians([(one, []), (other, [])])
        self.assertTrue(any(k == build_roads.AREA_MEDIAN for k, _f, _r in made))

    def test_short_crossover_between_steps_breaks_the_median(self):
        # Каратош: перемычка в 15 м между шагами в 25 м — полоса шла насквозь.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Qoratosh ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 24), (0, 24)), "Qoratosh ko'chasi", 10.0)
        link = (3, 0, ring((137, 0), (137, 24)), "", 10.0)
        made = build_roads.build_medians([(one, []), (other, []), (link, [])])
        strips = [r for k, _f, r in made if k == build_roads.AREA_MEDIAN]
        self.assertEqual(len(strips), 2, "по полосе с каждой стороны проезда")
        kx = sc.LAT_METERS * math.cos(math.radians(LAT))
        for strip in strips:
            xs = [(p[0] - LON) * kx for p in strip]
            self.assertTrue(max(xs) < 137 or min(xs) > 137, "полоса не пересекает проезд")

    def test_bridge_and_ground_carriageways_are_not_a_pair(self):
        one = (3, build_roads.FLAG_ONEWAY | build_roads.FLAG_BRIDGE, ring((0, 0), (300, 0)), "Furqat ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 22), (0, 22)), "Furqat ko'chasi", 10.0)
        self.assertEqual(build_roads.build_medians([(one, []), (other, [])]), [])

    def test_side_ramp_does_not_break_the_median(self):
        # Съезд справа примыкает к одной ленте — разделительная идёт дальше.
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (600, 0)), "Muqimiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((600, 22), (0, 22)), "Muqimiy ko'chasi", 10.0)
        ramps = [(metres(200, -2), 13.0), (metres(400, 24), 13.0)]
        self.assertEqual(len(build_roads._median_strips(one, other, ramps)), 1)

    def test_strips_are_flagged_apart_from_islands(self):
        one = (3, build_roads.FLAG_ONEWAY, ring((0, 0), (300, 0)), "Navoiy ko'chasi", 10.0)
        other = (3, build_roads.FLAG_ONEWAY, ring((300, 22), (0, 22)), "Navoiy ko'chasi", 10.0)
        areas = build_roads.build_medians([(one, []), (other, [])])
        self.assertTrue(areas)
        for kind, flags, _ring in areas:
            self.assertEqual(kind, build_roads.AREA_MEDIAN)
            self.assertTrue(flags & build_roads.AREA_FLAG_STRIP)
            self.assertEqual(build_mvt._area_props(kind, flags), {"kind": 9, "strip": True})
        self.assertEqual(build_mvt._area_props(build_roads.AREA_MEDIAN, build_roads.AREA_FLAG_CLOSED),
                         {"kind": 9}, "островок — без флага, лежит под полотном")


class IslandTests(unittest.TestCase):
    def road(self, name, length=30.0):
        return (3, 0, ring((0, 0), (length, 0)), name)

    def test_junction_interior_is_not_an_island(self):
        # Середина перекрёстка двух проспектов: только именованные ленты двух улиц.
        face = [self.road("Navoiy"), self.road("Anhor"), self.road("Navoiy"), self.road("Anhor")]
        self.assertFalse(build_roads.is_island_face(face))

    def test_short_unnamed_connector_does_not_make_an_island(self):
        # Навои × Рашидов: середину перекрёстка обходит связка в пару метров.
        face = [self.road("Navoiy"), self.road("Rashidov"), self.road("Navoiy"),
                self.road("Rashidov"), self.road("", 3.0)]
        self.assertFalse(build_roads.is_island_face(face))

    def test_slip_lane_island_is_kept(self):
        face = [self.road("Navoiy"), self.road("", 35.0), self.road("Anhor")]
        self.assertTrue(build_roads.is_island_face(face))

    def test_face_of_one_street_is_kept(self):
        self.assertTrue(build_roads.is_island_face([self.road("Navoiy"), self.road("Navoiy")]))


class GateTests(unittest.TestCase):
    def test_gate_checks_the_quantized_shape_and_counts(self):
        build_roads.SURFACE_REJECTED.clear()
        bowtie = (build_roads.AREA_MEDIAN, build_roads.AREA_FLAG_CLOSED,
                  ring((0, 0), (30, 20), (30, 0), (0, 20)))
        self.assertFalse(build_roads.surface_gate(bowtie))
        self.assertEqual(build_roads.SURFACE_REJECTED[(build_roads.AREA_MEDIAN,
                                                      sc.REASON_SELF_INTERSECTION)], 1)
        good = (build_roads.AREA_JUNCTION, build_roads.AREA_FLAG_CLOSED,
                ring((0, 0), (20, 0), (20, 20), (0, 20)))
        self.assertTrue(build_roads.surface_gate(good))


class JunctionTests(unittest.TestCase):
    def test_minor_junction_is_left_to_the_line(self):
        # Серый ромб цветом проспекта на перекрёстке дворовых проездов.
        node = metres(0, 0)
        arms = {build_roads._node_key(node): [
            (node, metres(40, 0), 6.0), (node, metres(-40, 0), 6.0), (node, metres(0, 40), 5.0)]}
        self.assertEqual(build_roads.build_junctions(arms), [])

    def test_wedge_of_land_is_not_asphalt(self):
        # Оболочка, где больше трети площади — не полотно, а земля между улицами.
        node = metres(0, 0)
        legs = [(node, metres(12, 0), 25.0), (node, metres(-12, 0), 25.0),
                (node, metres(3, 12), 14.0)]
        wedge = [metres(-12, -12), metres(60, -12), metres(60, 60), metres(-12, 12)]
        self.assertGreater(build_roads.uncovered_share(legs, wedge),
                           build_roads.JUNCTION_MAX_UNCOVERED)
        self.assertFalse(build_roads._hull_fits(legs, wedge))


class CarriagewayTests(unittest.TestCase):
    def street(self, points, width):
        return ((3, build_roads.FLAG_ONEWAY, points, "Navoiy ko'chasi", width, False), [])

    def test_guessed_widths_leave_room_for_the_median(self):
        # Оси в 16 м друг от друга, ширина по классу 14 м у каждой: без
        # подгонки ленты перекрываются и разделительной нет.
        streets = [self.street(ring((0, 0), (300, 0)), 14.0),
                   self.street(ring((300, 16), (0, 16)), 14.0)]
        fitted = build_roads.fit_carriageways(streets)
        widths = [s[0][4] for s in fitted]
        self.assertLessEqual(sum(widths) / 2, 16 - build_roads.CARRIAGEWAY_MIN_GAP_METERS + 0.05)

    def test_well_separated_carriageways_are_untouched(self):
        streets = [self.street(ring((0, 0), (300, 0)), 10.0),
                   self.street(ring((300, 30), (0, 30)), 10.0)]
        self.assertEqual([s[0][4] for s in build_roads.fit_carriageways(streets)], [10.0, 10.0])


class CrossingTests(unittest.TestCase):
    def test_marked_crossings_by_osm_meaning(self):
        marked = build_roads.crossing_is_marked
        for tags in ({"crossing": "zebra"}, {"crossing": "marked"}, {"crossing": "uncontrolled"},
                     {"crossing": "traffic_signals"}, {"crossing": "traffic_signals;marked"},
                     {"crossing:markings": "zebra"}, {"crossing:markings": "yes"}):
            self.assertTrue(marked(tags), tags)
        for tags in ({"crossing": "unmarked"}, {}, {"crossing": "traffic_signals", "crossing:markings": "no"}):
            self.assertFalse(marked(tags), tags)


class LaneArrowTests(unittest.TestCase):
    def point(self, turns, width=12, azimuth=90):
        flags = build_roads.point_flags(azimuth, width)
        return build_roads.pack_turns(flags, turns)

    def test_one_arrow_per_lane_left_to_right(self):
        # Дорога на восток (азимут 90°): левая по ходу полоса — севернее.
        turns = [build_roads.TURN_LEFT, build_roads.TURN_THROUGH, build_roads.TURN_RIGHT]
        arrows = list(build_mvt.lane_arrows(build_roads.POINT_LANE_ARROWS,
                                            self.point(turns), (LON, LAT)))
        self.assertEqual([p["turn"] for _spot, p in arrows], turns)
        lats = [spot[1] for spot, _p in arrows]
        self.assertGreater(lats[0], lats[1])
        self.assertGreater(lats[1], lats[2])
        # Перед стоп-линией: западнее точки подхода.
        self.assertTrue(all(spot[0] < LON for spot, _p in arrows))
        self.assertTrue(all(p["bearing"] == 90 for _spot, p in arrows))

    def test_empty_lane_draws_nothing(self):
        turns = [build_roads.TURN_NONE, build_roads.TURN_THROUGH]
        arrows = list(build_mvt.lane_arrows(build_roads.POINT_LANE_ARROWS, self.point(turns), (LON, LAT)))
        self.assertEqual(len(arrows), 1)

    def test_other_points_have_no_arrows(self):
        self.assertEqual(list(build_mvt.lane_arrows(1, self.point([1]), (LON, LAT))), [])


class ArrowRowFitsDrawnRoadTests(unittest.TestCase):
    """Ряд стрелок делит нарисованную ленту, а не ширину из записи полос.

    Нурафшон, снимок CarPlay 13.10.2026: запись 4 полосы → 14 м, лента
    нарисована в 10,6 м — крайние стрелки легли на бордюр и за кромку.
    """

    def point(self, turns, width=14, azimuth=90, oneway=True):
        flags = build_roads.point_flags(azimuth, width) | (build_roads.PFLAG_ONEWAY if oneway else 0)
        return build_roads.pack_turns(flags, turns)

    def across(self, spot):
        # Дорога на восток: «вбок» — по широте, плюс к северу (влево по ходу).
        return (spot[1] - LAT) * sc.LAT_METERS

    def test_row_spans_the_drawn_width_not_the_tagged_one(self):
        turns = [build_roads.TURN_LEFT, build_roads.TURN_THROUGH, build_roads.TURN_THROUGH,
                 build_roads.TURN_RIGHT]
        drawn = 10.6
        carriageway = lambda centre, bearing: ((centre[0], LAT), drawn, True)
        arrows = list(build_mvt.lane_arrows(build_roads.POINT_LANE_ARROWS, self.point(turns),
                                            (LON, LAT), carriageway=carriageway))
        self.assertEqual(len(arrows), 4)
        lane = drawn / 4
        for spot, props in arrows:
            self.assertAlmostEqual(props["lw"], round(lane, 1))
            # Значок не шире полосы: его край — внутри ленты.
            self.assertLessEqual(abs(self.across(spot)) + lane / 2, drawn / 2 + 1e-6)
        self.assertGreater(self.across(arrows[0][0]), self.across(arrows[-1][0]), "левая полоса — слева")

    def test_row_sits_on_the_axis_of_the_ribbon(self):
        # Точка посадки в метре от оси — ряд всё равно по центру ленты.
        turns = [build_roads.TURN_THROUGH, build_roads.TURN_THROUGH]
        carriageway = lambda centre, bearing: ((centre[0], LAT), 7.0, True)
        arrows = list(build_mvt.lane_arrows(build_roads.POINT_LANE_ARROWS, self.point(turns),
                                            metres(0, 1.0), carriageway=carriageway))
        mid = sum(self.across(spot) for spot, _p in arrows) / len(arrows)
        self.assertAlmostEqual(mid, 0.0, delta=0.01)

    def test_two_way_road_keeps_arrows_on_its_right_half(self):
        turns = [build_roads.TURN_LEFT, build_roads.TURN_THROUGH]
        carriageway = lambda centre, bearing: ((centre[0], LAT), 12.0, False)
        arrows = list(build_mvt.lane_arrows(build_roads.POINT_LANE_ARROWS, self.point(turns, oneway=False),
                                            (LON, LAT), carriageway=carriageway))
        for spot, props in arrows:
            self.assertLess(self.across(spot), 0, "правая по ходу половина — южнее оси")
            self.assertLessEqual(abs(self.across(spot)) + props["lw"] / 2, 6.0 + 1e-6)

    def test_carriageway_lookup_finds_the_ribbon_under_the_row(self):
        road = (3, build_roads.FLAG_ONEWAY, [metres(-50, 0), metres(50, 0)], "")
        index = build_mvt.OverlapIndex([road], {id(road): 10.6})
        found = index.carriageway(metres(0, 2.0), 90)
        self.assertIsNotNone(found)
        axis, width, oneway = found
        self.assertAlmostEqual(width, 10.6, places=3)
        self.assertTrue(oneway)
        self.assertAlmostEqual((axis[1] - LAT) * sc.LAT_METERS, 0.0, delta=0.01)
        self.assertIsNone(index.carriageway(metres(0, 2.0), 270), "встречное направление — не наша лента")
        self.assertIsNone(index.carriageway(metres(0, 12.0), 90), "мимо полотна — ленты нет")


class ArrowRowPastStopTests(unittest.TestCase):
    """Ряд за стоп-линией или зеброй — уже в перекрёстке (снимок CarPlay 13.10.2026)."""

    def row(self, x):
        return [(metres(x, y), {"turn": 1, "lw": 3.0}) for y in (-4.5, -1.5, 1.5, 4.5)]

    def line_at(self, x):
        return [metres(x, -7), metres(x, 7)]

    def test_row_between_the_stop_line_and_the_junction_is_dropped(self):
        stops = build_mvt.StopIndex([self.line_at(-12)])
        self.assertTrue(build_mvt.row_past_stop(self.row(0), 90, stops, build_mvt.StopIndex([])))

    def test_row_past_a_zebra_is_dropped(self):
        zebras = build_mvt.StopIndex([self.line_at(-8)])
        self.assertTrue(build_mvt.row_past_stop(self.row(0), 90, build_mvt.StopIndex([]), zebras))

    def test_row_before_its_stop_line_stays(self):
        # Ряд перед стоп-линией, а позади — прежний светофор: ряд на месте.
        stops = build_mvt.StopIndex([self.line_at(11), self.line_at(-20)])
        self.assertFalse(build_mvt.row_past_stop(self.row(0), 90, stops, build_mvt.StopIndex([])))

    def test_row_with_nothing_around_stays(self):
        self.assertFalse(build_mvt.row_past_stop(self.row(0), 90, build_mvt.StopIndex([]),
                                                 build_mvt.StopIndex([])))

    def test_oncoming_stop_line_does_not_count(self):
        # Стоп-линия встречных позади нас, на другой ленте — не наша.
        far = build_mvt.StopIndex([[metres(-10, 12), metres(-10, 26)]])
        self.assertFalse(build_mvt.row_past_stop(self.row(0), 90, far, build_mvt.StopIndex([])))


class ArrowLeaderTests(unittest.TestCase):
    def arrow(self, x, y, bearing=90, width=10):
        turns = [1, 2]
        flags = build_roads.point_flags(bearing, width)
        for index, turn in enumerate(turns):
            flags |= turn << (13 + index * 4)
        return (build_mvt.POINT_LANE_ARROWS, flags, [metres(x, y)])

    def test_rows_on_one_approach_keep_the_front_one(self):
        # Навои × Рашидов: 2–3 ряда стрелок подряд на одном подходе.
        points = [self.arrow(0, 0), self.arrow(15, 0), self.arrow(30, 0)]
        self.assertEqual(build_mvt.arrow_leaders(points), {2}, "остаётся ближний к перекрёстку")

    def test_other_approaches_stay(self):
        points = [self.arrow(0, 0), self.arrow(15, 20),                # соседняя лента
                  self.arrow(10, 0, bearing=270), self.arrow(100, 0)]  # встречная и далёкая
        self.assertEqual(build_mvt.arrow_leaders(points), {0, 1, 2, 3})


class ArrowBeforeStopLineTests(unittest.TestCase):
    def test_arrows_stand_before_the_signal_stop_line(self):
        # Конец участка с turn:lanes — у центра; светофор подхода на 25 м раньше.
        flags = build_roads.point_flags(90, 12)          # едем на восток
        signal = (1, build_roads.point_flags(90, 12), [metres(-25, 0)])
        grid = build_mvt._signal_grid([signal])
        setback = build_mvt.arrow_setback(flags, (LON, LAT), grid)
        stop_line = -25 - build_mvt.SIGNAL_STOP_SETBACK
        self.assertAlmostEqual(-setback, stop_line - build_mvt.ARROW_BEFORE_STOP_METERS, delta=0.01,
                               msg="стрелки — перед стоп-линией, а не между ней и зеброй")

    def test_no_signal_keeps_the_usual_setback(self):
        flags = build_roads.point_flags(90, 12)
        self.assertEqual(build_mvt.arrow_setback(flags, (LON, LAT), {}), build_mvt.ARROW_SETBACK_METERS)

    def test_signal_far_ahead_does_not_pull_arrows_back(self):
        flags = build_roads.point_flags(90, 12)
        grid = build_mvt._signal_grid([(1, build_roads.point_flags(90, 12), [metres(5, 0)])])
        self.assertEqual(build_mvt.arrow_setback(flags, (LON, LAT), grid), build_mvt.ARROW_SETBACK_METERS)


class SignalPaintTests(unittest.TestCase):
    def test_stop_line_only_across_a_oneway_carriageway(self):
        flags = build_roads.point_flags(90, 10)
        self.assertEqual(list(build_mvt.road_paint(1, flags, (LON, LAT))), [],
                         "у двусторонней дороги длины стоп-линии мы не знаем")
        lines = list(build_mvt.road_paint(1, flags | build_mvt.PFLAG_ONEWAY, (LON, LAT)))
        self.assertEqual(len(lines), 1)
        (a, b), = lines
        self.assertAlmostEqual(sc.LAT_METERS * abs(a[1] - b[1]), 10, delta=0.2)   # поперёк, на всю ширину
        self.assertLess(a[0], LON, "стоп-линия — ДО светофора по ходу движения")

    def test_two_way_stop_line_lies_on_the_right_half(self):
        # Подъезд на север к узлу в 30 м: линия — справа от оси (восточная половина).
        flags = build_roads.point_flags(0, 12)
        centres = {}
        cx, cy = metres(0, 30)
        centres.setdefault((int(cx / build_mvt._SIGNAL_CELL), int(cy / build_mvt._SIGNAL_CELL)), []).append((cx, cy))
        line = build_mvt.two_way_stop_line(flags, (LON, LAT), centres)
        self.assertIsNotNone(line)
        east = [(p[0] - LON) * sc.LAT_METERS * math.cos(math.radians(LAT)) for p in line]
        self.assertTrue(all(x > 0 for x in east), "правая половина")
        self.assertAlmostEqual(max(east), 6.0, delta=0.1)
        self.assertLess(line[0][1], LAT, "до светофора по ходу")
        self.assertIsNone(build_mvt.two_way_stop_line(flags, (LON, LAT), {}), "без узла — не угадываем")

    def test_waffle_is_the_zone_between_the_signals(self):
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        # Светофоры у стоп-линий четырёх подходов, в ~48 м от центра (как у
        # Навои × Рашидов), каждый смотрит в центр.
        def facing(x, y):
            bearing = math.degrees(math.atan2(-x, -y)) % 360
            return (1, build_roads.point_flags(bearing, 12), [metres(x, y)])
        signals = [facing(x, y) for x, y in ((48, 8), (-48, -8), (8, -48), (-8, 48))]
        zone = build_mvt.waffle_zone(box, build_mvt._signal_grid(signals))
        self.assertIsNotNone(zone)
        area, _ = sc.area_and_perimeter(sc.to_meters(zone))
        self.assertGreater(area, 1500, "зона — весь перекрёсток между стоп-линиями, а не центр осей")
        self.assertIsNone(sc.defect(zone))

    def test_signals_facing_away_do_not_belong_to_the_junction(self):
        # Навои × Фурката: светофоры эстакады и съездов смотрят мимо центра.
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        # Их дороги идут ПОПЕРЁК направления на центр — ось мимо перекрёстка.
        away = [(1, build_roads.point_flags(b, 12), [metres(x, y)])
                for (x, y), b in (((-40, 2), 0), ((40, -2), 180), ((10, 30), 90))]
        self.assertIsNone(build_mvt.waffle_zone(box, build_mvt._signal_grid(away)))

    def facing_signals(self, centre_x, spots):
        def facing(x, y):
            bearing = math.degrees(math.atan2(centre_x - x, -y)) % 360
            return (1, build_roads.point_flags(bearing, 12), [metres(x, y)])
        return [facing(x, y) for x, y in spots]

    def test_signals_of_a_neighbour_junction_do_not_stretch_the_zone(self):
        # Бунёдкор × Сеул: соседний узел в 70 м, его светофоры — в 60 м от нашего центра.
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        other = ring((64, -6), (76, -6), (76, 6), (64, 6))
        own = self.facing_signals(0, ((30, 5), (-30, -5), (5, -30), (-5, 30)))
        theirs = self.facing_signals(70, ((48, 3), (48, -3)))   # на общей дороге, ближе к соседу
        grid = build_mvt._signal_grid(own + theirs)
        loose = build_mvt.waffle_zone(box, grid)
        tight = build_mvt.waffle_zone(box, grid, build_mvt.box_centres([box, other]))
        self.assertIsNotNone(tight)
        widest = max(x for x, _ in sc.to_meters(tight))
        self.assertLess(widest - min(x for x, _ in sc.to_meters(tight)),
                        max(x for x, _ in sc.to_meters(loose)) - min(x for x, _ in sc.to_meters(loose)),
                        "светофоры соседнего узла отданы ему")

    def test_one_light_per_approach_around_the_centre(self):
        # Беруни × Сакичмон у Яндекса: четыре светофора ромбом в центре.
        zone = ring((-20, -20), (20, -20), (20, 20), (-20, 20))
        signals = [metres(x, y) for x, y in ((40, 3), (42, -3), (-40, 0), (2, 40), (0, -40))]
        lights = build_mvt.approach_lights(zone, signals)
        self.assertEqual(len(lights), 4, "два светофора одного подхода — один значок")
        kx = sc.LAT_METERS * math.cos(math.radians(LAT))
        for lon, lat in lights:
            distance = math.hypot((lon - LON) * kx, (lat - LAT) * sc.LAT_METERS)
            self.assertLessEqual(distance, build_mvt.LIGHT_MAX_METERS + 0.01)
            self.assertGreaterEqual(distance, build_mvt.LIGHT_MIN_METERS - 0.01)

    def test_centres_of_one_junction_do_not_split_its_signals(self):
        # Середина узла и ядро пересечения в 12 м друг от друга — один перекрёсток.
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        twin = ring((6, 6), (18, 6), (18, 18), (6, 18))
        own = self.facing_signals(0, ((30, 5), (-30, -5), (5, -30), (-5, 30)))
        grid = build_mvt._signal_grid(own)
        self.assertIsNotNone(build_mvt.waffle_zone(box, grid, build_mvt.box_centres([box, twin])))

    def test_one_icon_point_per_waffle(self):
        # Два центра одного перекрёстка из соседних тайлов — одна «вафля», одна точка.
        zone = ring((-20, -20), (20, -20), (20, 20), (-20, 20))
        shifted = ring((-19, -20), (21, -20), (21, 20), (-19, 20))
        waffles = build_mvt.WaffleSet()
        centre = waffles.add(zone)
        self.assertIsNotNone(centre)
        self.assertIsNone(waffles.add(shifted))
        lon, lat = metres(0, 0)
        self.assertAlmostEqual(centre[0], lon, places=6)
        self.assertAlmostEqual(centre[1], lat, places=6)
        self.assertIsNotNone(waffles.add(ring((80, -20), (120, -20), (120, 20), (80, 20))))

    def _metres_between(self, a, b):
        kx = 111_320 * math.cos(math.radians(a[1]))
        return math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * 111_320)

    def test_diagonal_crossing_becomes_a_zebra_across_the_road(self):
        # Дорога с юга на север шириной 14 м; OSM провёл переход наискось.
        road = (3, 0, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 14.0})
        zebras = build_mvt.fit_zebras([([metres(-12, -9), metres(12, 9)], True)], fitter)
        self.assertEqual(len(zebras), 1)
        (a, b), marked = zebras[0]
        self.assertTrue(marked)
        self.assertAlmostEqual(self._metres_between(a, b), 14.0 - 2 * build_mvt.ZEBRA_EDGE_INSET_METERS, delta=0.1)
        # Поперёк оси: концы на одной широте, по разные стороны оси.
        self.assertAlmostEqual(a[1], b[1], places=7)
        self.assertLess(a[0], metres(0, 0)[0])
        self.assertGreater(b[0], metres(0, 0)[0])

    def test_dual_carriageway_gets_two_zebras_with_a_gap(self):
        west = (3, build_mvt.FLAG_ONEWAY, [metres(-6, -100), metres(-6, 100)], "Навои")
        east = (3, build_mvt.FLAG_ONEWAY, [metres(6, 100), metres(6, -100)], "Навои")
        fitter = build_mvt.ZebraFitter([west, east], {id(west): 8.0, id(east): 8.0})
        zebras = build_mvt.fit_zebras([([metres(-15, 0), metres(15, 0)], True)], fitter)
        self.assertEqual(len(zebras), 2)
        # Между зебрами — разделительная: ни одна не заходит на середину.
        for (a, b), _marked in zebras:
            self.assertGreater(min(abs(a[0] - metres(0, 0)[0]), abs(b[0] - metres(0, 0)[0])) * 83_000, 1.5)

    def test_diagonal_crossing_of_a_dual_carriageway_is_one_straight_zebra(self):
        west = (3, build_mvt.FLAG_ONEWAY, [metres(-6, -100), metres(-6, 100)], "Беруни")
        east = (3, build_mvt.FLAG_ONEWAY, [metres(6, 100), metres(6, -100)], "Беруни")
        fitter = build_mvt.ZebraFitter([west, east], {id(west): 8.0, id(east): 8.0})
        zebras = build_mvt.fit_zebras([([metres(-15, -6), metres(15, 6)], True)], fitter)
        self.assertEqual(len(zebras), 2)
        lats = {round(p[1], 7) for (a, b), _m in zebras for p in (a, b)}
        self.assertEqual(len(lats), 1)                     # обе на одной поперечной

    def test_crossing_ending_on_the_median_reaches_the_other_carriageway(self):
        west = (3, build_mvt.FLAG_ONEWAY, [metres(-6, -100), metres(-6, 100)], "Navoiy")
        east = (3, build_mvt.FLAG_ONEWAY, [metres(6, 100), metres(6, -100)], "Navoiy")
        side = (3, build_mvt.FLAG_ONEWAY, [metres(40, -100), metres(40, 100)], "Other")
        fitter = build_mvt.ZebraFitter([west, east, side], {id(west): 8.0, id(east): 8.0, id(side): 8.0})
        zebras = build_mvt.fit_zebras([([metres(-15, 0), metres(0, 0)], True)], fitter)
        self.assertEqual(len(zebras), 2)                    # обе ленты Навои, не чужая

    def test_two_crossings_on_one_approach_are_one_zebra(self):
        road = (3, 0, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 10.0})
        zebras = build_mvt.fit_zebras([([metres(-8, 0), metres(8, 0)], False),
                                       ([metres(-8, 4), metres(8, 4)], True)], fitter)
        self.assertEqual(len(zebras), 1)
        self.assertTrue(zebras[0][1])           # остаётся размеченный

    def test_crossing_that_misses_every_road_is_not_drawn(self):
        road = (3, 0, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 10.0})
        self.assertEqual(build_mvt.fit_zebras([([metres(20, 0), metres(40, 0)], True)], fitter), [])

    def test_oblique_stop_line_is_squared_to_its_own_carriageway(self):
        road = (3, build_mvt.FLAG_ONEWAY, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 10.0})
        oblique = [metres(-9, -3), metres(7, 4)]                 # через островок, за кромку
        line = build_mvt.fit_stop_line(oblique, 0.0, fitter, {})
        self.assertAlmostEqual(line[0][1], line[1][1], places=7)  # строго поперёк
        self.assertAlmostEqual(self._metres_between(line[0], line[1]), 10.0 - 2 * 0.3, delta=0.1)

    def test_stop_line_stands_before_the_zebra(self):
        road = (3, build_mvt.FLAG_ONEWAY, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 10.0})
        zebras = [([metres(-4.7, 2), metres(4.7, 2)], True)]       # зебра в 2 м за линией
        line = build_mvt.fit_stop_line([metres(-5, 0), metres(5, 0)], 0.0, fitter,
                                       build_mvt.zebra_centre_grid(zebras))
        y = (line[0][1] - metres(0, 0)[1]) * 111_320
        self.assertAlmostEqual(y, 2 - 1.5 - 1.5, delta=0.1)

    def test_stop_line_without_an_axis_is_not_drawn(self):
        road = (3, build_mvt.FLAG_ONEWAY, [metres(0, -100), metres(0, 100)], "Беруни")
        fitter = build_mvt.ZebraFitter([road], {id(road): 10.0})
        self.assertIsNone(build_mvt.fit_stop_line([metres(30, 0), metres(40, 0)], 0.0, fitter, {}))

    def test_two_way_stop_line_covers_only_its_half(self):
        road = (5, 0, [metres(0, -100), metres(0, 100)], "Мукими")
        fitter = build_mvt.ZebraFitter([road], {id(road): 12.0})
        line = build_mvt.fit_stop_line([metres(0.3, 0), metres(6, 0)], 0.0, fitter, {}, True)
        xs = sorted((p[0] - metres(0, 0)[0]) * 111_320 * math.cos(math.radians(p[1])) for p in line)
        self.assertGreater(xs[0], 0.0)                              # правее оси
        self.assertAlmostEqual(xs[1], 6 - 0.3, delta=0.1)

    def test_node_zebra_near_a_crossing_way_is_a_duplicate(self):
        grid = {}
        way = [metres(-10, 0), metres(10, 0)]
        for lon, lat in way:
            grid.setdefault((int(lon / build_mvt._SIGNAL_CELL), int(lat / build_mvt._SIGNAL_CELL)), []).append((lon, lat))
        self.assertTrue(build_mvt._near_crossing_way(metres(-9, 1), grid))
        self.assertFalse(build_mvt._near_crossing_way(metres(0, 60), grid))

    def test_no_waffle_without_enough_signals(self):
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        two = [(1, 0, [metres(45, 8)]), (1, 0, [metres(-45, -8)])]
        far = [(1, 0, [metres(x, y)]) for x, y in ((145, 8), (-145, -8), (8, -145))]
        self.assertIsNone(build_mvt.waffle_zone(box, build_mvt._signal_grid(two)))
        self.assertIsNone(build_mvt.waffle_zone(box, build_mvt._signal_grid(far)))


class FilletTests(unittest.TestCase):
    def cross(self, width=20.0):
        node = metres(0, 0)
        return node, [(node, metres(80, 0), width), (node, metres(0, 80), width),
                      (node, metres(-80, 0), width), (node, metres(0, -80), width)]

    def test_four_corners_of_a_cross_are_rounded(self):
        node, legs = self.cross()
        fillets = list(build_roads.iter_fillets({build_roads._node_key(node): legs}))
        self.assertEqual(len(fillets), 4)
        for kind, flags, ring_ in fillets:
            self.assertEqual(kind, build_roads.AREA_FILLET)
            self.assertTrue(flags & build_roads.FILLET_MAJOR)
            self.assertIsNone(sc.defect_of_kind(kind, ring_))

    def test_fillet_sits_in_the_block_corner_and_is_sized_by_width(self):
        node, legs = self.cross(20.0)
        kind, flags, ring_ = build_roads.fillet_between(node, legs[0], legs[1])
        kx = sc.LAT_METERS * math.cos(math.radians(node[1]))
        rel = [((lon - node[0]) * kx, (lat - node[1]) * sc.LAT_METERS) for lon, lat in ring_]
        # Угол квартала между востоком и севером: кромки в 10 м от осей.
        self.assertAlmostEqual(rel[0][0], 10, delta=0.3)
        self.assertAlmostEqual(rel[0][1], 10, delta=0.3)
        area, _ = sc.area_and_perimeter(rel)
        radius = build_roads.FILLET_RADIUS_MAX
        self.assertAlmostEqual(area, radius ** 2 * (1 - math.pi / 4), delta=4)

    def test_straight_continuation_gets_no_fillet(self):
        node = metres(0, 0)
        self.assertIsNone(build_roads.fillet_between(node, (node, metres(80, 0), 12), (node, metres(-80, 1), 12)))


class LineWidthTests(unittest.TestCase):
    def test_short_wide_piece_is_a_stub(self):
        short = (3, 0, ring((0, 0), (20, 0)), "Olmazor")
        long = (3, 0, ring((0, 0), (200, 0)), "Olmazor")
        self.assertTrue(build_mvt._road_props(short, 17.0).get("stub"))
        self.assertNotIn("stub", build_mvt._road_props(long, 17.0))

    def test_chain_width_overrides_piece_width(self):
        piece = (3, 0, ring((0, 0), (50, 0)), "Navoiy ko'chasi")
        self.assertEqual(build_mvt._road_props(piece, 14.04)["width"], 14.0)
        self.assertNotEqual(build_mvt._road_props(piece)["width"], 14.0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
