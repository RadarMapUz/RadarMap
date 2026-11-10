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

    // MARK: - Камеры на линии маршрута (CameraOnLine, 27.B)

    /// Точки камер на линии — раз на построение (вне главного потока), а на
    /// кадре только отбор по прогрессу и одна проекция на ось дороги без
    /// маршрута. Потолки ловят возврат проекции в кадр: 10 построений
    /// маршрута Ташкент—Самарканд (10 тыс. точек, 120 камер) и 600 кадров.
    func testCameraOnLineBudget() {
        let pts = (0..<10_000).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30 + Double($0) * 0.00002,
                                              longitude: 69.20 + Double($0) * 0.0001))
        }
        let cameras = (0..<120).map { i -> Camera in
            let base = pts[i * 80].coordinate
            return Camera(id: i, region: "", city: "", location: "К\(i)",
                          lat: base.latitude + 0.0001, lon: base.longitude,
                          type: "Стационар камера", violations: [], needsReview: nil,
                          axis: 79, dir: i % 2 == 0 ? 79 : 259, lanes: 3, cls: "primary",
                          split: true, twin: i % 4 == 1)
        }
        // `along` — как его отдаёт camerasAlong: метры по линии до точки камеры.
        var cum = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count { cum[i] = cum[i - 1] + pts[i - 1].distance(to: pts[i]) }
        let alongs = cameras.map { ($0, cum[$0.id * 80]) }
        let clock = ContinuousClock()
        var spots: [Int: CameraOnLine.Spot] = [:]
        let built = clock.now
        for _ in 0..<10 { spots = CameraOnLine.routeSpots(points: pts, cameras: alongs) }
        let buildTime = clock.now - built
        XCTAssertEqual(spots.count, 120)
        XCTAssertLessThan(buildTime, .milliseconds(300), "10 построений точек камер: \(buildTime)")

        let route = cameras.enumerated().map { (id: $0.element.id, along: Double($0.offset) * 800) }
        let origin = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.20)
        var shown = 0
        let frames = clock.now
        for frame in 0..<600 {
            let display = CameraOnLine.display(route: route, spots: spots, progress: Double(frame) * 100,
                                               passedTolerance: 60, nearest: frame % 120,
                                               nearestOnRoad: nil)
            shown += display.points.count
            _ = CameraOnLine.roadSpot(camera: cameras[frame % 120], origin: origin, bearing: 79)
        }
        let frameTime = clock.now - frames
        XCTAssertGreaterThan(shown, 0)
        XCTAssertLessThan(frameTime, .milliseconds(150), "600 кадров отбора камер на линии: \(frameTime)")
    }

    /// Участок треноги (83): выбор цели — на каждом кадре карты; места целей
    /// на маршруте — раз на маршрут.
    func testTripodZoneBudget() {
        let pts = (0..<10_000).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30 + Double($0) * 0.00002,
                                              longitude: 69.20 + Double($0) * 0.0001))
        }
        let tripods = (0..<60).map { i in
            TripodZone.Candidate(key: i, coordinate: pts[i * 150].coordinate, grade: .confirmed)
        }
        let spots = (0..<600).map { i in
            TripodZone.Candidate(key: -1 - i, coordinate: CLLocationCoordinate2D(
                latitude: 41.0 + Double(i % 30) * 0.02, longitude: 69.0 + Double(i / 30) * 0.03), grade: .hotspot)
        }
        let clock = ContinuousClock()
        let started = clock.now
        // Как в приложении (TripodZoneCache.alongs): индекс маршрута один на все цели.
        let along = TripodZone.alongs(of: tripods + spots, route: pts)
        let alongTime = clock.now - started
        XCTAssertEqual(tripods.filter { along[$0.key] != nil }.count, 60, "каждая тренога на маршруте найдена")
        XCTAssertLessThan(alongTime, .milliseconds(400), "места 660 целей на маршруте в 10 000 точек: \(alongTime)")

        var found = 0
        let frames = clock.now
        for frame in 0..<600 {
            let me = pts[frame * 15].coordinate
            if TripodZone.target(tripods: tripods, hotspots: spots, me: me, course: 79,
                                 routeAlong: nil, progress: nil) != nil { found += 1 }
            if TripodZone.target(tripods: tripods, hotspots: spots, me: me, course: 79,
                                 routeAlong: along, progress: Double(frame) * 100) != nil { found += 1 }
        }
        let frameTime = clock.now - frames
        XCTAssertGreaterThan(found, 0)
        XCTAssertLessThan(frameTime, .milliseconds(150), "600 кадров выбора цели участка: \(frameTime)")
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
                          lanes: 2, cls: "primary", road: deltas,
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

    // MARK: - История по месяцам (15.1)

    /// Запуск читает индекс и месяцы окна, а не всю историю: два тяжёлых
    /// месяца (по 120 поездок с треком в 400 точек и шестью проездами) плюс
    /// год лёгких месяцев позади. Бюджет — на чтение окна; год позади на
    /// старте не читается вовсе (иначе запуск рос бы вместе с историей).
    func testHistoryLaunchBudget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = TripStore.Paths(documents: dir)
        let now = Date(timeIntervalSince1970: 1_793_448_000)   // 31.10.2026
        func trip(_ start: Date, heavy: Bool) -> TripRecord {
            var track: [Double]?
            if heavy {
                var points: [Double] = []
                points.reserveCapacity(1200)
                for step in 0..<400 {
                    let k = Double(step)
                    points.append(41.30 + k * 0.0003)
                    points.append(69.20 + k * 0.0004)
                    points.append(40 + Double(step % 30))
                }
                track = points
            }
            let passes = heavy ? (0..<6).map { index in
                PassedCamera(id: UUID(), cameraID: index, typeRaw: "Стационар радар", location: "Улица \(index)",
                             speedKmh: 58, date: start.addingTimeInterval(Double(index) * 60),
                             lat: 41.3, lon: 69.2, limitKmh: 60)
            } : []
            return TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                              endedAt: start.addingTimeInterval(1500), distanceMeters: 12_000,
                              maxSpeedKmh: 80, passed: passes, endLat: 41.33, endLon: 69.3,
                              track: track, score: 92, startLat: 41.3, startLon: 69.2)
        }
        // Сентябрь и октябрь — по 120 тяжёлых поездок; август пуст; дальше
        // двенадцать месяцев по 60 лёгких.
        let heavy = (0..<240).map { trip(now.addingTimeInterval(-Double($0) * 0.25 * 86_400 - 3600), heavy: true) }
        let light = (0..<720).map { trip(now.addingTimeInterval(-Double(92 + $0 / 2) * 86_400), heavy: false) }
        var plan = TripStore.WritePlan()
        for (month, records) in TripStore.grouped(heavy + light) {
            plan.shards[month] = records
            plan.index[month] = TripStore.entry(month, records: records)
        }
        TripStore.perform(plan, paths: paths)

        let clock = ContinuousClock()
        let start = clock.now
        let result = TripStore.readLaunch(paths: paths, now: now, windowDays: AppConfig.tripHistoryLaunchDays,
                                          minRecords: TripHistory.Retention.current.keepLast, all: false)
        let elapsed = clock.now - start
        guard case .ready(let launch) = result else { return XCTFail("история не прочиталась") }
        XCTAssertEqual(launch.records.count, heavy.count, "в памяти — только окно")
        XCTAssertGreaterThanOrEqual(launch.older.count, 12, "год позади остаётся на диске")
        XCTAssertTrue(launch.unknown.isEmpty)
        XCTAssertLessThan(elapsed, .seconds(1), "запуск истории: индекс + два месяца — \(elapsed)")
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
        func variant(north: Double) -> CommuteProfile.Variant {
            var shifted = line
            for i in stride(from: 0, to: shifted.count, by: 2) {
                shifted[i] = Int32(((lat + north / 111_320) * 1e5).rounded())
            }
            return CommuteProfile.Variant(id: UUID(), line: shifted,
                                          ends: (1...150).map { Float($0 * 200) },
                                          limitKmh: [], rows: rows, lastUsed: start)
        }
        // Три варианта, два из них — параллельно в километре: далёкие линии
        // не сканируются, пока до них заведомо дальше порога.
        var session = try XCTUnwrap(CommuteLiveSession(variants: [variant(north: 1000), variant(north: 0),
                                                                  variant(north: -1000)],
                                                        weekend: false, departure: start, calendar: utc))
        let clock = ContinuousClock()
        let began = clock.now
        for k in 0..<2000 {
            let x = Double(k) * 15
            _ = session.note(lat: lat, lon: lon0 + x / kx, accuracy: 10,
                             at: start.addingTimeInterval(Double(k)))
        }
        XCTAssertLessThan(clock.now - began, .milliseconds(100), "призрак дорожает на фикс")
    }

    // MARK: - Слой полос (20.8)

    /// Слой на пределе контракта — 50 000 подходов — и маршрут в 30 манёвров:
    /// поиск подхода на каждый шаг обязан стоить микросекунды (сетка, а не
    /// перебор), иначе приложение слоя к маршруту на главном потоке стало бы
    /// заметным. Плюс сборка сетки на 50 000 — она идёт при каждом подъёме
    /// слоя с диска.
    func testLaneOverlayLookupBudget() {
        // Подходы сеткой по Ташкенту плотнее реального: ~1,3 на ячейку поиска.
        let arrows: [[LaneArrow]] = [[.left], [.left, .straight], [.straight], [.straight, .right]]
        var junctions: [LaneOverlay.Junction] = []
        junctions.reserveCapacity(AppConfig.laneOverlayMaxJunctions)
        for i in 0..<AppConfig.laneOverlayMaxJunctions {
            let row = i / 224, column = i % 224
            junctions.append(LaneOverlay.Junction(id: "j\(i)", latitude: 41.2 + Double(row) * 0.0009,
                                                  longitude: 69.1 + Double(column) * 0.0009,
                                                  bearing: Double((i * 90) % 360), tolerance: 30, lanes: arrows))
        }
        let clock = ContinuousClock()
        let built = clock.now
        let overlay = LaneOverlay(junctions: junctions)
        let buildTime = clock.now - built
        XCTAssertLessThan(buildTime, .seconds(1), "сетка слоя на 50 000 подходов: \(buildTime)")

        // 30 манёвров маршрута — у подходов (с курсом) и между ними.
        let probes: [LaneProbe] = (0..<30).map { k in
            let junction = junctions[(k * 1_663) % junctions.count]
            let offset = k.isMultiple(of: 2) ? 0.00005 : 0.0004
            return LaneProbe(target: .step(k), latitude: junction.latitude + offset,
                             longitude: junction.longitude, approachBearing: junction.bearing,
                             maneuver: k.isMultiple(of: 3) ? .right : .left)
        }
        var found = 0
        var worst: Duration = .zero
        var total: Duration = .zero
        for _ in 0..<100 {
            for probe in probes {
                let began = clock.now
                if overlay.lanes(at: probe.coordinate, approachBearing: probe.approachBearing,
                                 maneuver: probe.maneuver) != nil { found += 1 }
                let spent = clock.now - began
                total += spent
                worst = max(worst, spent)
            }
        }
        XCTAssertGreaterThan(found, 0, "подходы рядом с точками обязаны находиться")
        XCTAssertLessThan(total / 3_000, .microseconds(100), "поиск подхода в среднем: \(total / 3_000)")
        XCTAssertLessThan(worst, .milliseconds(1), "худший поиск подхода: \(worst)")

        // Приложение слоя к маршруту целиком: 30 манёвров + 300 проездов.
        let steps = (0..<30).map { RouteStep(distanceAlong: Double($0) * 500, text: "", icon: "arrow.up", kind: .left) }
        let passages = (0..<300).map { k -> LaneProbe in
            let junction = junctions[(k * 151) % junctions.count]
            return LaneProbe(target: .passage(Double(k) * 50), latitude: junction.latitude,
                             longitude: junction.longitude, approachBearing: junction.bearing, maneuver: nil)
        }
        let attachedAt = clock.now
        let attached = LaneOverlay.attach(steps: steps, notices: [], probes: probes + passages, overlay: overlay)
        let attachTime = clock.now - attachedAt
        XCTAssertGreaterThan(attached.stats.overlay, 0)
        XCTAssertLessThan(attachTime, .milliseconds(10), "слой к маршруту в 330 точек: \(attachTime)")
    }

    /// Пробки на карте линиями улиц (33H): сшивка и сглаживание всего города —
    /// фикстура вечернего Ташкента, 41 тыс. рёбер (вдвое больше, чем дал бы
    /// весь город с моделью по магистралям), раз на новый now.json, вне
    /// главного потока. Спецификация: < 30 мс в Debug.
    func testTrafficStitchBudget() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "traffic_demo_tashkent", withExtension: "json"))
        let snapshot = try XCTUnwrap(TrafficSnapshot.decode(Data(contentsOf: url)))
        XCTAssertGreaterThan(snapshot.edges.count, 30_000)
        _ = TrafficLines.lines(from: snapshot.edges)            // прогрев
        let clock = ContinuousClock()
        var best = Duration.seconds(10)
        var lines = 0
        for _ in 0..<3 {
            let start = clock.now
            lines = TrafficLines.lines(from: snapshot.edges).count
            best = min(best, clock.now - start)
        }
        XCTAssertGreaterThan(lines, 0)
        XCTAssertLessThan(best, .milliseconds(30), "сшивка пробок города: \(best)")
    }

    /// Пробки на линии маршрута (25.D): остаток маршрута в 30 км по городу с
    /// тысячей рёбер — пересчёт идёт на каждые 30 м прогресса (вне главного
    /// потока), и он обязан оставаться миллисекундами, а не сотнями.
    func testRouteTrafficBudget() {
        let route = (0..<3_000).map { i in
            CLLocationCoordinate2D(latitude: 41.25 + Double(i) * 0.00009,
                                   longitude: 69.20 + Double(i % 200) * 0.00002)
        }
        let edges = (0..<1_000).map { i -> TrafficEdge in
            let a = route[(i * 3) % (route.count - 1)], b = route[(i * 3) % (route.count - 1) + 1]
            return TrafficEdge(a: a, b: b, level: 1 + i % 3, kmh: 15, modelKmh: 50)
        }
        let snapshot = TrafficSnapshot(generated: Date(), edges: edges)
        let clock = ContinuousClock()
        let start = clock.now
        var pieces = 0
        for _ in 0..<5 { pieces += RouteTraffic.pieces(along: route, snapshot: snapshot).count }
        let total = clock.now - start
        XCTAssertGreaterThan(pieces, 0)
        // 5 пересчётов 30 км — меньше полсекунды на симуляторе (замер 21.10 — 0,065 с).
        XCTAssertLessThan(total, .milliseconds(500), "пробки на линии деградировали: \(total)")
    }

    /// «Впереди пробка» (JamAhead): раз в 10 с всю поездку, на главном потоке.
    /// Индекс узлов строится один раз на снимок, а сам поиск идёт по цепочке
    /// от своего ребра — не перебором всех рёбер города.
    func testJamAheadBudget() {
        // Город 10 × 10 км: улицы на север каждые ~200 м, рёбра по ~100 м, каждое третье медленное.
        var edges: [TrafficEdge] = []
        for street in 0..<50 {
            for i in 0..<100 {
                let a = CLLocationCoordinate2D(latitude: 41.25 + Double(i) * 0.0009,
                                               longitude: 69.20 + Double(street) * 0.0024)
                let b = CLLocationCoordinate2D(latitude: a.latitude + 0.0009, longitude: a.longitude)
                edges.append(TrafficEdge(a: a, b: b, level: i % 3 == 0 ? 1 : 3, kmh: 8, modelKmh: 50))
            }
        }
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = TrafficSnapshot(generated: Date(), edges: edges)
        let build = clock.now - start
        start = clock.now
        var found = 0
        for i in 0..<1_000 {
            let position = CLLocationCoordinate2D(latitude: 41.25 + Double(i % 80) * 0.0009 + 0.0002,
                                                  longitude: 69.20 + Double(i % 50) * 0.0024)
            if JamAhead.detect(in: snapshot, position: position, course: 0) != nil { found += 1 }
        }
        let each = (clock.now - start) / 1_000
        XCTAssertGreaterThan(found, 0)
        // Замер 10.11 (macOS, -Onone): снимок 5 000 рёбер — 15 мс, поиск — 0,013 мс.
        XCTAssertLessThan(build, .milliseconds(150), "снимок пробок с индексом узлов: \(build)")
        XCTAssertLessThan(each, .microseconds(500), "пробка впереди на фикс: \(each)")
    }

    /// Время прибытия во времени (33C): маршрут на 300 км с профилем города
    /// и живыми пробками — «Быстрый» считает его на каждый вариант, и он
    /// обязан оставаться в пределах 2 мс (docs/spec_traffic_33.md).
    func testTrafficTimeAheadBudget() {
        // 300 км на северо-восток, точка каждые 100 м; первые 20 км — город.
        let route = (0...3_000).map { i in
            CLLocationCoordinate2D(latitude: 41.25 + Double(i) * 0.0006, longitude: 69.20 + Double(i) * 0.0006)
        }
        // Город на первых 20 км: наш путь в обе стороны, поперечные улицы
        // каждые ~400 м (обе стороны, по 300 м) и ещё 1 500 рёбер города в
        // стороне от пути — профиль часа пик ~3 000 рёбер.
        func edge(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [Any] {
            [a.latitude, a.longitude, b.latitude, b.longitude, 60, [[18, 20], [19, 30]]]
        }
        var city: [[Any]] = []
        for i in 0..<200 {
            city.append(edge(route[i], route[i + 1]))
            city.append(edge(route[i + 1], route[i]))
            if i % 5 == 0 {
                for k in 0..<3 {
                    let a = CLLocationCoordinate2D(latitude: route[i].latitude + Double(k) * 0.0009,
                                                   longitude: route[i].longitude - Double(k) * 0.0009)
                    let b = CLLocationCoordinate2D(latitude: a.latitude + 0.0009, longitude: a.longitude - 0.0009)
                    city.append(edge(a, b))
                    city.append(edge(b, a))
                }
            }
        }
        for i in 0..<1_500 {
            let a = CLLocationCoordinate2D(latitude: 41.30 + Double(i % 50) * 0.002,
                                           longitude: 69.10 + Double(i / 50) * 0.002)
            city.append(edge(a, CLLocationCoordinate2D(latitude: a.latitude + 0.0009, longitude: a.longitude)))
        }
        let monday = TypicalTraffic.tashkent.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 17,
                                                                       minute: 40))!
        let object: [String: Any] = ["v": 1, "generated": monday.timeIntervalSince1970, "edges": city]
        let profile = TrafficProfile.decode(try! JSONSerialization.data(withJSONObject: object))!
        let live = TrafficSnapshot(generated: monday, edges: (0..<150).map { i in
            TrafficEdge(a: route[i], b: route[i + 1], level: 2, kmh: 25, modelKmh: 60)
        })
        let clock = ContinuousClock()
        var total = 0.0
        let start = clock.now
        for _ in 0..<10 {
            total += TrafficTimeAhead.delay(along: route, baseTime: 300 * 60, departure: monday, now: monday,
                                            live: live, profile: profile)?.seconds ?? 0
        }
        let each = (clock.now - start) / 10
        XCTAssertGreaterThan(total, 0)
        // Спецификация — < 2 мс на маршрут. Тесты собираются без оптимизаций
        // (-Onone): на симуляторе 27.10 сам проход 3 000 точек без данных — 0,7 мс,
        // этот маршрут — 3,2 мс. Потолок здесь — 5 мс: регрессию на порядок он
        // ловит, а 2 мс относятся к оптимизированной сборке (TRAFFIC.md, 33C).
        XCTAssertLessThan(each, .milliseconds(5), "время прибытия во времени на 300 км: \(each)")
    }

    /// Срез линии под значком (27.A): на КАЖДОМ кадре стрелки (до 30 в
    /// секунду всю поездку) — проекция точки, краска окна с пробками и
    /// манёвром, выражение line-gradient и порог стрелок. Обязан быть
    /// микросекундами: десятки миллисекунд на кадр — это и есть «лагает».
    func testRouteCutFrameBudget() {
        let route = (0..<3_000).map { i in
            CLLocationCoordinate2D(latitude: 41.25 + Double(i) * 0.00009,
                                   longitude: 69.20 + Double(i % 200) * 0.00002)
        }
        let line = RouteCut.Line(route)
        let arrows = RouteCut.arrows(line)
        let traffic = (0..<40).map { i in
            RouteTraffic.Piece(level: 2 + i % 2, coordinates: [], from: Double(i) * 700, to: Double(i) * 700 + 120)
        }
        let colours = RouteCut.Colours(daylight: true)
        var tracker = RouteCut.Tracker()
        var window: RouteCut.Window?
        let clock = ContinuousClock()
        let start = clock.now
        var stops = 0
        // 1 800 кадров — минута на 30 к/с, ~830 м пути.
        for frame in 0..<1_800 {
            let along = 100 + Double(frame) * 0.46
            let point = line.pose(at: along).coordinate
            let cut = tracker.advance(pose: point, course: -1, fixAlong: along - 3, speedMps: 14, line: line)
            window = RouteCut.window(window, cut: cut, routeLength: line.length)
            guard let window else { continue }
            let paint = RouteCut.paint(window: window, cut: cut, drawEnd: window.end, traffic: traffic,
                                       maneuver: (along + 50)...(along + 120), colours: colours)
            for layer in [paint.casing, paint.body, paint.maneuver, paint.core] {
                stops += RouteCut.gradient(layer).count
            }
            _ = RouteCut.arrowThreshold(arrows, cut: cut, minRank: 2)
        }
        let total = clock.now - start
        XCTAssertGreaterThan(stops, 0)
        XCTAssertGreaterThan(tracker.cut, 800)
        // Минута кадров — меньше 0,3 с на симуляторе (≤ 0,17 мс на кадр).
        XCTAssertLessThan(total, .milliseconds(300), "срез линии дорожает на кадр: \(total)")
    }

    /// «Перед дальней дорогой» (12.4): маршрут 600 км (точка на 100 м),
    /// 400 камер на нём и 3000 заправок в коридоре. Лист собирается вне
    /// главного потока при открытии и после докачки; проекция заведений на
    /// линию и сборка мест обязаны оставаться десятками миллисекунд, а не
    /// секундами — возврат перебора «каждое заведение × каждый отрезок»
    /// (18 млн пар) это и поймает.
    func testLongTripBriefBudget() {
        let route = (0..<6_000).map { i in
            MKMapPoint(CLLocationCoordinate2D(latitude: 41.30 - Double(i) * 0.0006,
                                              longitude: 69.20 - Double(i) * 0.0004 + Double(i % 50) * 0.00001))
        }
        let cameras = syntheticCameras(400)
        let markers = cameras.enumerated().map { index, camera in
            LongTripBrief.Marker(camera: camera, along: Double(index) * 1_450 + Double(index % 3) * 90)
        }
        let kinds: [Venue.Kind] = [.cng, .fuel, .lpg]
        let venues = (0..<3_000).map { i -> Venue in
            let base = route[(i * 2) % route.count].coordinate
            return Venue(kind: kinds[i % 3], name: "",
                         point: CLLocationCoordinate2D(latitude: base.latitude + Double(i % 7 - 3) * 0.002,
                                                       longitude: base.longitude + Double(i % 5 - 2) * 0.002))
        }
        let now = Date()
        let clock = ContinuousClock()
        let start = clock.now
        var rows = 0
        for _ in 0..<5 {
            let items = CorridorVenues.find(venues, route: route, progress: 0, kinds: Set(kinds), limit: .max)
            let brief = LongTripBrief.make(markers: markers, venues: items, kinds: kinds, progress: 0,
                                           routeLength: 600_000, venuesComplete: true, now: now)
            rows += brief.checkpoints.count + brief.fuel.reduce(0) { $0 + $1.items.count }
        }
        let total = clock.now - start
        XCTAssertGreaterThan(rows, 0)
        // 5 сборок — меньше 2 с на симуляторе (замер 27.10 — 0,52 с; перебор
        // всех пар был бы десятками секунд).
        XCTAssertLessThan(total, .milliseconds(2_000), "лист дальней дороги дорожает: \(total)")
    }

    /// Свой поиск (40G) на клетке формы Ташкента: 3 200 улиц, у каждой
    /// «ko'chasi» и по 36 домов (115 тысяч), и 9 000 мест, у трети — другие и
    /// старые имена. Запрос идёт на каждую букву на главном потоке — худший из
    /// набора обязан быть меньше 30 мс. «ka 1» / «Чи 1» — две буквы и номер:
    /// до ревью 03.11 «ka» совпадало с «kachasi» у всех улиц, и строка id на
    /// каждый из ~30 тысяч домов давала 170 мс на маке (после — 14 мс под
    /// нагрузкой 60). Сборка индекса — off-main и меньше 3 с.
    func testSearchIndexBudget() {
        let syllables = ["ta", "shk", "ent", "cho", "rsu", "nov", "za", "ham", "mir", "zo", "ulu", "gbek",
                         "yun", "usa", "bad", "chi", "lan", "zar", "bun", "yod", "kor", "sab", "zi", "qo",
                         "yli", "beru", "ni", "tin", "chlik", "oy", "bek", "pax", "ta", "kor", "olm", "azor"]
        func name(_ seed: Int, words: Int) -> String {
            (0..<words).map { w in
                (0..<2 + (seed + w) % 2).map { syllables[(seed * 7 + w * 13 + $0 * 5) % syllables.count] }.joined()
            }.joined(separator: " ")
        }
        var addresses: [Address] = []
        var names: [String: (aliases: [String], old: [String])] = [:]
        for street in 0..<3_200 {
            let title = name(street, words: 2) + " ko'chasi \(street)"
            if street % 3 == 0 { names[title] = ([name(street + 1, words: 2) + " улица"], [name(street + 2, words: 1)]) }
            for house in 0..<36 {
                addresses.append(Address(street: title, house: "\(house + 1)",
                                         point: CLLocationCoordinate2D(latitude: 41.2 + Double(street % 60) * 0.004,
                                                                       longitude: 69.1 + Double(street / 60) * 0.004
                                                                           + Double(house) * 0.0001)))
            }
        }
        let kinds = Venue.Kind.allCases
        let venues = (0..<9_000).map { i in
            Venue(kind: kinds[i % kinds.count], name: name(i * 3, words: 1 + i % 3),
                  point: CLLocationCoordinate2D(latitude: 41.2 + Double(i % 90) * 0.003,
                                                longitude: 69.1 + Double(i / 90) * 0.003),
                  aliases: i % 3 == 0 ? [name(i, words: 2)] : [], oldNames: i % 5 == 0 ? [name(i + 9, words: 1)] : [])
        }
        let clock = ContinuousClock()
        let buildStart = clock.now
        let index = SearchIndex(book: AddressBook(addresses: addresses, names: names), venues: VenueBook(venues: venues))
        let build = clock.now - buildStart
        let near = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        let queries = ["ta", "tashk", "ташкент", "чорсу", "метро хамза", "hamza metro", "mirzo ulugbek",
                       "мирза улугбека", "yunusabad", "бунёдкор", "bunedkor", "chilanzar 5", "novza", "амира тимура",
                       "kor ko'chasi 7", "azs", "метро", "махалля", "beruni", "tinchlikk", "oybek pahtakor",
                       "olmazor 12", "qoyli", "nov", "z", "улица ", "zzzzzz", "a b c d",
                       "ka 1", "ko 1", "Чи 1", "yu 1", "ta 1", "K.G‘", "chorsu 2"]
        var worst: Duration = .zero
        var worstQuery = ""
        var found = 0
        for query in queries {
            // Лучший из трёх: бюджет — про цену запроса, а не про занятость мака.
            var best: Duration = .seconds(1)
            for _ in 0..<3 {
                let start = clock.now
                let answer = index.search(query, near: near)
                best = min(best, clock.now - start)
                found += answer.addresses.count + answer.venues.count
            }
            if best > worst { worst = best; worstQuery = query }
        }
        XCTAssertGreaterThan(found, 0)
        XCTAssertLessThan(worst, .milliseconds(30), "запрос поиска дорожает: худший \(worst) на «\(worstQuery)»")
        XCTAssertLessThan(build, .seconds(3), "сборка индекса поиска дорожает: \(build)")
    }
    /// Лента «Вождения 3D» (LanePath, 43): участок 1,5 км по городской
    /// сетке (7 200 отрезков лент тайла, 300 стрелок) — пересчёт идёт при
    /// смене маршрута, манёвра и раз в 250 м, срез — раз в 8 м. Возврат
    /// перебора «станция × все отрезки» (5 млн пар) это и поймает.
    func testLanePathBudget() {
        let frame = LanePath.Frame(origin: CLLocationCoordinate2D(latitude: 41.30, longitude: 69.24))
        func c(_ x: Double, _ y: Double) -> CLLocationCoordinate2D { frame.coordinate(.init(x: x, y: y)) }
        var roads: [LanePath.Road] = []
        for k in 0..<60 {
            let a = Double(k) * 100
            roads.append(LanePath.Road(points: (0...60).map { c(a, Double($0) * 100) }, width: 14,
                                       oneway: false, bridge: k % 9 == 0))
            roads.append(LanePath.Road(points: (0...60).map { c(Double($0) * 100, a) }, width: 10,
                                       oneway: k % 2 == 0, bridge: false))
        }
        let arrows = (0..<300).map { (i: Int) -> LanePath.Arrow in
            let x: Double = Double(i % 60) * 100 + 2
            let y: Double = Double(i / 5) * 100 - 40
            return LanePath.Arrow(coordinate: c(x, y), bearing: 0, width: 3.5, ours: i % 2 == 0)
        }
        // Лесенка: 300 м на север, 300 м на восток — манёвр на каждом углу.
        var route: [CLLocationCoordinate2D] = []
        for step in 0..<10 {
            let a = Double(step) * 300
            route += [c(a, a), c(a, a + 300)]
        }
        let clock = ContinuousClock()
        let start = clock.now
        var pieces = 0
        for run in 0..<5 {
            let car = 200 + Double(run) * 250
            let ribbon = LanePath.build(LanePath.Input(
                route: route, from: car, length: AppConfig.drive3DAheadMeters, car: car, speedMps: 14,
                window: 210, roads: roads, arrows: arrows,
                maneuver: LanePath.Maneuver(along: (car / 300).rounded(.up) * 300 + 300, edge: .left, row: true),
                narrowing: true))
            for cut in stride(from: car, to: car + 250, by: AppConfig.drive3DCutStepMeters) {
                pieces += LanePath.pieces(ribbon, from: cut).count
            }
            _ = LanePath.chevrons(ribbon, spacing: AppConfig.drive3DChevronSpacing)
        }
        let total = clock.now - start
        XCTAssertGreaterThan(pieces, 0)
        // 5 пересчётов и 160 срезов: ~0,6 с в отладочной сборке на маке
        // (−Onone; в релизе ~0,05 с) — потолок втрое выше.
        XCTAssertLessThan(total, .seconds(2), "лента 3D дорожает: \(total)")
    }
}
