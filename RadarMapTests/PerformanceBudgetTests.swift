//
//  PerformanceBudgetTests.swift
//  RadarMapTests
//
//  Бюджеты горячих функций: падение производительности ловится до релиза,
//  а не на дороге. Потолки заведомо щедрые (симулятор на CI медленнее железа
//  и шумит) — они ловят не деградацию на проценты, а регресс в разы: возврат
//  квадратичного перебора, случайный расчёт на каждый тик и т.п.
//
//  Замеряем чистую работу через ContinuousClock, а не XCTest measure:
//  функции async (@concurrent), а measure с async не дружит.
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class PerformanceBudgetTests: XCTestCase {

    /// ~3400 камер по сетке вокруг Ташкента — размер боевой базы.
    private func syntheticCameras(_ count: Int = 3400) -> [Camera] {
        (0..<count).map { index in
            Camera(id: index, region: "Ташкент", city: "Ташкент",
                   location: "Улица \(index)",
                   lat: 41.20 + Double(index % 60) * 0.005,
                   lon: 69.10 + Double(index / 60) * 0.005,
                   type: index % 3 == 0 ? "Стационар радар" : "Стационар камера",
                   violations: [], needsReview: nil)
        }
    }

    /// Слой маркеров для города: перебор всей базы + кластеризация.
    /// До @concurrent-фикса это выполнялось на main при каждом сдвиге карты.
    func testCameraLayerBudget() async {
        let cameras = syntheticCameras()
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35))

        let clock = ContinuousClock()
        var total: Duration = .zero
        for _ in 0..<10 {
            let start = clock.now
            _ = await CameraMapContent.layer(cameras: cameras, region: region,
                                             filter: .all, budget: 220)
            total += clock.now - start
        }
        // 10 пересборок слоя всей городской области — суммарно меньше секунды.
        XCTAssertLessThan(total, .seconds(1),
                          "слой маркеров деградировал: \(total) на 10 пересборок")
    }

    /// Слой частоты («тепло») недельных треков Итогов.
    func testHeatLinesBudget() async {
        // Неделя езды: 12 поездок по 400 точек, три общих коридора.
        let tracks: [[TrackPoint]] = (0..<12).map { trip in
            let corridor = Double(trip % 3) * 0.01
            return (0..<400).map { step in
                TrackPoint(lat: 41.30 + corridor + Double(step % 5) * 0.0001,
                           lon: 69.20 + Double(step) * 0.0004,
                           speedKmh: 50)
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        _ = await TripHistory.heatLines(tracks)
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(1),
                          "слой частоты деградировал: \(elapsed)")
    }

    /// Разбор рейтинга за месяц: вклады, камеры, норма по восьми прошлым окнам.
    /// Считается на открытие экрана и на смену периода; если он уедет обратно
    /// в body, экран начнёт пересчитывать всё это на каждый кадр прокрутки.
    func testRatingScreenBudget() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Полгода езды: хватает и на месяц разбора, и на восемь окон нормы.
        let history: [TripRecord] = (0..<50).map { index in
            let start = now.addingTimeInterval(Double(-index) * 3600 * 24)
            let passes: [PassedCamera] = (0..<8).map { p in
                PassedCamera(id: UUID(), cameraID: p, typeRaw: "Стационар радар",
                             location: "Юнусабад", speedKmh: 70 + Double(p),
                             date: start, lat: 41.3, lon: 69.2, limitKmh: 60)
            }
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1800),
                              distanceMeters: 12_000, maxSpeedKmh: 90,
                              passed: passes, score: 72)
        }
        let days = TripDayBook.rebuilt(from: history)

        let clock = ContinuousClock()
        var total: Duration = .zero
        for _ in 0..<10 {
            let start = clock.now
            _ = await RatingBreakdown.screen(records: history, days: days,
                                             period: .month, anchor: now)
            total += clock.now - start
        }
        XCTAssertLessThan(total, .milliseconds(500),
                          "разбор рейтинга деградировал: \(total) на 10 пересчётов")
    }

    /// Сводка периода по полной истории (50 записей с проездами).
    /// Считается при каждом пересчёте body Итогов — обязана быть мгновенной.
    func testPeriodSummaryBudget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history: [TripRecord] = (0..<50).map { index in
            let start = now.addingTimeInterval(Double(-index) * 3600 * 5)
            let passes: [PassedCamera] = (0..<6).map { p in
                PassedCamera(id: UUID(), cameraID: index * 10 + p,
                             typeRaw: "Стационар радар", location: "Юнусабад",
                             speedKmh: 70, date: start, lat: 41.3, lon: 69.2,
                             limitKmh: 60)
            }
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1800),
                              distanceMeters: 12_000, maxSpeedKmh: 90,
                              passed: passes, score: 80)
        }

        let clock = ContinuousClock()
        var total: Duration = .zero
        for _ in 0..<50 {
            let start = clock.now
            _ = TripHistory.summary(history, period: .month, now: now)
            total += clock.now - start
        }
        // 50 пересчётов сводки месяца — суммарно меньше полсекунды.
        XCTAssertLessThan(total, .milliseconds(500),
                          "сводка периода деградировала: \(total) на 50 пересчётов")
    }

    // MARK: - Схема на приборке

    /// Плотная городская сетка улиц через ~110 м: 200 сегментов, 20 200 точек —
    /// гуще реального центра Ташкента. Собирается боевым `LimitIndex.build`,
    /// то есть замер включает и сеточный запрос `roads(near:)`.
    private func syntheticRoadNetwork() -> LimitIndex {
        var segments: [[Any]] = []
        for i in 0..<100 {
            let lat = 41.26 + Double(i) * 0.001
            var flat: [Double] = []
            for j in 0...100 { flat.append(lat); flat.append(69.20 + Double(j) * 0.001) }
            segments.append([60, flat])
        }
        for j in 0..<100 {
            let lon = 69.20 + Double(j) * 0.001
            var flat: [Double] = []
            for i in 0...100 { flat.append(41.26 + Double(i) * 0.001); flat.append(lon) }
            segments.append([60, flat])
        }
        let data = try! JSONSerialization.data(withJSONObject: ["segments": segments])
        return LimitIndex.build(from: data)!
    }

    // MARK: - Лимит дороги

    /// Сеть по статистике БОЕВОГО файла, а не по худшему случаю.
    ///
    /// `syntheticRoadNetwork()` выше нарочно гуще реальности: он проверяет
    /// `roads(near:)` под нагрузкой. Для `match` такая сеть врёт в другую
    /// сторону — её сегменты тянутся через всю область по сотне точек каждый,
    /// тогда как в `speed_limits.json` 21 558 сегментов на 183 483 точки, то
    /// есть **8,5 точки на сегмент**: OSM режет улицу на куски там, где
    /// меняются теги. `match` обходит ВСЕ пары точек всех сегментов кольца 3×3,
    /// поэтому длина сегмента влияет на цену тика напрямую.
    ///
    /// Здесь: улицы через ~220 м (плотный центр Ташкента), каждая порезана на
    /// куски по 8 точек, шаг точки ~28 м. Область 0,06° — заметно больше
    /// кольца, чтобы замер не упирался в её край.
    private func realisticRoadNetwork() -> LimitIndex {
        var segments: [[Any]] = []
        let pointStep = 0.00025          // ~28 м между точками
        let streetStep = 0.002           // ~220 м между улицами
        let pieces = 8                   // точек в сегменте — как в боевом файле
        for i in 0..<30 {
            let lat = 41.28 + Double(i) * streetStep
            var lon = 69.20
            while lon < 69.26 {
                var flat: [Double] = []
                for k in 0...pieces { flat.append(lat); flat.append(lon + Double(k) * pointStep) }
                segments.append([60, flat])
                lon += Double(pieces) * pointStep
            }
        }
        for j in 0..<30 {
            let lon = 69.20 + Double(j) * streetStep
            var lat = 41.28
            while lat < 41.34 {
                var flat: [Double] = []
                for k in 0...pieces { flat.append(lat + Double(k) * pointStep); flat.append(lon) }
                segments.append([60, flat])
                lat += Double(pieces) * pointStep
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: ["segments": segments])
        return LimitIndex.build(from: data)!
    }

    /// Матчинг лимита по позиции и курсу: зовётся на КАЖДОМ GPS-тике, всю
    /// поездку, и от него зависят превышение, рейтинг и градус оповещения.
    ///
    /// Здесь этот тест и родился как измерение: на первом прогоне он показал
    /// 0,73 мс на тик — самую дорогую операцию GPS-тика, при том что
    /// комментарий у индекса обещал микросекунды. Сетка ячеек отсекала страну,
    /// но внутри кольца 3×3 честно перебирались ВСЕ пары точек ВСЕХ попавших
    /// сегментов, и на каждую пару звался `MKMapPoint.distance` — корень и
    /// пересчёт масштаба по широте ради одного сравнения «кто ближе».
    ///
    /// После рамки сегмента и сравнения квадратов в единицах карты — 0,11 мс.
    /// Потолок вдвое выше замеренного: ловим регресс в разы, а не шум.
    func testSpeedLimitMatchBudget() {
        let index = realisticRoadNetwork()
        let clock = ContinuousClock()
        var total: Duration = .zero
        var matched = 0
        // Пять проездов по 200 тиков: 28 м за тик (~100 км/ч) укладывается в
        // ширину сети ровно 200 раз. Вылет за её край считал бы стоимость
        // раннего выхода из пустой ячейки, а не работы.
        for _ in 0..<5 {
            for tick in 0..<200 {
                let point = CLLocationCoordinate2D(latitude: 41.30,
                                                   longitude: 69.205 + Double(tick) * 0.00025)
                let began = clock.now
                if index.match(point, courseDegrees: 90) != nil { matched += 1 }
                total += clock.now - began
            }
        }
        // Замерено на этой сети: ~0,11 с на 1000 тиков (было 0,73 до рамки).
        XCTAssertLessThan(total, .milliseconds(250),
                          "матчинг лимита деградировал: \(total) на 1000 тиков")
        // И он обязан что-то находить: мгновенный тест, который ничего не
        // матчит, померил бы стоимость раннего выхода, а не работы.
        XCTAssertGreaterThan(matched, 500, "тест не попал в сетку — замер бессмысленный")
    }

    // MARK: - Камеры маршрута

    /// «Эта камера на маршруте?» — вопрос не раз в секунду, а полтораста раз в
    /// секунду: `recomputeNearest` задаёт его про каждую камеру окна на каждом
    /// тике. Перебором по маршруту Ташкент—Самарканд это десятки тысяч
    /// сравнений на тик, и хуже всего именно там, где ехать дольше всего.
    func testRouteCameraLookupBudget() {
        let cameras: [RouteService.RouteCamera] = (0..<250).map { i in
            RouteService.RouteCamera(
                camera: Camera(id: i, region: "", city: "", location: "К\(i)",
                               lat: 41.3 + Double(i) * 0.01, lon: 69.2,
                               type: "Стационар радар", violations: [], needsReview: nil),
                distanceAlong: Double(i) * 1200)
        }
        let index = RouteService.index(of: cameras)

        let clock = ContinuousClock()
        var total: Duration = .zero
        var found = 0
        // 60 тиков × 150 камер окна — минута езды с построенным маршрутом.
        for _ in 0..<60 {
            let began = clock.now
            for id in 0..<150 where index.byID[id] != nil { found += 1 }
            total += clock.now - began
        }
        XCTAssertLessThan(total, .milliseconds(50),
                          "поиск камеры маршрута деградировал: \(total) на 9000 запросов")
        XCTAssertEqual(found, 60 * 150)
    }

    // MARK: - Лента «что впереди» на экране машины

    /// Камера, встреченная маршрутом дважды (петля развязки, круговое движение,
    /// разворот), обязана резолвиться в ПЕРВОЕ вхождение. Со вторым остаток
    /// пути считался бы до дальнего прохода — то есть приложение молчало бы о
    /// камере, пока не проедет её в первый раз.
    func testRouteCameraIndexKeepsFirstOccurrence() {
        let camera = Camera(id: 7, region: "", city: "", location: "Развязка",
                            lat: 41.3, lon: 69.2, type: "Стационар радар",
                            violations: [], needsReview: nil)
        let index = RouteService.index(of: [
            RouteService.RouteCamera(camera: camera, distanceAlong: 800),
            RouteService.RouteCamera(camera: camera, distanceAlong: 3400),
        ])
        XCTAssertEqual(index.byID[7]?.distanceAlong, 800)
        XCTAssertEqual(index.ids, [7])
    }

    // MARK: - Пер-тиковые пути поездки (аудит нагрева: раньше без потолков)

    /// Проекция на длинный маршрут — самый горячий пер-тик с активным
    /// маршрутом. Кумулятив снял O(позиция)-суммирование; потолок сторожит,
    /// чтобы оно не вернулось: 600 тиков по 10-тысячному маршруту.
    func testRouteProjectionBudget() {
        let pts = (0..<10_000).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30 + Double($0) * 0.00002,
                                              longitude: 69.20 + Double($0) * 0.0001))
        }
        let cum = RouteService.cumulative(of: pts)
        var hint = 0
        var checksum = 0.0
        let clock = ContinuousClock()
        let start = clock.now
        do {
            for tick in 0..<600 {
                // Едем вдоль маршрута: точка возле сегмента ~tick*15.
                let base = pts[min(tick * 15, pts.count - 1)]
                let probe = MKMapPoint(x: base.x + 5, y: base.y + 5)
                let (along, _) = RouteService.project(probe, onto: pts, cum: cum,
                                                      hint: &hint)
                checksum += along
            }
        }
        let elapsed = clock.now - start
        XCTAssertGreaterThan(checksum, 0)
        XCTAssertLessThan(elapsed, .milliseconds(250),
                          "600 проекций на 10k-маршрут: \(elapsed)")
    }

    /// Учёт проездов на каждом тике: подход к камере, зона измерения, траверз.
    func testPassTrackingBudget() {
        let origin = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        let camera = Camera(id: 1, region: "Т", city: "", location: "к",
                            lat: GeoMath.destination(from: origin, bearing: 0,
                                                     distanceMeters: 600).latitude,
                            lon: origin.longitude, type: "Стационар радар",
                            violations: [], needsReview: nil)
        var tracking = PassTracking()
        var passes = 0
        let clock = ContinuousClock()
        let start = clock.now
        do {
            for _ in 0..<5 {
                for tick in 0..<120 {
                    // 1785 м пути через камеру (тик = 15 м): конец лежит за
                    // радиусом + гистерезисом отпускания — проезд завершается.
                    let at = GeoMath.destination(from: origin, bearing: 0,
                                                 distanceMeters: Double(tick) * 15)
                    let d = GeoMath.fastDistance(at.latitude, at.longitude,
                                                 camera.lat, camera.lon)
                    passes += tracking.update(nearest: camera, nearestDistance: d,
                                              coordinate: at, speedKmh: 58,
                                              roadLimit: 60, radius: 600).count
                }
            }
        }
        let elapsed = clock.now - start
        XCTAssertGreaterThan(passes, 0, "маршрут проходит камеру насквозь — проезд обязан записаться")
        XCTAssertLessThan(elapsed, .milliseconds(250), "600 тиков учёта проездов: \(elapsed)")
    }

    /// Худший случай гейтов: в окне 150 камер и НИ ОДНОЙ на нашей дороге —
    /// перебор доходит до конца на каждом тике (обычно выходит на первой).
    func testGateWindowBudget() {
        let me = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)
        // Все камеры поперёк курса и в стороне: гейты обязаны отвергать каждую.
        let window: [Camera] = (0..<150).map { i in
            var at = GeoMath.destination(from: me, bearing: 0,
                                         distanceMeters: 300 + Double(i) * 40)
            at = GeoMath.destination(from: at, bearing: 90, distanceMeters: 400)
            var deltas: [Int] = []
            for step in [-200.0, 0, 200.0] {
                let p = GeoMath.destination(from: at, bearing: 90, distanceMeters: step)
                deltas.append(Int(((p.latitude - at.latitude) * 1e6).rounded()))
                deltas.append(Int(((p.longitude - at.longitude) * 1e6).rounded()))
            }
            return Camera(id: i, region: "Т", city: "", location: "к",
                          lat: at.latitude, lon: at.longitude, type: "Стационар радар",
                          violations: [], needsReview: false, axis: 90, dir: nil,
                          lanes: 2, cls: "primary", bridge: nil, road: deltas,
                          split: nil, twin: nil)
        }
        let situation = LocationGates.Situation(coordinate: me, course: 0, speedKmh: 60,
                                                horizontalAccuracy: 5, context: .city)
        var kept = 0
        let clock = ContinuousClock()
        let start = clock.now
        do {
            for _ in 0..<60 {
                kept += window.count { LocationGates.isOnOurRoad($0, in: situation,
                                                                 isOnRoute: false) }
            }
        }
        let elapsed = clock.now - start
        XCTAssertEqual(kept, 0, "боковые камеры с поперечной дорогой — не наши")
        XCTAssertLessThan(elapsed, .milliseconds(500), "60 тиков × 150 камер гейтов: \(elapsed)")
    }

    /// Чекпоинт поездки: упрощение + упаковка часового трека. Пишется раз в
    /// 20 с — но на main-акторе, и до аудита паковался ВЕСЬ сырой буфер.
    func testCheckpointPackBudget() {
        let raw = (0..<3300).map {
            TrackPoint(lat: 41.3 + Double($0) * 0.0001,
                       lon: 69.2 + Double($0) * 0.00012,
                       speedKmh: 60 + Double($0 % 30))
        }
        var total = 0
        let clock = ContinuousClock()
        let start = clock.now
        do {
            for _ in 0..<50 {
                let packed = TripStats.packTrack(TripStats.simplify(
                    raw, tolerance: 0.00022, maxPoints: 400)) ?? []
                total += packed.count
            }
        }
        let elapsed = clock.now - start
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(elapsed, .milliseconds(500), "50 чекпоинтов часового трека: \(elapsed)")
    }

    // MARK: - Призрак дороги на работу

    /// Фикс призрака — проекция в окне линии и O(1) прогноз: 2000 фиксов
    /// по линии из 600 вершин — меньше 50 мс суммарно (бюджет 8.8.2).
    func testCommuteGhostPerFixBudget() throws {
        let lat = 41.3, lon0 = 69.2
        let kx = 111_320 * cos(lat * .pi / 180)
        var line: [Int32] = []
        for i in 0..<600 {
            let x = 30_000.0 * Double(i) / 599
            line.append(Int32((lat * 1e5).rounded()))
            line.append(Int32(((lon0 + x / kx) * 1e5).rounded()))
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let rows = (0..<10).map { i in
            CommuteProfile.Row(tripID: Double(i), departure: start.addingTimeInterval(-Double(i + 1) * 86_400),
                               weekend: false, arrivalMinute: 0,
                               seconds: [UInt16](repeating: 20, count: 150))
        }
        let variant = CommuteProfile.Variant(id: UUID(), line: line,
                                             ends: (1...150).map { Float($0 * 200) },
                                             limitKmh: [], rows: rows, lastUsed: start)
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant], weekend: false,
                                                        departure: start, calendar: utc))
        let clock = ContinuousClock()
        let began = clock.now
        for k in 0..<2000 {
            let x = Double(k) * 15
            _ = session.note(lat: lat, lon: lon0 + x / kx, accuracy: 10,
                             at: start.addingTimeInterval(Double(k)))
        }
        XCTAssertLessThan(clock.now - began, .milliseconds(50), "призрак дорожает на фикс")
    }
}
