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

    func testManeuverStepMapping() {
        func step(_ type: String, _ modifier: String?, name: String = "", exit: Int? = nil) -> RouteStep? {
            RouteService.maneuverStep(
                RouteService.OSRMResponse.Step(
                    distance: 100, name: name,
                    maneuver: RouteService.OSRMResponse.Maneuver(type: type, modifier: modifier, exit: exit)),
                at: 500, language: "ru")
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
                at: 500, language: "ru")
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


    // MARK: - Положение на маршруте (plan_algorithms.md, А1)

    /// Маршрут «туда и обратно»: на восток по одной линии, назад по соседней
    /// в двадцати метрах севернее. Городская сетка полна таких мест.
    private var loopRoute: [MKMapPoint] {
        var pts: [MKMapPoint] = []
        for step in 0...10 {
            pts.append(MKMapPoint(CLLocationCoordinate2D(
                latitude: 41.30000, longitude: 69.20 + Double(step) * 0.005)))
        }
        for step in 0...10 {
            pts.append(MKMapPoint(CLLocationCoordinate2D(
                latitude: 41.30018, longitude: 69.25 - Double(step) * 0.005)))
        }
        return pts
    }

    /// Снос GPS в сторону обратной ветки больше не двигает прогресс вперёд.
    ///
    /// Точка в тринадцати метрах от ветки «туда» и в семи от ветки «обратно» —
    /// по одной близости побеждала вторая, и приложение считало, что мы
    /// проехали ещё три километра. Отсюда «говорит про поворот, который я уже
    /// проехал». Курс различает ветки надёжно: обратная идёт нам навстречу.
    func testCourseKeepsProgressOnOurLegOfTheLoop() {
        let pts = loopRoute
        let cum = RouteService.cumulative(of: pts)
        let probe = MKMapPoint(CLLocationCoordinate2D(latitude: 41.30012, longitude: 69.23))

        var hint = 0
        let withCourse = RouteService.project(probe, onto: pts, cum: cum,
                                              hint: &hint, course: 90)
        XCTAssertEqual(withCourse.along, 2509, accuracy: 250,
                       "мы на ветке «туда», примерно 2,5 км от старта")

        var blindHint = 0
        let blind = RouteService.project(probe, onto: pts, cum: cum,
                                         hint: &blindHint, course: -1)
        XCTAssertGreaterThan(blind.along, 5000,
                             "без курса точка садится на обратную ветку — это и был дефект")
    }

    /// Недостоверный курс не двигает прогресс: `-1` означает «не знаем», и
    /// молчание тут лучше догадки — ровно как в гейтах направления у камер.
    func testUnknownCourseAddsNoPenalty() {
        let pts = straightRoute
        let cum = RouteService.cumulative(of: pts)
        let probe = MKMapPoint(CLLocationCoordinate2D(latitude: 41.3005, longitude: 69.25))
        var a = 0, b = 0
        let blind = RouteService.project(probe, onto: pts, cum: cum, hint: &a, course: -1)
        let aligned = RouteService.project(probe, onto: pts, cum: cum, hint: &b, course: 90)
        XCTAssertEqual(blind.along, aligned.along, accuracy: 1)
    }

    /// Стрелка на линии маршрута: точка через N метров и направление сегмента.
    func testPointAndCourseOnRoute() throws {
        let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20)
        let east = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.21)
        let north = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.21)
        let pts = [start, east, north].map(MKMapPoint.init)
        let cum = RouteService.cumulative(of: pts)
        let mid = try XCTUnwrap(RouteService.pointAndCourse(along: cum[1] / 2, pts: pts, cum: cum))
        XCTAssertEqual(mid.coordinate.longitude, 69.205, accuracy: 0.0005)
        XCTAssertEqual(mid.course, 90, accuracy: 1, "первый отрезок — на восток")
        let turn = try XCTUnwrap(RouteService.pointAndCourse(along: cum[1] + 100, pts: pts, cum: cum))
        XCTAssertEqual(turn.course, 0, accuracy: 1, "после поворота — на север")
        let beyond = try XCTUnwrap(RouteService.pointAndCourse(along: cum[2] + 500, pts: pts, cum: cum))
        XCTAssertEqual(beyond.coordinate.latitude, 41.31, accuracy: 0.0001, "за финишем — на финише")
    }

    /// Путь впереди: с сегмента машины и не дальше просимого — не весь
    /// хвост маршрута с начала (аудит энергии 19.10).
    func testPathAheadStartsAtTheCarAndStopsAtTheDistance() {
        // Прямая на восток: точка каждые ~100 м, 5 км.
        let points = (0...50).map { MKMapPoint(CLLocationCoordinate2D(latitude: 41.3,
                                                                     longitude: 69.2 + Double($0) * 0.0012)) }
        let cumulative = RouteService.cumulative(of: points)
        let car = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.2 + 10.5 * 0.0012)
        let path = RouteService.ahead(points, cumulative: cumulative, after: cumulative[10] + 50,
                                      from: car, meters: 600)!
        XCTAssertEqual(path.first!.longitude, car.longitude, accuracy: 1e-9, "начало — машина")
        XCTAssertEqual(path[1].longitude, points[11].coordinate.longitude, accuracy: 1e-9,
                       "следующая точка — конец сегмента машины, не начало маршрута")
        XCTAssertLessThanOrEqual(path.count, 9, "≈600 м по ~100 м — не весь хвост")
        XCTAssertNil(RouteService.ahead(points, cumulative: cumulative, after: cumulative.last! + 10,
                                        from: car, meters: 600), "маршрут кончился")
    }
}
