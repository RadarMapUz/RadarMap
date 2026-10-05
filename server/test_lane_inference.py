"""Тесты угадывания полос по соседям (lane_inference) и его места в сборке."""
import math
import unittest

import build_mvt
import build_roads
import lane_inference

LAT, LON = 41.311, 69.28
KX = 111_320 * math.cos(math.radians(LAT))


def line(x0, x1, y=0.0):
    return [(LON + x0 / KX, LAT + y / 111_320), (LON + x1 / KX, LAT + y / 111_320)]


def road(x0, x1, lanes=0, code=3, oneway=True, name="Navoiy ko'chasi", y=0.0):
    flags = build_roads.FLAG_ONEWAY if oneway else 0
    if lanes:
        flags = build_roads.with_lanes(flags, lanes) | build_roads.FLAG_LANES_TAGGED
    return (code, flags, line(x0, x1, y), name)


ARGS = (build_roads.lanes_of,
        lambda f: f & build_roads.FLAG_LANES_TAGGED,
        lambda f: f & build_roads.FLAG_ONEWAY)


class InferTests(unittest.TestCase):
    def test_gap_in_a_tagged_street_is_filled(self):
        # Улица размечена до и после — середина без тега получает те же 4.
        roads = [road(0, 300, 4), road(300, 500), road(500, 900, 4)]
        guessed = lane_inference.infer_lanes(roads, *ARGS)
        self.assertEqual(guessed[id(roads[1])][0], 4)

    def test_split_votes_are_not_guessed(self):
        # Соседи спорят (3 и 5 поровну) — уверенности нет, пунктира нет.
        roads = [road(0, 300, 3), road(300, 500), road(500, 800, 5)]
        self.assertNotIn(id(roads[1]), lane_inference.infer_lanes(roads, *ARGS))

    def test_direction_must_match(self):
        # Полосы двусторонней улицы — не полосы односторонней ленты.
        roads = [road(0, 300, 4, oneway=False), road(300, 500, oneway=True)]
        self.assertEqual(lane_inference.infer_lanes(roads, *ARGS), {})

    def test_other_class_does_not_vote_unless_same_street(self):
        roads = [road(0, 300, 2, code=5, name="Boshqa"), road(300, 500, code=3)]
        self.assertEqual(lane_inference.infer_lanes(roads, *ARGS), {})

    def test_far_neighbours_do_not_vote(self):
        roads = [road(0, 300, 4), road(3000, 3300)]
        self.assertEqual(lane_inference.infer_lanes(roads, *ARGS), {})

    def test_measured_width_must_fit(self):
        roads = [road(0, 300, 4), road(300, 500), road(500, 900, 4)]
        narrow = {id(roads[1]): 7.0}         # 4 полосы в 7 м не помещаются
        self.assertNotIn(id(roads[1]), lane_inference.infer_lanes(roads, *ARGS, narrow))


class PipelineTests(unittest.TestCase):
    def test_inferred_lanes_are_flagged_apart_from_tags(self):
        roads = [road(0, 300, 4), road(300, 500), road(500, 900, 4)]
        out, count = build_roads.apply_lane_inference(roads)
        self.assertEqual(count, 1)
        flags = out[1][1]
        self.assertEqual(build_roads.lanes_of(flags), 4)
        self.assertTrue(flags & build_roads.FLAG_LANES_INFERRED)
        self.assertFalse(flags & build_roads.FLAG_LANES_TAGGED, "очередь панели видит «OSM молчит»")

    def test_short_unnamed_link_gets_two_lanes(self):
        # Перемычка у перекрёстка по классу получала 6 полос и кляксу узла.
        link = (3, 0, line(0, 40), "")
        out, count = build_roads.apply_lane_inference([link])
        self.assertEqual(count, 1)
        self.assertEqual(build_roads.lanes_of(out[0][1]), 2)
        long_road = (3, 0, line(0, 400), "")
        out, count = build_roads.apply_lane_inference([long_road])
        self.assertEqual(count, 0, "длинная безымянная — не связка")

    def test_hand_drawn_roads_are_left_alone(self):
        hand = (3, build_roads.FLAG_ONEWAY | build_roads.FLAG_HAND_DRAWN, line(300, 500), "Navoiy ko'chasi")
        roads = [road(0, 300, 4), hand, road(500, 900, 4)]
        out, count = build_roads.apply_lane_inference(roads)
        self.assertEqual(count, 0)
        self.assertIs(out[1], hand)

    def test_inferred_lanes_get_dashes_but_never_a_solid_centre(self):
        flags = build_roads.with_lanes(0, 4) | build_roads.FLAG_LANES_INFERRED
        two_way = (3, flags, line(0, 400), "Navoiy ko'chasi")
        (_line, centre), = build_mvt.centre_lines([two_way])
        self.assertEqual(centre, build_mvt.CENTRE_DASHED, "сплошная — только по подтверждённым")
        self.assertEqual(len(list(build_mvt.lane_markings([two_way]))), 2)
        oneway = (3, build_roads.FLAG_ONEWAY | build_roads.with_lanes(0, 3) | build_roads.FLAG_LANES_INFERRED,
                  line(0, 400), "Navoiy ko'chasi")
        self.assertEqual(len(list(build_mvt.lane_markings([oneway]))), 2)


if __name__ == "__main__":
    unittest.main()
