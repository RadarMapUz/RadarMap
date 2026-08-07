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

    /// Схема приборки, полный горячий путь минуты езды: на каждом тике —
    /// арифметика точки зрения и решение о пересборке, изредка — сборка сцены
    /// (плотный центр, позади маршрут на 300 км из 10 000 точек). Ловим два
    /// регресса: возврат тяжёлой работы на каждый тик и разучившийся жить
    /// растр, который пересобирается каждую секунду.
    func testRoadSketchBudget() {
        // Как в бою: индекс под кэшем окрестности (см. SpeedLimitService).
        let network = CachedRoadNetwork(syntheticRoadNetwork())
        let start0 = CLLocationCoordinate2D(latitude: 41.29, longitude: 69.25)
        let route: [CLLocationCoordinate2D] = (0..<10_000).map {
            CLLocationCoordinate2D(latitude: start0.latitude + Double($0) * 0.0003,
                                   longitude: start0.longitude)
        }
        let track: [CLLocationCoordinate2D] = (0..<60).map {
            CLLocationCoordinate2D(latitude: start0.latitude - Double($0) * 0.0003,
                                   longitude: start0.longitude)
        }
        // Камера в 600 м впереди со своим куском дороги, как у 99,7% базы
        // (дельты в 1e-6°; ~30 м шага по широте ≈ 270 единиц).
        var road: [Int] = []
        for step in -3...3 { road.append(step * 270); road.append(0) }
        let camera = Camera(id: 1, region: "Т", city: "Т", location: "Тест",
                            lat: start0.latitude + 600 / 111_320.0,
                            lon: start0.longitude,
                            type: "Стационар радар", violations: [], needsReview: nil,
                            axis: 0, road: road)

        let clock = ContinuousClock()
        var total: Duration = .zero
        var scene: RoadSketch.Scene?
        var key: RoadSketch.RebuildKey?
        var rebuilds = 0
        for tick in 0..<60 {
            // 20 м/тик ≈ 72 км/ч: проезжаем камеру насквозь, как в жизни.
            let me = CLLocationCoordinate2D(
                latitude: start0.latitude + Double(tick) * 20 / 111_320.0,
                longitude: start0.longitude)
            let began = clock.now
            let distance = GeoMath.fastDistance(me.latitude, me.longitude,
                                                camera.lat, camera.lon)
            let span = RoadSketch.span(forDistance: distance)
            let inRange = RoadSketch.isInRange(distance: distance, span: span)
            let freshKey = RoadSketch.RebuildKey(
                alertCameraID: inRange ? camera.id : nil,
                alertInRange: inRange,
                spanBucket: RoadSketch.bucket(forSpan: span),
                networkGeneration: 1, storeRevision: 1, budget: 80)
            let offset = scene.map { built in
                CGPoint(x: 0, y: (me.latitude - built.anchorLatitude) * 111_320.0)
            } ?? .zero
            if RoadSketch.needsRebuild(scene: scene, key: freshKey,
                                       previousKey: key, meOffsetMeters: offset) {
                rebuilds += 1
                scene = RoadSketch.scene(alertCamera: camera, alertInRange: inRange,
                                         cameras: [camera], network: network,
                                         networkBudget: 80, route: route, track: track,
                                         anchor: me, spanMeters: span)
            }
            key = freshKey
            _ = RoadSketch.screenPoint(scene?.alertCamera ?? .zero, meOffset: offset,
                                       courseDegrees: 0, spanMeters: span,
                                       aspect: 16.0 / 9.0)
            total += clock.now - began
        }
        // Минута тиков приборки — суммарно меньше полсекунды.
        XCTAssertLessThan(total, .milliseconds(500),
                          "схема приборки деградировала: \(total) на 60 тиков")
        // Суть архитектуры: проезд камеры насквозь — худший случай (ступени
        // масштаба щёлкают туда и обратно), и даже он обязан пересобирать
        // растр в разы реже, чем раз в тик.
        XCTAssertLessThan(rebuilds, 30,
                          "растр пересобирается слишком часто: \(rebuilds) раз за минуту")
    }
}
