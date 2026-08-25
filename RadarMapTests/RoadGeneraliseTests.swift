//
//  RoadGeneraliseTests.swift
//  RadarMapTests
//
//  Генерализация сети. Тесты здесь не про красоту, а про то, чего делать
//  НЕЛЬЗЯ: выдумать дорогу, спрятать дорогу неизвестного класса, развернуть
//  одностороннюю против движения, сшить магистраль с двором.
//
//  Файл появился после кадра из симулятора, где схема выглядела спагетти:
//  каждый OSM-way рисовался отдельным штрихом с круглым концом, и город
//  превращался в россыпь обрубков и лесенок парковочных проездов.
//

import CoreGraphics
import XCTest
@testable import RadarMap

final class RoadGeneraliseTests: XCTestCase {

    private func line(_ points: [(Double, Double)], _ kind: RoadClass = .residential,
                      level: Int = 0, oneWay: Bool = false,
                      detailed: Bool = true) -> RoadSketch.Line {
        RoadSketch.Line(points: points.map { CGPoint(x: $0.0, y: $0.1) },
                        kind: kind, level: level, isOneWay: oneWay, isDetailed: detailed)
    }

    // MARK: - Отбор по масштабу

    func testWiderSpanKeepsOnlyTheBackbone() {
        XCTAssertEqual(RoadGeneralise.minimumRank(forSpan: 140, onMinorRoad: false), 8,
                       "на ближнем плане видно всё, включая проезды")
        XCTAssertLessThan(RoadGeneralise.minimumRank(forSpan: 400, onMinorRoad: false),
                          RoadGeneralise.minimumRank(forSpan: 250, onMinorRoad: false))
        XCTAssertEqual(RoadGeneralise.minimumRank(forSpan: 700, onMinorRoad: false), 3,
                       "на охвате района остаётся костяк")
    }

    func testOwnMinorStreetSurvivesAnySpan() {
        // Едем по двору на широком охвате: без поблажки машина ехала бы по
        // пустоте, а схема отвечает ровно на вопрос «где я на своей дороге».
        let wide = RoadGeneralise.minimumRank(forSpan: 700, onMinorRoad: true)
        XCTAssertGreaterThanOrEqual(wide, RoadGeneralise.rank(.residential))
    }

    func testFootpathsAreNeverDrawn() {
        // Тротуар — не проезжая часть. На ближнем плане дорожки вокруг домов
        // давали больше линий, чем все улицы вместе, и схема превращалась в
        // проволочные контуры.
        let path = line([(0, 0), (0, 200)], .pedestrian)
        XCTAssertTrue(RoadGeneralise.apply([path], span: 140, onMinorRoad: true).isEmpty)
        XCTAssertTrue(RoadGeneralise.apply([path], span: 140, onMinorRoad: false).isEmpty)
    }

    func testUnknownClassIsNeverHidden() {
        // Источник без классов (индекс лимитов) отдаёт .unknown. Спрятать
        // дорогу потому, что мы не знаем её класса, — выдать незнание за
        // решение. Тот же запрет, что в оповещениях.
        let unknown = line([(0, 0), (0, 400)], .unknown, detailed: false)
        let kept = RoadGeneralise.apply([unknown], span: 700, onMinorRoad: false)
        XCTAssertEqual(kept.count, 1)
    }

    // MARK: - Склейка

    func testChainOfWaysBecomesOneStreet() {
        let a = line([(0, 0), (0, 100)])
        let b = line([(0, 100), (0, 200)])
        let c = line([(0, 200), (0, 300)])
        let merged = RoadGeneralise.merge([a, b, c])
        XCTAssertEqual(merged.count, 1, "три куска одной улицы — одна ломаная")
        XCTAssertEqual(merged[0].points.count, 4, "стык не дублирует точку")
        XCTAssertEqual(RoadGeneralise.length(merged[0].points), 300, accuracy: 0.01)
    }

    func testDifferentClassesAreNeverMerged() {
        // Магистраль, переходящая в двор, — две разные дороги: они и
        // рисуются разной толщиной и разным тоном.
        let highway = line([(0, 0), (0, 100)], .primary)
        let yard = line([(0, 100), (0, 200)], .service)
        XCTAssertEqual(RoadGeneralise.merge([highway, yard]).count, 2)
    }

    func testBridgeIsNeverMergedWithGround() {
        let ground = line([(0, 0), (0, 100)], .primary)
        let bridge = line([(0, 100), (0, 200)], .primary, level: 1)
        XCTAssertEqual(RoadGeneralise.merge([ground, bridge]).count, 2)
    }

