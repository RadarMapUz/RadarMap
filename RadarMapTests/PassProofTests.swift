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

    // MARK: - Поперёк оси у самой камеры (14.10)

    /// Камера на дороге север–юг с огрызком дороги в 32 м — как на обычном
    /// перекрёстке, где OSM режет улицу: за краем огрызка боковое отклонение
    /// честно молчит (nil), и первый гейт не может ничего доказать.
    private func junctionCamera(cls: String = "primary", needsReview: Bool? = nil) -> Camera {
        let half = Int((16.0 / 111_320 * 1e6).rounded())
        return Camera(id: 9, region: "", city: "", location: "перекрёсток",
                      lat: 41.30, lon: 69.21, type: "Стационар камера",
                      violations: [], needsReview: needsReview,
                      axis: 0, dir: 180, lanes: 3, cls: cls,
                      road: [half, 0, -half, 0], split: true)
    }

    /// Прямой проезд через траверз в `offset` м от камеры курсом `bearing`
    /// (фикс каждые 14 м — 50 км/ч), `course(i)` — курс фикса, которому
    /// поверил фильтр. Возвращает записанные проезды, хвост — как flush в
    /// конце поездки.
    private func drive(past camera: Camera, bearing: Double, offset: Double = 15,
                       speed: Double = 50, accuracy: Double = 6, recordProof: Bool = true,
                       course: (Int) -> Double) -> [PassTracking.Pass] {
        var tracking = PassTracking()
        let closest = GeoMath.destination(from: camera.coordinate, bearing: bearing + 90,
                                          distanceMeters: offset)
        var passes: [PassTracking.Pass] = []
        for (i, along) in stride(from: -420.0, through: 600, by: 14).enumerated() {
            let at = GeoMath.destination(from: closest, bearing: bearing, distanceMeters: along)
            let distance = GeoMath.fastDistance(at.latitude, at.longitude, camera.lat, camera.lon)
            passes += tracking.update(nearest: camera, nearestDistance: distance, coordinate: at,
                                      speedKmh: speed, roadLimit: 60, radius: 400,
                                      course: course(i),
                                      offRoad: PassGeometry.isProvenOffRoad(camera:at:),
                                      axisDeviation: { cam, point, heading in
                                          recordProof ? PassGeometry.axisDeviation(camera: cam, at: point,
                                                                                   course: heading, accuracy: accuracy)
                                                      : nil
                                      })
        }
        return passes + tracking.flush()
    }

    /// Поперечная улица под 60°: траверз в 15 м, огрызок дороги камеры
    /// короче нас — прежние гейты проезд пропускали. Курс у камеры поперёк её
    /// оси — проезд не наш.
    func testCrossingAtSixtyDegreesIsNotRecorded() {
        let camera = junctionCamera()
        XCTAssertEqual(drive(past: camera, bearing: 60, recordProof: false) { _ in 60 }.count, 1,
                       "до 14.10: траверз 15 м, бокового доказательства нет — записывался")
        XCTAssertTrue(drive(past: camera, bearing: 60) { _ in 60 }.isEmpty,
                      "поперечная улица перекрёстка — не наш проезд")
    }

    /// По своей дороге с шумом курса ±20° — проезд записан.
    func testAlongTheAxisWithHeadingNoiseIsRecorded() {
        let camera = junctionCamera()
        let passes = drive(past: camera, bearing: 0, offset: 3) { $0.isMultiple(of: 2) ? 20 : 340 }
        XCTAssertEqual(passes.count, 1, "шум курса — не пересечение")
        XCTAssertEqual(passes.first?.speedKmh, 50)
    }

    /// Курсу верить нельзя (−1) — доказательства нет, решают прежние гейты.
    func testUnknownCourseKeepsTheOldGates() {
        let camera = junctionCamera()
        XCTAssertEqual(drive(past: camera, bearing: 60) { _ in -1 }.count, 1)
    }

    /// Ползком курс не доказательство — как и для гейтов оповещений.
    func testCrawlingCourseProvesNothing() {
        let camera = junctionCamera()
        let crawl = AppConfig.directionalMinSpeedKmh - 1
        XCTAssertEqual(drive(past: camera, bearing: 60, speed: crawl) { _ in 60 }.count, 1)
    }

    /// Ось снапа на проезд/жилую зону и ось непроверенной камеры ничего не
    /// доказывают: радар трассы, севший на поперечный проезд, иначе не
    /// писался бы никогда.
    func testUntrustedAxisGivesNoCrossingProof() {
        for cls in ["service", "living_street", "track", "footway"] {
            XCTAssertEqual(drive(past: junctionCamera(cls: cls), bearing: 60) { _ in 60 }.count, 1, cls)
        }
        XCTAssertEqual(drive(past: junctionCamera(needsReview: true), bearing: 60) { _ in 60 }.count, 1,
                       "позиция не проверена — ось может быть осью поперечной улицы")
    }

    /// Свернули с поперечной улицы на дорогу камеры за 25 м до неё: у самой
    /// камеры большинство тиков — вдоль её оси, проезд записан.
    func testTurningOntoTheCameraRoadBeforeItIsRecorded() {
        let camera = junctionCamera()
        let junction = GeoMath.destination(from: camera.coordinate, bearing: 180, distanceMeters: 25)
        var tracking = PassTracking()
        var points: [(CLLocationCoordinate2D, Double)] = []
        for along in stride(from: -420.0, to: 0, by: 14) {   // с запада на восток
            points.append((GeoMath.destination(from: junction, bearing: 90, distanceMeters: along), 90))
        }
        for along in stride(from: 0.0, through: 600, by: 14) {   // на север, мимо камеры
            points.append((GeoMath.destination(from: junction, bearing: 0, distanceMeters: along), 0))
        }
        var passes: [PassTracking.Pass] = []
        for (at, course) in points {
            let distance = GeoMath.fastDistance(at.latitude, at.longitude, camera.lat, camera.lon)
            passes += tracking.update(nearest: camera, nearestDistance: distance, coordinate: at,
                                      speedKmh: 50, roadLimit: 60, radius: 400, course: course,
                                      offRoad: PassGeometry.isProvenOffRoad(camera:at:),
                                      axisDeviation: {
                                          PassGeometry.axisDeviation(camera: $0, at: $1, course: $2, accuracy: 6)
                                      })
        }
        XCTAssertEqual((passes + tracking.flush()).count, 1)
    }

    /// Медиана, а не один тик: тик сближения у 2676 был самым «прямым» из
    /// восьми (52°), а один кривой тик не перевешивает дорогу.
    func testCrossingProofIsTheMedianOfTheTraverse() {
        XCTAssertFalse(PassGeometry.isProvenCrossing([]), "курса не было — доказательства нет")
        XCTAssertTrue(PassGeometry.isProvenCrossing([56.5, 52.3, 63.2, 56.4, 52.3, 63.3, 56.5, 52.3]))
        XCTAssertFalse(PassGeometry.isProvenCrossing([12, 85, 15]), "один кривой тик")
        XCTAssertFalse(PassGeometry.isProvenCrossing([AppConfig.passCrossingMinAngle]), "порог не включительно")
    }

    /// Отклонение — от оси куска дороги у точки, по модулю 180°: ехать по
    /// дороге на юг — то же, что на север.
    func testAxisDeviationIsUndirected() throws {
        let camera = junctionCamera()
        XCTAssertEqual(try XCTUnwrap(PassGeometry.axisDeviation(camera: camera, at: camera.coordinate,
                                                                course: 180, accuracy: 5)), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(PassGeometry.axisDeviation(camera: camera, at: camera.coordinate,
                                                                course: 300, accuracy: 5)), 60, accuracy: 0.5)
        XCTAssertNil(PassGeometry.axisDeviation(camera: camera, at: camera.coordinate, course: -1, accuracy: 5))
        XCTAssertNil(PassGeometry.axisDeviation(camera: camera, at: camera.coordinate, course: 300,
                                                accuracy: AppConfig.courseProofMaxAccuracyMeters + 1),
                     "курс по земле на плохом фиксе — шум")
    }

    /// Фиксы уровня Wi-Fi: курс по земле — шум, доказательства нет, проезд
    /// судят прежние гейты (сценарий «каньон» требует записи своей камеры).
    func testPoorFixesGiveNoCrossingProof() {
        let camera = junctionCamera()
        XCTAssertEqual(drive(past: camera, bearing: 60, accuracy: 60) { _ in 60 }.count, 1)
    }

    /// Камера 2676 (Руставели, ось 39°), прогон 13.3: проехали по Бобуру
    /// (~341°) в 17 м от неё, и проезд лёг в историю. Тики — из журнала
    /// прогона: координата и курс, которому поверил фильтр (336/342/346° —
    /// курс по земле на неравных шагах симулятора).
    func testCamera2676FromTheCityDriveIsNotRecorded() {
        let camera = Camera(id: 2676, region: "Toshkent shahar", city: "Yakkasaroy tumani",
                            location: "Shota Rustaveli ko'chasi", lat: 41.285684, lon: 69.253794,
                            type: "Стационар камера", violations: [], needsReview: nil,
                            axis: 40, dir: 220, lanes: 3, cls: "primary",
                            road: [81, 79, -139, -155], split: true)
        let ticks: [(lat: Double, lon: Double, course: Double)] = [
            (41.283887, 69.254390, 346.7), (41.284002, 69.254322, 336.1), (41.284122, 69.254272, 342.5),
            (41.284132, 69.254281, 346.6), (41.284247, 69.254213, 336.2), (41.284367, 69.254163, 342.5),
            (41.284378, 69.254172, 346.6), (41.284492, 69.254104, 336.1), (41.284612, 69.254054, 342.4),
            (41.284623, 69.254063, 346.6), (41.284738, 69.253995, 336.1), (41.284857, 69.253945, 342.4),
            (41.284868, 69.253954, 346.6), (41.284983, 69.253886, 336.1), (41.285103, 69.253836, 342.5),
            (41.285113, 69.253845, 346.6), (41.285227, 69.253775, 335.4), (41.285347, 69.253724, 342.1),
            (41.285352, 69.253735, 346.3), (41.285466, 69.253666, 335.5), (41.285587, 69.253614, 342.2),
            (41.285592, 69.253625, 346.4), (41.285706, 69.253555, 335.4), (41.285826, 69.253504, 342.1),
            (41.285831, 69.253515, 346.3), (41.285946, 69.253445, 335.5), (41.286065, 69.253394, 342.2),
            (41.286071, 69.253405, 346.4), (41.286185, 69.253336, 335.6), (41.286305, 69.253285, 342.3),
            (41.286310, 69.253296, 346.5), (41.286425, 69.253226, 335.5), (41.286545, 69.253175, 342.2),
            (41.286550, 69.253186, 346.4), (41.286664, 69.253116, 335.4), (41.286785, 69.253065, 342.2),
            (41.286789, 69.253076, 346.4), (41.286903, 69.253007, 335.5), (41.287022, 69.252956, 342.2),
            (41.287029, 69.252966, 346.4), (41.287144, 69.252896, 335.4), (41.287263, 69.252845, 342.2),
            (41.287268, 69.252856, 346.4), (41.287383, 69.252789, 336.4), (41.287503, 69.252739, 342.6),
            (41.287516, 69.252747, 346.7), (41.287631, 69.252680, 336.4), (41.287750, 69.252630, 342.5),
            (41.287764, 69.252638, 346.6), (41.287879, 69.252571, 336.4), (41.287999, 69.252521, 342.6),
            (41.288012, 69.252529, 346.7), (41.288127, 69.252462, 336.4), (41.288248, 69.252411, 342.6),
            (41.288248, 69.252411, 342.6), (41.288260, 69.252420, 346.7), (41.288376, 69.252353, 336.4),
            (41.288496, 69.252303, 342.6), (41.288509, 69.252311, 346.7), (41.288624, 69.252244, 336.4),
            (41.288744, 69.252194, 342.6), (41.288757, 69.252202, 346.7), (41.288873, 69.252135, 336.4),
            (41.288993, 69.252084, 342.6), (41.289005, 69.252093, 346.7), (41.289120, 69.252026, 336.4),
            (41.289240, 69.251976, 342.5), (41.289253, 69.251984, 346.6), (41.289369, 69.251917, 336.4),
            (41.289489, 69.251867, 342.6), (41.289501, 69.251875, 346.7), (41.289616, 69.251808, 336.4),
            (41.289737, 69.251758, 342.6), (41.289749, 69.251766, 346.7), (41.289864, 69.251699, 336.4),
            (41.289984, 69.251649, 342.5), (41.289997, 69.251657, 346.6), (41.290113, 69.251590, 336.4),
            (41.290233, 69.251539, 342.6),
        ]
        let radius = AlertEngine.effectiveRadius(speedKmh: 50, baseRadius: AppConfig.alertRadius)
        func run(recordProof: Bool) -> [PassTracking.Pass] {
            var tracking = PassTracking()
            var passes: [PassTracking.Pass] = []
            for (i, tick) in ticks.enumerated() {
                let at = CLLocationCoordinate2D(latitude: tick.lat, longitude: tick.lon)
                let distance = GeoMath.fastDistance(tick.lat, tick.lon, camera.lat, camera.lon)
                // Ближайшей она была на первом тике (206 м) — дальше её вёл трекер.
                passes += tracking.update(nearest: i == 0 ? camera : nil,
                                          nearestDistance: i == 0 ? distance : nil,
                                          coordinate: at, speedKmh: 50, roadLimit: 60, radius: radius,
                                          course: tick.course,
                                          offRoad: PassGeometry.isProvenOffRoad(camera:at:),
                                          axisDeviation: { cam, point, heading in
                                              recordProof ? PassGeometry.axisDeviation(camera: cam, at: point,
                                                                                       course: heading, accuracy: 5)
                                                          : nil
                                          })
            }
            return passes + tracking.flush()
        }
        XCTAssertEqual(run(recordProof: false).count, 1, "так было в прогоне: проезд записан")
        XCTAssertTrue(run(recordProof: true).isEmpty, "поперечная улица — не наш проезд")
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
