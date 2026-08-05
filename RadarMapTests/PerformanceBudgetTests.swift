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
}