    func testOneWayIsNeverReversed() {
        // Обе линии идут К общей точке (0,100). Развернуть одну, чтобы сшить,
        // значило бы пустить шевроны против движения.
        let a = line([(0, 0), (0, 100)], .primary, oneWay: true)
        let b = line([(0, 200), (0, 100)], .primary, oneWay: true)
        let merged = RoadGeneralise.merge([a, b])
        XCTAssertEqual(merged.count, 2, "односторонние сшиваются только конец-в-начало")
    }

    func testTwoWayMayBeReversedToJoin() {
        let a = line([(0, 0), (0, 100)], .primary)
        let b = line([(0, 200), (0, 100)], .primary)
        XCTAssertEqual(RoadGeneralise.merge([a, b]).count, 1)
    }

    func testHairpinIsNotMerged() {
        // Улица не разворачивается на себя в узле. Склеенная шпилька рисуется
        // штрихом, идущим туда и обратно, — на экране это шип, торчащий из
        // дороги. Ровно он и приехал в симулятор, когда сервер начал склеивать
        // сам.
        let up = line([(0, 0), (0, 200)], .primary)
        let down = line([(1, 0), (1, 200)], .primary)   // рядом, в ту же сторону
        XCTAssertEqual(RoadGeneralise.merge([up, down]).count, 2)
    }

    func testTurnDegreesMeasuresTheBend() {
        XCTAssertEqual(RoadGeneralise.turnDegrees(CGPoint(x: 0, y: 0),
                                                  CGPoint(x: 0, y: 100),
                                                  CGPoint(x: 0, y: 200)), 0, accuracy: 0.01)
        XCTAssertEqual(RoadGeneralise.turnDegrees(CGPoint(x: 0, y: 0),
                                                  CGPoint(x: 0, y: 100),
                                                  CGPoint(x: 100, y: 100)), 90, accuracy: 0.01)
        XCTAssertEqual(RoadGeneralise.turnDegrees(CGPoint(x: 0, y: 0),
                                                  CGPoint(x: 0, y: 100),
                                                  CGPoint(x: 0, y: 0)), 180, accuracy: 0.01)
    }

    func testForkStopsTheChain() {
        // В узле сходятся три конца: продолжение неоднозначно, и выбирать
        // наугад нельзя — улица честно обрывается на перекрёстке.
        let trunk = line([(0, 0), (0, 100)], .primary)
        let left = line([(0, 100), (-100, 200)], .primary)
        let right = line([(0, 100), (100, 200)], .primary)
        XCTAssertEqual(RoadGeneralise.merge([trunk, left, right]).count, 3)
    }

    // MARK: - Обрубки

    func testStubsGoAfterMergingNotBefore() {
        // Пять кусков по двадцать метров — это стометровая улица. Отсев по
        // длине КУСКА убил бы её целиком; отсев после склейки — сохраняет.
        let pieces = (0..<5).map { index in
            line([(0, Double(index) * 20), (0, Double(index + 1) * 20)])
        }
        let kept = RoadGeneralise.apply(pieces, span: 300, onMinorRoad: false)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(RoadGeneralise.length(kept[0].points), 100, accuracy: 0.01)
    }

    func testLoneParkingAisleIsDropped() {
        // Одиночный карман в пятнадцать метров на охвате в триста — шум,
        // из которого и складывалась «гребёнка» на экране.
        let aisle = line([(50, 50), (50, 65)], .service)
        XCTAssertTrue(RoadGeneralise.apply([aisle], span: 300, onMinorRoad: false).isEmpty)
    }

    // MARK: - Упрощение

    func testSimplifyDropsPointsOffTheLine() {
        let noisy = [CGPoint(x: 0, y: 0), CGPoint(x: 0.2, y: 50),
                     CGPoint(x: -0.1, y: 100), CGPoint(x: 0, y: 150)]
        XCTAssertEqual(RoadGeneralise.simplify(noisy, tolerance: 1).count, 2)
    }

    func testSimplifyKeepsRealCorners() {
        // Поворот на девяносто градусов — не шум. Упрощение, съедающее его,
        // рисует машине прямую там, где дорога сворачивает.
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(RoadGeneralise.simplify(corner, tolerance: 1), corner)
    }

    // MARK: - Раздельные проезжие

    private func avenue(x: Double, oneWay: Bool = true,
                        reversed: Bool = false) -> RoadSketch.Line {
        let ys: [Double] = reversed ? [300, 200, 100, 0] : [0, 100, 200, 300]
        return line(ys.map { (x, $0) }, .primary, oneWay: oneWay)
    }

