//
//  PassProofTests.swift
//  RadarMapTests
//
//  Запись проезда требует ДОКАЗАТЕЛЬСТВА — в отличие от оповещения, которое
//  срабатывает по подозрению. Цена ошибки разная: лишний сигнал стоит одного
//  «бип», лишняя запись — ложного превышения, чужого перекрёстка в «Где теряете
//  баллы» и снятых баллов рейтинга.
//
//  Разобрано на реальном случае: на развязке Айбек × Малая кольцевая в историю
//  попадали камеры Туркистон — они стоят на ПОПЕРЕЧНОЙ улице. Коридор
//  оповещений пропускал их при захвате за 400 м (там его допуск 68–93 м по
//  построению), а дальше PassTracking мерил только расстояние по прямой.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class PassProofTests: XCTestCase {

    /// Камера на 4-полосном проспекте, идущем строго на восток; кусок дороги
    /// ±100 м от неё. halfWidth = 4×3,5/2 + 8 = 15 м, порог отклонения = 37,5 м.
    private func avenueCamera(id: Int = 1, lat: Double = 41.30,
                              lon: Double = 69.21) -> Camera {
        let halfPieceLon = Int((100.0 / (111_320 * cos(lat * .pi / 180))) * 1e6)
        return Camera(id: id, region: "", city: "", location: "проспект",
                      lat: lat, lon: lon, type: "Стационар радар",
                      violations: [], needsReview: nil,
                      dir: 90, lanes: 4, cls: "primary",
                      road: [0, -halfPieceLon, 0, halfPieceLon])
    }

    /// Смещение к северу в градусах широты.
    private func north(_ meters: Double) -> Double { meters / 111_320 }

    // MARK: - Доказательство по куску дороги

    func testOnOwnRoadIsNotOffRoad() {
        let camera = avenueCamera()
        let onRoad = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.2105)
        XCTAssertFalse(PassGeometry.isProvenOffRoad(camera: camera, at: onRoad))
    }

    /// Соседняя полоса и погрешность координаты — это ещё не «другая дорога».
    func testWithinRoadWidthIsNotOffRoad() {
        let camera = avenueCamera()
        let beside = CLLocationCoordinate2D(latitude: 41.30 + north(30), longitude: 69.2105)
        XCTAssertFalse(PassGeometry.isProvenOffRoad(camera: camera, at: beside))
    }

    /// Поперечная улица развязки: шестьдесят метров вбок — это доказательство.
    func testCrossStreetIsProvenOffRoad() {
        let camera = avenueCamera()
        let crossing = CLLocationCoordinate2D(latitude: 41.30 + north(60), longitude: 69.2105)
        XCTAssertTrue(PassGeometry.isProvenOffRoad(camera: camera, at: crossing))
    }

    /// Кусок дороги кончился раньше нас — это «нечего мерить», а не «другая
    /// дорога». На перекрёстке OSM режет улицу на огрызки в два-три десятка
    /// метров, и молчаливое отклонение таких проездов было бы потерей данных.
    func testBeyondRoadPieceGivesNoProof() {
        let camera = avenueCamera()
        // 250 м восточнее камеры — за концом её стометрового куска.
        let far = CLLocationCoordinate2D(latitude: 41.30 + north(60), longitude: 69.213)
        XCTAssertFalse(PassGeometry.isProvenOffRoad(camera: camera, at: far))
    }

    /// Своя камера и краудсорсная отметка геометрии не несут — доказательства нет.
    func testCameraWithoutRoadProfileGivesNoProof() {
        let plain = Camera(id: 2, region: "", city: "", location: "своя",
                           lat: 41.30, lon: 69.21, type: "Стационар радар",
                           violations: [], needsReview: nil)
        let farAway = CLLocationCoordinate2D(latitude: 41.30 + north(300), longitude: 69.21)
        XCTAssertFalse(PassGeometry.isProvenOffRoad(camera: plain, at: farAway))
    }

    /// Снап сел на тротуар — профилю такой «дороги» верить нельзя ни для
    /// заглушения оповещения, ни для отклонения проезда.
    func testPedestrianProfileGivesNoProof() {
        let halfPieceLon = Int((100.0 / (111_320 * cos(41.30 * .pi / 180))) * 1e6)
        let footway = Camera(id: 3, region: "", city: "", location: "тротуар",
                             lat: 41.30, lon: 69.21, type: "Стационар радар",
                             violations: [], needsReview: nil,
                             dir: 90, lanes: 1, cls: "footway",
                             road: [0, -halfPieceLon, 0, halfPieceLon])
        let aside = CLLocationCoordinate2D(latitude: 41.30 + north(60), longitude: 69.2105)
        XCTAssertFalse(PassGeometry.isProvenOffRoad(camera: footway, at: aside))
    }

    // MARK: - Порог траверза

    func testTraverseLimitIsTightForSnappedCameras() {
        XCTAssertEqual(PassGeometry.traverseLimit(for: avenueCamera()),
                       AppConfig.passTraverseMaxMeters)
    }

    /// У точки, поставленной человеком, координата не на оси дороги — сужать
    /// порог там значит терять настоящие проезды.
    func testTraverseLimitStaysWideWithoutProfile() {
        let plain = Camera(id: 4, region: "", city: "", location: "своя",
                           lat: 41.30, lon: 69.21, type: "Передвижной радар",
                           violations: [], needsReview: nil)
        XCTAssertEqual(PassGeometry.traverseLimit(for: plain),
                       AppConfig.passTraverseNoProfileMeters)
    }

    // MARK: - Сквозной сценарий развязки

    /// Ехали своей дорогой, камера стоит на поперечной улице в 60 м. Раньше
    /// такой проезд записывался: 60 ≤ 80 м старого гейта.
    func testInterchangeCameraIsNotRecorded() {
        var tracking = PassTracking()
        let camera = avenueCamera(lat: 41.30 + north(60))   // в 60 м севернее нашей дороги
        func tick(_ lon: Double, _ speed: Double) -> [PassTracking.Pass] {
            let coordinate = CLLocationCoordinate2D(latitude: 41.30, longitude: lon)
            let distance = GeoMath.fastDistance(41.30, lon, camera.lat, camera.lon)
            return tracking.update(nearest: camera, nearestDistance: distance,
                                   coordinate: coordinate, speedKmh: speed,
                                   roadLimit: 60, radius: 500,
                                   offRoad: PassGeometry.isProvenOffRoad(camera:at:))
        }
        _ = tick(69.2060, 70)     // захват издалека — коридор оповещений щедр
        _ = tick(69.2100, 72)     // траверз: 60 м вбок
        let passes = tick(69.2220, 74)
        XCTAssertTrue(passes.isEmpty, "камера поперечной улицы не наш проезд")
        XCTAssertTrue(tracking.tracked.isEmpty)
    }

    /// Тот же путь, но камера на нашей дороге: проезд обязан записаться,
    /// со скоростью-минимумом из зоны измерения.
    func testOwnRoadPassStillRecorded() {
        var tracking = PassTracking()
        let camera = avenueCamera()
        func tick(_ lon: Double, _ speed: Double) -> [PassTracking.Pass] {
            let coordinate = CLLocationCoordinate2D(latitude: 41.30, longitude: lon)
            let distance = GeoMath.fastDistance(41.30, lon, camera.lat, camera.lon)
            return tracking.update(nearest: camera, nearestDistance: distance,
                                   coordinate: coordinate, speedKmh: speed,
                                   roadLimit: 60, radius: 500,
                                   offRoad: PassGeometry.isProvenOffRoad(camera:at:))
        }
        _ = tick(69.2060, 70)
        _ = tick(69.2095, 62)     // ~42 м — зона измерения
        _ = tick(69.2100, 57)     // траверз
        _ = tick(69.2105, 66)     // разгон после проезда
        let passes = tick(69.2220, 90)
        XCTAssertEqual(passes.count, 1)
        XCTAssertEqual(passes[0].speedKmh, 57, "минимум зоны, разгон после — не в счёт")
    }

    // MARK: - Починка дневных агрегатов после ретро-чистки

    /// Чистка выбрасывает проезд из записи, и дневная строка обязана поехать
    /// следом — иначе рейтинг периода (он считается по дням) разойдётся с
    /// разбором (он считается по записям), и блок перестанет сходиться.
    ///
    /// Правится хирургически: вычесть старую запись, прибавить новую. Полная
    /// пересборка из истории стёрла бы месяцы, для которых записей уже нет.
    func testDayAggregateFollowsCleanedRecord() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func pass(speed: Double, lat: Double) -> PassedCamera {
            PassedCamera(id: UUID(), cameraID: Int(lat * 1e4), typeRaw: "Стационар радар",
                         location: "к", speedKmh: speed, date: start,
                         lat: lat, lon: 69.21, limitKmh: 60)
        }
        // Один честный проезд в лимите и один «чужой» с превышением.
        let dirty = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                               endedAt: start.addingTimeInterval(1800),
                               distanceMeters: 10_000, maxSpeedKmh: 90,
                               passed: [pass(speed: 55, lat: 41.30),
                                        pass(speed: 95, lat: 41.304)],
                               score: 75)
        let clean = TripRecord(id: dirty.id, startedAt: start, endedAt: dirty.endedAt,
                               distanceMeters: 10_000, maxSpeedKmh: 90,
                               passed: [pass(speed: 55, lat: 41.30)], score: 100)

        var days = TripDayBook.folded(dirty, into: [])
        XCTAssertEqual(days.first?.overPasses, 1)
        XCTAssertGreaterThan(days.first?.fineRisk ?? 0, 0)

        days = TripDayBook.unfolded(dirty, from: days)
        days = TripDayBook.folded(clean, into: days)

        let day = try? XCTUnwrap(days.first)
        XCTAssertEqual(day?.trips, 1, "поездка не должна раздвоиться")
        XCTAssertEqual(day?.distanceMeters ?? 0, 10_000, accuracy: 1)
        XCTAssertEqual(day?.overPasses, 0, "ложное превышение ушло из дня")
        XCTAssertEqual(day?.fineRisk ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(day?.cleanPasses, 1)
        XCTAssertEqual(day?.rating, 100, "балл пересчитан вслед за записью")
    }

    /// Прошли близко, но по дублёру: расстояние молчит, геометрия — нет.
    func testCloseButOnParallelCarriagewayIsRejected() {
        var tracking = PassTracking()
        // Камера в 38 м вбок: в порог траверза (40 м) укладывается…
        let camera = avenueCamera(lat: 41.30 + north(38))
        let coordinate = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.21)
        _ = tracking.update(nearest: camera, nearestDistance: 38, coordinate: coordinate,
                            speedKmh: 55, roadLimit: 60, radius: 500,
                            offRoad: { _, _ in true })   // …но геометрия доказала обратное
        XCTAssertTrue(tracking.flush().isEmpty)
    }
}
