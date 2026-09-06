//
//  RouteGeometryTests.swift
//  RadarMapTests
//
//  Геометрия маршрута: коридор камер, проекция прогресса, пройденный префикс, манёвры.
//

import XCTest
import MapKit
@testable import RadarMap

final class RouteGeometryTests: XCTestCase {

    /// Прямой маршрут на восток вдоль широты 41.30: от 69.20 до 69.30 (~8.4 км).
    private var straightRoute: [MKMapPoint] {
        stride(from: 69.20, through: 69.30, by: 0.005).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: $0))
        }
    }

    private func camera(id: Int, lat: Double, lon: Double) -> Camera {
        Camera(id: id, region: "Тест", city: "", location: "тестовая",
               lat: lat, lon: lon, type: "Стационар радар",
               violations: [], needsReview: nil)
    }

    private func bbox(of pts: [MKMapPoint]) -> MKMapRect {
        var rect = MKMapRect.null
        for p in pts { rect = rect.union(MKMapRect(origin: p, size: MKMapSize())) }
        return rect
    }

    func testCamerasAlongFindsOnlyCorridorCameras() {
        let pts = straightRoute
        let cameras = [
            camera(id: 1, lat: 41.3001, lon: 69.25),   // ~11 м от линии — в коридоре
            camera(id: 2, lat: 41.31, lon: 69.25),     // ~1.1 км — мимо
            camera(id: 3, lat: 41.3000, lon: 69.21),   // на линии, ближе к старту
        ]
        let found = RouteService.camerasAlong(pts: pts, bbox: bbox(of: pts),
                                              centerLat: 41.30, cameras: cameras)
        XCTAssertEqual(found.map(\.id), [3, 1], "порядок — по расстоянию от старта")

        // Камера №3 стоит через ~0.01° долготы от старта ≈ 830 м.
        XCTAssertEqual(found[0].distanceAlong, 830, accuracy: 60)
    }

    func testProjectReturnsProgressAndDeviation() {
        let pts = straightRoute
        var hint = 0
        // Точка около середины маршрута, смещена на ~55 м к северу.
        let probe = MKMapPoint(CLLocationCoordinate2D(latitude: 41.3005, longitude: 69.25))
        let (along, deviation) = RouteService.project(probe, onto: pts,
                                                      cum: RouteService.cumulative(of: pts),
                                                      hint: &hint)

        XCTAssertEqual(deviation, 55, accuracy: 10)
        // Пройдено ~половина из ~8.4 км.
        XCTAssertEqual(along, 4180, accuracy: 150)
        XCTAssertGreaterThan(hint, 0, "подсказка сегмента должна сдвинуться к середине")
    }

    /// Кумулятив — то же «пройдено», что и прямое суммирование от нуля: до
    /// него project честно складывал длину на каждом тике (O(позиция) sqrt в
    /// секунду на длинном маршруте — телефон грелся тем сильнее, чем дальше ехал).
    func testCumulativeMatchesDirectSummation() {
        let pts = straightRoute
        let cum = RouteService.cumulative(of: pts)
        XCTAssertEqual(cum.count, pts.count)
        XCTAssertEqual(cum[0], 0)
        var direct = 0.0
        for i in 1..<pts.count {
            direct += pts[i - 1].distance(to: pts[i])
            XCTAssertEqual(cum[i], direct, accuracy: 0.001)
        }
    }

    /// Запрет полного перебора не ломает оценку отклонения: вне окна подсказки
    /// оценка остаётся «далеко» (логике перестроения этого достаточно), а с
    /// разрешённым перебором сегмент находится точно. Маршрут плотный (201
    /// точка): у обычной фикстуры окно hint±40 покрывало всю линию целиком.
    func testProjectHonorsFullScanGate() {
        let pts = stride(from: 69.20, through: 69.30, by: 0.0005).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: $0))
        }
        let cum = RouteService.cumulative(of: pts)
        // Точка на линии у финиша; подсказка у старта — окно её не достаёт.
        let probe = MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: 69.295))
        var hint = 0
        let windowed = RouteService.project(probe, onto: pts, cum: cum,
                                            hint: &hint, allowFullScan: false)
        XCTAssertGreaterThan(windowed.deviation, 200,
                             "без полного перебора отклонение обязано остаться большим")
        var freshHint = 0
        let full = RouteService.project(probe, onto: pts, cum: cum,
                                        hint: &freshHint, allowFullScan: true)
        XCTAssertLessThan(full.deviation, 10, "полный перебор находит настоящий сегмент")
        XCTAssertEqual(full.along, cum[cum.count - 1], accuracy: 600)
    }

    func testTraveledPrefixLength() {
        let pts = straightRoute
        guard let prefix = RouteService.traveledPrefix(points: pts, upTo: 1000) else {
            return XCTFail("префикс на 1 км должен существовать")
        }
        let coords = prefix.points()
        var length = 0.0
        for i in 1..<prefix.pointCount { length += coords[i - 1].distance(to: coords[i]) }
        XCTAssertEqual(length, 1000, accuracy: 5)

        XCTAssertNil(RouteService.traveledPrefix(points: pts, upTo: 30),
                     "первые метры не рисуем — нечего показывать")
    }

    func testManeuverStepMapping() {
        func step(_ type: String, _ modifier: String?, name: String = "", exit: Int? = nil) -> RouteStep? {
            RouteService.maneuverStep(
                RouteService.OSRMResponse.Step(
                    distance: 100, name: name,
                    maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier, exit: exit)),
                at: 500)
        }

        XCTAssertEqual(step("turn", "right")?.icon, "arrow.turn.up.right")
        XCTAssertEqual(step("turn", "left")?.icon, "arrow.turn.up.left")
        XCTAssertEqual(step("roundabout", nil, exit: 2)?.icon, "arrow.triangle.2.circlepath")
        XCTAssertEqual(step("arrive", nil)?.icon, "flag.checkered")
        XCTAssertNil(step("new name", "straight"), "смену названия улицы не озвучиваем")
        XCTAssertNil(step("depart", nil), "старт не озвучиваем")

        // Название улицы попадает в текст манёвра.
        let named = step("turn", "right", name: "Амира Темура")
        XCTAssertTrue(named?.text.contains("Амира Темура") == true)
        XCTAssertEqual(named?.distanceAlong, 500)
    }

    /// `continue` — не поворот.
    ///
    /// Жалоба с дороги: «еду прямо, а он говорит, как будто я направо
    /// повернул». У OSRM continue значит «оставайтесь на своей дороге», и
    /// modifier описывает изгиб самой дороги, а не требуемое действие.
    func testContinueIsNotATurn() {
        func step(_ type: String, _ modifier: String?) -> RouteStep? {
            RouteService.maneuverStep(
                RouteService.OSRMResponse.Step(
                    distance: 100, name: "",
                    maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier,
                                                                 exit: nil)),
                at: 500)
        }

        XCTAssertNil(step("continue", "right"), "изгиб дороги — не команда свернуть")
        XCTAssertNil(step("continue", "left"))
        XCTAssertNil(step("continue", "slight right"))
        XCTAssertNil(step("continue", "straight"))
        // Разворот требует действия, как его ни назови.
        XCTAssertEqual(step("continue", "uturn")?.kind, .uturn)
        // Настоящие повороты не задеты.
        XCTAssertEqual(step("turn", "right")?.icon, "arrow.turn.up.right")
        XCTAssertEqual(step("end of road", "left")?.icon, "arrow.turn.up.left")
    }

    /// За 850 метров объявляем поворот, но не «плавно правее».
    func testOnlyRealManeuversDeserveTheEarlyCall() {
        XCTAssertTrue(ManeuverKind.right.deservesEarlyCall)
        XCTAssertTrue(ManeuverKind.uturn.deservesEarlyCall)
        XCTAssertTrue(ManeuverKind.roundabout.deservesEarlyCall)
        XCTAssertFalse(ManeuverKind.slightRight.deservesEarlyCall)
        XCTAssertFalse(ManeuverKind.straight.deservesEarlyCall)
    }
}