    func testOppositeCarriagewaysCollapseIntoOne() {
        // Проспект в данных — честно две проезжие части. На трёхстах метрах
        // две полосы со встречными шевронами читаются ошибкой рендера.
        let collapsed = RoadGeneralise.collapseDual([avenue(x: 0),
                                                     avenue(x: 18, reversed: true)],
                                                    maxSeparation: 40)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertTrue(collapsed[0].isDual)
        XCTAssertFalse(collapsed[0].isOneWay,
                       "схлопнутая дорога двусторонняя: шевроны на ней были бы ложью")
        XCTAssertEqual(Double(collapsed[0].points[0].x), 9, accuracy: 0.5,
                       "ось идёт посередине между проезжими")
    }

    func testSameDirectionRoadsAreNotCollapsed() {
        // Дублёр, идущий В ТУ ЖЕ сторону, — вторая дорога, а не вторая
        // проезжая часть той же. Схлопнуть её значит стереть съезд.
        let collapsed = RoadGeneralise.collapseDual([avenue(x: 0), avenue(x: 18)],
                                                    maxSeparation: 40)
        XCTAssertEqual(collapsed.count, 2)
    }

    func testFarApartCarriagewaysStaySeparate() {
        let collapsed = RoadGeneralise.collapseDual([avenue(x: 0),
                                                     avenue(x: 120, reversed: true)],
                                                    maxSeparation: 40)
        XCTAssertEqual(collapsed.count, 2)
    }

    func testDifferentClassesAreNotCollapsed() {
        let big = line([(0, 0), (0, 300)], .primary, oneWay: true)
        let small = line([(18, 300), (18, 0)], .service, oneWay: true)
        XCTAssertEqual(RoadGeneralise.collapseDual([big, small], maxSeparation: 40).count, 2)
    }

    func testSplitCarriagewayIsAbsorbedInPieces() {
        // Главный случай, ради которого всё и написано: у двух проезжих
        // частей число ways почти никогда не совпадает — на одной стороне
        // перекрёстков больше. Если ось забирает только один встречный кусок,
        // проспект схлопывается частями: сверху одна дорога, ниже снова две.
        // Непоследовательность на одной улице читается поломкой рендера
        // сильнее, чем сама раздвоенность.
        let back1 = line([(18, 300), (18, 160)], .primary, oneWay: true)
        let back2 = line([(18, 150), (18, 0)], .primary, oneWay: true)
        let collapsed = RoadGeneralise.collapseDual([avenue(x: 0), back1, back2],
                                                    maxSeparation: 40)
        XCTAssertEqual(collapsed.count, 1, "оба встречных куска идут в одну ось")
        XCTAssertTrue(collapsed[0].isDual)
    }

    func testTinyFragmentIsNotAbsorbed() {
        // У обрубка в пятнадцать метров направление определяется шумом
        // координат, и «встречность» становится монеткой.
        let fragment = line([(18, 150), (18, 135)], .primary, oneWay: true)
        XCTAssertEqual(RoadGeneralise.collapseDual([avenue(x: 0), fragment],
                                                   maxSeparation: 40).count, 2)
    }

    func testShortBlockPieceIsAbsorbed() {
        // Кусок между двумя перекрёстками бывает и тридцать метров, а на одной
        // стороне проспекта перекрёстков всегда больше, чем на другой. Порог
        // в сорок метров оставлял проспект схлопнутым справа от перекрёстка и
        // раздвоенным слева — на одной и той же улице.
        let block = line([(18, 150), (18, 118)], .primary, oneWay: true)
        let collapsed = RoadGeneralise.collapseDual([avenue(x: 0), block],
                                                    maxSeparation: 40)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertTrue(collapsed[0].isDual)
    }

    func testSideRoadLeavingTheAxisIsNotAbsorbed() {
        // Съезд идёт вдоль проспекта только вначале, а потом уходит в сторону.
        // Достаточно одной его точки за допуском, чтобы это был уже съезд.
        let ramp = line([(18, 300), (18, 200), (140, 60)], .primary, oneWay: true)
        XCTAssertEqual(RoadGeneralise.collapseDual([avenue(x: 0), ramp],
                                                   maxSeparation: 40).count, 2)
    }

    func testTwoWayRoadsAreLeftAlone() {
        let a = line([(0, 0), (0, 300)], .primary)
        let b = line([(18, 300), (18, 0)], .primary)
        XCTAssertEqual(RoadGeneralise.collapseDual([a, b], maxSeparation: 40).count, 2)
    }

    func testNoCollapseOnCloseSpans() {
        // Вблизи разделительная полоса — реальное препятствие, через которое
        // не перестроиться. Рисовать две проезжие одной линией там нельзя.
        XCTAssertEqual(RoadGeneralise.collapseSeparation(forSpan: 140), 0)
        XCTAssertGreaterThan(RoadGeneralise.collapseSeparation(forSpan: 400), 0)
    }

