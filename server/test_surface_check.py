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

    def test_waffle_is_the_zone_between_the_signals(self):
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        # Светофоры у стоп-линий четырёх подходов, в ~38 м от центра.
        signals = [(1, 0, [metres(x, y)]) for x, y in ((38, 8), (-38, -8), (8, -38), (-8, 38))]
        zone = build_mvt.waffle_zone(box, build_mvt._signal_grid(signals))
        self.assertIsNotNone(zone)
        area, _ = sc.area_and_perimeter(sc.to_meters(zone))
        self.assertGreater(area, 1500, "зона — весь перекрёсток между стоп-линиями, а не центр осей")
        self.assertIsNone(sc.defect(zone))

    def test_elongated_signal_set_is_not_a_junction(self):
        # Навои × Фурката: светофоры эстакады и съездов дали вытянутый треугольник.
        box = ring((-6, -6), (6, -6), (6, 6), (-6, 6))
        thin = [(1, 0, [metres(x, y)]) for x, y in ((-40, 2), (40, -2), (10, 6))]
        self.assertIsNone(build_mvt.waffle_zone(box, build_mvt._signal_grid(thin)))

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
