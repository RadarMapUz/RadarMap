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

    // MARK: - Стрелка на линии и перестроение по курсу (снимок CarPlay 21.10)

    /// Стрелка садится на линию маршрута, только пока курс с ней согласен.
    /// Перестроение дало маршрут «назад» (линия на восток, машина — на
    /// запад): стрелка на линии смотрела назад, и карта разворачивалась на
    /// 180° на три фикса. Свернул мимо под прямым углом — тоже не на линии.
    func testRouteSnapRequiresAgreeingCourse() {
        let point = CLLocationCoordinate2D(latitude: 41.305, longitude: 69.245)
        let snap = (coordinate: point, course: 96.0)
        XCTAssertNotNil(RouteService.displaySnap(deviation: 8, on: snap, course: 100), "едем по линии")
        XCTAssertNotNil(RouteService.displaySnap(deviation: 8, on: snap, course: -1),
                        "курс неизвестен — линия лучше, чем ничего")
        XCTAssertNil(RouteService.displaySnap(deviation: 8, on: snap, course: 270), "маршрут «назад»")
        XCTAssertNil(RouteService.displaySnap(deviation: 12, on: (point, 142), course: 233),
                     "свернул мимо под прямым углом (прогон: 142° против 233°)")
        XCTAssertNotNil(RouteService.displaySnap(deviation: 12, on: (point, 142), course: 190),
                        "запаздывание курса в повороте по маршруту — ещё на линии")
        XCTAssertNil(RouteService.displaySnap(deviation: 30, on: snap, course: 96), "дальше 25 м")
        XCTAssertNil(RouteService.displaySnap(deviation: 8, on: nil, course: 96))
        // Через север: 355° и 10° — одно направление.
        XCTAssertNotNil(RouteService.displaySnap(deviation: 5, on: (point, 355), course: 10))
    }

    /// Перестроение на ходу просит OSRM начать маршрут по курсу машины; без
    /// курса запрос прежний.
    func testRerouteAsksOSRMToStartAlongOurCourse() {
        func value(_ items: [URLQueryItem], _ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let plain = RouteService.osrmQueryItems(alternatives: false, heading: nil, waypoints: 2)
        XCTAssertNil(value(plain, "bearings"))
        XCTAssertNil(value(plain, "radiuses"))
        XCTAssertEqual(value(plain, "steps"), "true")
        let range = AppConfig.rerouteBearingRangeDegrees, radius = AppConfig.rerouteBearingRadiusMeters
        let west = RouteService.osrmQueryItems(alternatives: false, heading: 270.4, waypoints: 2)
        XCTAssertEqual(value(west, "bearings"), "270,\(range);")
        XCTAssertEqual(value(west, "radiuses"), "\(radius);unlimited")
        let viaStop = RouteService.osrmQueryItems(alternatives: false, heading: 359.7, waypoints: 3)
        XCTAssertEqual(value(viaStop, "bearings"), "0,\(range);;", "360° — это 0°, остановке курса нет")
        XCTAssertEqual(value(viaStop, "radiuses"), "\(radius);unlimited;unlimited")
        XCTAssertNil(value(RouteService.osrmQueryItems(alternatives: false, heading: -1, waypoints: 2), "bearings"))
    }

    // MARK: - Ход навстречу маршруту и курс первого маршрута (20.9)

    /// Градусов долготы на метр на широте 41.30.
    private let lonPerMeter = 1 / (111_320 * cos(41.30 * .pi / 180))

    /// Фикс машины: где, курс (достоверный, −1 — нет), скорость.
    private struct Fix {
        let coordinate: CLLocationCoordinate2D
        let course: CLLocationDirection
        let speedKmh: Double
    }

    /// Прогон фиксов той же цепочкой, что RouteService.updateProgress:
    /// проекция с курсом и подсказкой сегмента → ветка, которую она выбрала
    /// (`hint` после project) → RerouteGate со всеми тремя правилами.
    /// Индексы фиксов, на которых пора перестраивать, и худшее отклонение.
    private func drive(_ fixes: [Fix], on pts: [MKMapPoint],
                       gate: inout RerouteGate) -> (rebuilds: [Int], maxDeviation: Double) {
        let cum = RouteService.cumulative(of: pts)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var hint = 0
        var rebuilds: [Int] = []
        var maxDeviation = 0.0
        for (index, fix) in fixes.enumerated() {
            let (along, deviation) = RouteService.project(MKMapPoint(fix.coordinate), onto: pts, cum: cum,
                                                          hint: &hint,
                                                          allowFullScan: gate.offRouteTicks % 3 == 0,
                                                          course: fix.course)
            maxDeviation = max(maxDeviation, deviation)
            let heading = RouteService.routeHeading(along: along, segment: hint, pts: pts,
                                                    course: fix.course, speedKmh: fix.speedKmh)
            if gate.note(deviation: deviation, now: t0.addingTimeInterval(Double(index)),
                         drift: RerouteGate.driftLimit(accuracy: nil), heading: heading) {
                rebuilds.append(index)
            }
        }
        return (rebuilds, maxDeviation)
    }

    /// Фиксы по прямой вдоль широты `lat`: от долготы `lon` шагами `step`
    /// метров (минус — на запад), курс `course`, 43 км/ч (12 м за фикс).
    private func leg(lat: Double, lon: Double, step: Double, count: Int,
                     course: CLLocationDirection) -> [Fix] {
        (0..<count).map {
            Fix(coordinate: CLLocationCoordinate2D(latitude: lat,
                                                   longitude: lon + Double($0) * step * lonPerMeter),
                course: course, speedKmh: 43)
        }
    }

    /// Развернулись на той же улице и едем назад по встречной стороне (11 м
    /// от линии): отклонение никогда не дойдёт ни до 150, ни до 50 м, и
    /// прежде маршрут вёл назад до самой цели. Теперь — перестроение на
    /// четвёртом фиксе навстречу.
    func testUTurnOnTheRouteStreetRebuilds() {
        let pts = straightRoute
        let east = leg(lat: 41.30, lon: 69.21, step: 12, count: 40, course: 90)
        let turn = Fix(coordinate: CLLocationCoordinate2D(latitude: 41.30005,
                                                          longitude: east.last!.coordinate.longitude),
                       course: 0, speedKmh: 15)
        let west = leg(lat: 41.30010, lon: east.last!.coordinate.longitude, step: -12, count: 12, course: 270)
        var gate = RerouteGate()
        let run = drive(east + [turn] + west, on: pts, gate: &gate)
        XCTAssertEqual(run.rebuilds, [east.count + 1 + AppConfig.rerouteWrongWayTicks - 1],
                       "четвёртый фикс навстречу")
        XCTAssertLessThan(run.maxDeviation, 15, "на линии: правила отклонения тут слепы")

        var blind = RerouteGate()
        let cum = RouteService.cumulative(of: pts)
        var hint = 0
        let old = (east + [turn] + west).enumerated().filter { index, fix in
            let (_, deviation) = RouteService.project(MKMapPoint(fix.coordinate), onto: pts, cum: cum,
                                                      hint: &hint, course: fix.course)
            return blind.note(deviation: deviation, now: Date(timeIntervalSince1970: Double(index)),
                              drift: RerouteGate.driftLimit(accuracy: nil))
        }
        XCTAssertTrue(old.isEmpty, "без правила 20.9 — никогда")
    }

    /// Прямая трассы, узлы через 418 м: окно проекции вперёд считалось от
    /// НАЧАЛА сегмента подсказки, и сегмент длиннее окна не пускал в него
    /// следующий — за каждым узлом отклонение росло до 200 м, и снос 20.6
    /// перестраивал маршрут на ровной дороге. 100 км/ч, 3 км — ни одного
    /// перестроения, машина на линии.
    func testLongStraightSegmentsKeepTheCarOnTheLine() {
        let fixes = (0..<110).map {
            Fix(coordinate: CLLocationCoordinate2D(latitude: 41.30001,
                                                   longitude: 69.2001 + Double($0) * 28 * lonPerMeter),
                course: 90, speedKmh: 100)
        }
        var gate = RerouteGate()
        let run = drive(fixes, on: straightRoute, gate: &gate)
        XCTAssertEqual(run.rebuilds, [])
        XCTAssertLessThan(run.maxDeviation, 3, "за узлом — следующий сегмент, а не конец прошлого")
        XCTAssertEqual(gate.driftTicks, 0)
    }

    /// Маршрут «туда и обратно» по одной и той же линии (развернуться в конце
    /// улицы и вернуться): обратная ветка совпадает с прямой, и ехать по ней
    /// на запад законно. Проекция с курсом выбирает попутную ветку — правило,
    /// глядящее на её сегмент, молчит всю дорогу.
    func testOutAndBackRouteOnTheSameStreetDoesNotRebuild() {
        let out = (0...10).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20 + Double($0) * 0.001))
        }
        let pts = out + out.reversed().dropFirst()
        let length = 0.01 / lonPerMeter
        let count = Int(length / 12)
        let east = leg(lat: 41.30002, lon: 69.20, step: 12, count: count, course: 90)
        // Разворот в конце: курс отстаёт на фикс, потом — на запад.
        let turn = [Fix(coordinate: CLLocationCoordinate2D(latitude: 41.30003, longitude: 69.21),
                        course: 90, speedKmh: 12),
                    Fix(coordinate: CLLocationCoordinate2D(latitude: 41.29999, longitude: 69.21),
                        course: 180, speedKmh: 12)]
        let west = leg(lat: 41.29998, lon: 69.21, step: -12, count: count - 2, course: 270)
        var gate = RerouteGate()
        let run = drive(east + turn + west, on: pts, gate: &gate)
        XCTAssertEqual(run.rebuilds, [], "обратная ветка маршрута попутна")
        XCTAssertEqual(gate.wrongWayTicks, 0)

        // Та же петля, но развернулись на полпути: обратная ветка здесь —
        // через километр по маршруту, проекция остаётся на прямой, и мы
        // едем ей навстречу — перестроение.
        var early = RerouteGate()
        let half = Array(east.prefix(count / 2))
        let back = leg(lat: 41.29998, lon: half.last!.coordinate.longitude, step: -12, count: 10, course: 270)
        XCTAssertEqual(drive(half + back, on: pts, gate: &early).rebuilds,
                       [half.count + AppConfig.rerouteWrongWayTicks - 1])
    }

    /// Петля, возвращающаяся по соседней проезжей части (loopRoute: туда по
    /// 41.30000, обратно по 41.30018): весь круг по маршруту — ни одного
    /// перестроения.
    func testLoopRouteDrivenAsPlannedNeverRebuilds() {
        let pts = loopRoute
        let length = 0.05 / lonPerMeter
        let count = Int(length / 12)
        let east = leg(lat: 41.30001, lon: 69.20, step: 12, count: count, course: 90)
        let connector = [Fix(coordinate: CLLocationCoordinate2D(latitude: 41.30009, longitude: 69.2501),
                             course: 0, speedKmh: 15)]
        let west = leg(lat: 41.30017, lon: 69.25, step: -12, count: count - 1, course: 270)
        var gate = RerouteGate()
        let run = drive(east + connector + west, on: pts, gate: &gate)
        XCTAssertEqual(run.rebuilds, [])
        XCTAssertLessThan(run.maxDeviation, 15)
    }

    /// Стоим на маршруте: приёмник гуляет ±10 м, курс выдержан против линии,
    /// но скорость — шум 0–6 км/ч. Ни одного перестроения.
    func testStandingNoiseOnTheRouteNeverRebuilds() {
        let pts = straightRoute
        let jitter: [(Double, Double)] = [(0, 0), (-8, 3), (6, -4), (-10, 2), (9, 5), (-3, -6)]
        let fixes = (0..<90).map { tick -> Fix in
            let (dx, dy) = jitter[tick % jitter.count]
            return Fix(coordinate: CLLocationCoordinate2D(latitude: 41.30 + dy / 111_320,
                                                          longitude: 69.25 + dx * lonPerMeter),
                       course: 270, speedKmh: Double(tick % 7))
        }
        var gate = RerouteGate()
        XCTAssertEqual(drive(fixes, on: pts, gate: &gate).rebuilds, [])
        XCTAssertEqual(gate.wrongWayTicks, 0)
    }

    /// Направление ветки — с сегмента проекции; повтор точки (сегмент
    /// нулевой длины) берёт соседний, за краем маршрута — nil.
    func testSegmentCourseOfThePickedBranch() throws {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: 41.30, longitude: 69.21))
        let c = MKMapPoint(CLLocationCoordinate2D(latitude: 41.31, longitude: 69.21))
        XCTAssertEqual(try XCTUnwrap(RouteService.segmentCourse([a, b, c], at: 0)), 90, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(RouteService.segmentCourse([a, b, c], at: 1)), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(RouteService.segmentCourse([c, b, a], at: 1)), 270, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(RouteService.segmentCourse([a, b, b, c], at: 1)), 0, accuracy: 0.5,
                       "повтор точки — следующий сегмент")
        XCTAssertEqual(try XCTUnwrap(RouteService.segmentCourse([a, b, b], at: 1)), 90, accuracy: 0.5,
                       "повтор в конце — предыдущий")
        XCTAssertNil(RouteService.segmentCourse([a, b], at: 1))
        XCTAssertNil(RouteService.segmentCourse([a, a], at: 0))
        XCTAssertNil(RouteService.segmentCourse([a, b], at: -1))
    }

    /// Первый маршрут на ходу просит OSRM начать по курсу машины; стоя или
    /// без достоверного курса — запрос прежний, без `bearings`.
    func testFirstRouteSendsHeadingOnlyWhenMovingWithTrustedCourse() {
        func bearings(course: CLLocationDirection, speedKmh: Double, alternatives: Bool = true) -> String? {
            RouteService.osrmQueryItems(alternatives: alternatives,
                                        heading: RouteService.requestHeading(course: course, speedKmh: speedKmh),
                                        waypoints: 2)
                .first { $0.name == "bearings" }?.value
        }
        let range = AppConfig.rerouteBearingRangeDegrees
        XCTAssertEqual(bearings(course: 87.6, speedKmh: 40), "88,\(range);", "едем — по курсу")
        XCTAssertEqual(bearings(course: 90, speedKmh: AppConfig.directionalMinSpeedKmh), "90,\(range);")
        XCTAssertNil(bearings(course: 90, speedKmh: AppConfig.directionalMinSpeedKmh - 0.1),
                     "ползём — водитель может поехать в любую сторону")
        XCTAssertNil(bearings(course: 90, speedKmh: 0), "стоим у светофора с выдержанным курсом")
        XCTAssertNil(bearings(course: -1, speedKmh: 60), "курса нет")
        XCTAssertNil(bearings(course: .nan, speedKmh: 60))
        let items = RouteService.osrmQueryItems(alternatives: true,
                                                heading: RouteService.requestHeading(course: 200, speedKmh: 50),
                                                waypoints: 2)
        XCTAssertEqual(items.first { $0.name == "alternatives" }?.value, "true", "варианты — и с курсом")
        XCTAssertEqual(items.first { $0.name == "radiuses" }?.value,
                       "\(AppConfig.rerouteBearingRadiusMeters);unlimited")
    }

    /// Запрос по курсу не дошёл до сервера — без повтора (второй ждал бы
    /// тот же таймаут); сервер отказал (NoSegment, 4xx/5xx) — повтор без курса.
    func testHeadingRetryOnlyAfterAServerAnswer() {
        XCTAssertFalse(RouteService.retriesWithoutHeading(after: RouteService.RouteError.noConnection))
        XCTAssertTrue(RouteService.retriesWithoutHeading(after: RouteService.RouteError.serverUnreachable))
        XCTAssertTrue(RouteService.retriesWithoutHeading(after: RouteService.RouteError.noRoute))
        XCTAssertTrue(RouteService.retriesWithoutHeading(after: URLError(.badServerResponse)))
    }
}