    func testAxisFadesInsteadOfSteppingSideways() {
        // Встречная проезжая часть покрывает только верх оси. Без затухания
        // ось прыгала бы вбок на половину разноса ровно там, где пара
        // кончилась, — на экране это излом асфальта, а не конец данных.
        let main = (0...12).map { CGPoint(x: 0, y: Double($0) * 25) }   // 0…300
        let back = [CGPoint(x: 20, y: 300), CGPoint(x: 20, y: 200)]
        let axis = RoadGeneralise.collapsedAxis(main, partners: [back],
                                                maxSeparation: 40)
        XCTAssertEqual(axis.count, main.count)
        // Наверху, где пара есть, ось посередине.
        XCTAssertEqual(Double(axis[12].x), 10, accuracy: 1.5)
        // Внизу, далеко за концом пары, ось вернулась на своё место.
        XCTAssertEqual(Double(axis[0].x), 0, accuracy: 0.5)
        // И между ними ни одного скачка больше пары метров на вершину.
        for index in 1..<axis.count {
            XCTAssertLessThan(abs(Double(axis[index].x - axis[index - 1].x)), 6,
                              "ось обязана сходить плавно, а не шагом")
        }
    }

    // MARK: - Готовая сеть с сервера

    func testPrecomputedSkipsGeometryButStillSmooths() {
        // Сеть формата v2 приходит уже склеенной, схлопнутой и упрощённой.
        // Повторять это на телефоне — платить за одно и то же дважды.
        // Сглаживание остаётся: оно удваивает точки, то есть в тайле стоило
        // бы вдвое больше трафика, а считается одним проходом.
        let corner = line([(0, 0), (0, 100), (100, 100)], .primary)
        let result = RoadGeneralise.apply([corner], span: 300,
                                          onMinorRoad: false, precomputed: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertGreaterThan(result[0].points.count, corner.points.count,
                             "сглаживание обязано остаться")
        XCTAssertEqual(result[0].points.first, corner.points.first)
        XCTAssertEqual(result[0].points.last, corner.points.last)
    }

    func testPrecomputedDoesNotDropShortRoads() {
        // Отсев обрубков сделан на сервере по ВСЕЙ сети. Повторный отсев на
        // телефоне выбросил бы куски, которые сервер сознательно оставил, —
        // например короткую улицу между двумя перекрёстками.
        let short = line([(0, 0), (0, 25)], .residential)
        XCTAssertEqual(RoadGeneralise.apply([short], span: 300,
                                            onMinorRoad: false, precomputed: true).count, 1)
        XCTAssertTrue(RoadGeneralise.apply([short], span: 300,
                                           onMinorRoad: false).isEmpty)
    }

    func testPrecomputedStillHidesFootpaths() {
        // Запрет на тротуары — не оптимизация, а правило: это не проезжая
        // часть. Он действует и на готовой сети.
        let path = line([(0, 0), (0, 300)], .pedestrian)
        XCTAssertTrue(RoadGeneralise.apply([path], span: 140,
                                           onMinorRoad: true, precomputed: true).isEmpty)
    }

    // MARK: - Сглаживание

    func testSmoothKeepsEnds() {
        // Концы лежат в узлах, общих с соседними улицами. Сдвинуть их значит
        // расцепить перекрёсток — на экране это дыра в дороге.
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
        let smoothed = RoadGeneralise.smooth(corner)
        XCTAssertEqual(smoothed.first, corner.first)
        XCTAssertEqual(smoothed.last, corner.last)
    }

    func testSmoothRoundsTheCorner() {
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
        let smoothed = RoadGeneralise.smooth(corner)
        XCTAssertFalse(smoothed.contains(CGPoint(x: 0, y: 100)),
                       "острый угол обязан исчезнуть — у дороги есть радиус")
        XCTAssertGreaterThan(smoothed.count, corner.count)
    }

    func testSmoothLeavesStraightLineAlone() {
        // Прямая после сглаживания обязана остаться прямой: точек больше,
        // но ни одна не сходит с оси.
        let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 100)]
        for point in RoadGeneralise.smooth(straight) {
            XCTAssertEqual(Double(point.x), 0, accuracy: 0.001)
        }
    }

    func testSmoothIgnoresTwoPointLines() {
        let segment = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)]
        XCTAssertEqual(RoadGeneralise.smooth(segment), segment)
    }

    func testSimplifyKeepsEnds() {
        let points = (0...20).map { CGPoint(x: 0, y: Double($0) * 10) }
        let simplified = RoadGeneralise.simplify(points, tolerance: 1)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)
    }
}
