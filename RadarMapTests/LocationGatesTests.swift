//
//  LocationGatesTests.swift
//  RadarMapTests
//
//  Порядок гейтов «эта камера наша?» — то, что раньше нельзя было проверить.
//
//  Сами движки (LocationFilter, RoadCorridor, RoadShape, оси) давно покрыты
//  своими тестами, но их ПОРЯДОК и приоритеты жили в LocationService рядом с
//  CLLocationManager — и держались на внимательности читателя. Эти тесты
//  фиксируют политику целиком: маршрут сильнее геометрии, глушить можно только
//  при доказательстве, неизвестность — всегда в пользу предупреждения.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class LocationGatesTests: XCTestCase {

    private let me = CLLocationCoordinate2D(latitude: 41.3110, longitude: 69.2790)

    /// Обстановка: едем на север (курс 0) по городу с хорошим GPS.
    private func situation(course: Double = 0, speed: Double = 60,
                           accuracy: Double = 5,
                           context: AlertPolicy.Context = .city) -> LocationGates.Situation {
        LocationGates.Situation(coordinate: me, course: course, speedKmh: speed,
                                horizontalAccuracy: accuracy, context: context)
    }

    /// Камера в `aheadMeters` к северу и `eastMeters` к востоку от нас, с
    /// куском дороги через её точку под азимутом `roadBearing`.
    private func camera(ahead aheadMeters: Double, east eastMeters: Double = 0,
                        roadBearing: Double? = 0, roadHalf: Double = 100,
                        cls: String? = "primary",
                        dir: Int? = nil, axis: Int? = nil,
                        split: Bool? = nil, twin: Bool? = nil,
                        type: String = "Стационар радар",
                        needsReview: Bool? = false) -> Camera {
        var at = GeoMath.destination(from: me, bearing: 0, distanceMeters: aheadMeters)
        at = GeoMath.destination(from: at, bearing: 90, distanceMeters: eastMeters)
        var road: [Int]?
        if let roadBearing {
            var deltas: [Int] = []
            for step in [-roadHalf, 0, roadHalf] {
                let p = GeoMath.destination(from: at, bearing: roadBearing,
                                            distanceMeters: step)
                deltas.append(Int(((p.latitude - at.latitude) * 1e6).rounded()))
                deltas.append(Int(((p.longitude - at.longitude) * 1e6).rounded()))
            }
            road = deltas
        }
        return Camera(id: 1, region: "Т", city: "", location: "к",
                      lat: at.latitude, lon: at.longitude, type: type,
                      violations: [], needsReview: needsReview, axis: axis, dir: dir,
                      lanes: 2, cls: cls, road: road,
                      split: split, twin: twin)
    }

    // MARK: - Когда фильтровать нельзя вообще

    /// Стоим или курса нет — гейты выключены целиком: глушить по случайному
    /// курсу нельзя, а стоящая машина не «едет мимо» камеры.
    func testNoCourseOrStandingNeverMutes() {
        // Камера ПОЗАДИ и поперёк — худший кандидат, и всё равно «наша».
        let behind = camera(ahead: -300, roadBearing: 90, dir: 180, twin: true)
        XCTAssertTrue(LocationGates.isOnOurRoad(behind, in: situation(course: -1),
                                                isOnRoute: false))
        XCTAssertTrue(LocationGates.isOnOurRoad(behind, in: situation(speed: 4),
                                                isOnRoute: false))
    }

    // MARK: - Маршрут сильнее геометрии

    /// Камера на активном маршруте не глушится ничем: координата в реестре
    /// бывает смещена вбок, и геометрия однажды уже глушила камеру на
    /// собственном маршруте пользователя.
    func testRouteBeatsEveryGeometryGate() {
        // Встречная по направлению, поперёк по оси, в стороне от дороги —
        // всё против неё, но она на маршруте.
        let hostile = camera(ahead: 300, east: 80, roadBearing: 90,
                             dir: 180, axis: 90, twin: true)
        XCTAssertFalse(LocationGates.isOnOurRoad(hostile, in: situation(),
                                                 isOnRoute: false))
        XCTAssertTrue(LocationGates.isOnOurRoad(hostile, in: situation(),
                                                isOnRoute: true))
    }

    /// Остаток «по маршруту» — только по живому прогрессу. Пока маршрут
    /// строится (замена маршрута без сети серверным, новая цель, заезд),
    /// прогресс стоит, а машина едет: камера маршрута «через 800 м»
    /// оставалась такой полкилометра, и проеханная за это время молчала
    /// (ревью 14.2). Тогда она — как все: по прямой и через гейты.
    func testFrozenRouteProgressIsNotTrusted() {
        XCTAssertEqual(LocationGates.routeRemaining(cameraAlong: 5_000, progressAlong: 4_200,
                                                    isOffRoute: false, isProgressFrozen: false), 800)
        XCTAssertNil(LocationGates.routeRemaining(cameraAlong: 5_000, progressAlong: 4_200,
                                                  isOffRoute: false, isProgressFrozen: true),
                     "маршрут строится — прогресс застыл")
        XCTAssertNil(LocationGates.routeRemaining(cameraAlong: 5_000, progressAlong: 4_200,
                                                  isOffRoute: true, isProgressFrozen: false),
                     "съехали — проекция застыла на старой линии (S7)")
        XCTAssertNil(LocationGates.routeRemaining(cameraAlong: nil, progressAlong: 4_200,
                                                  isOffRoute: false, isProgressFrozen: false),
                     "камера не на маршруте")
        // Без остатка по маршруту кандидат — по прямой и не «маршрутный»:
        // гейты решают сами, и «маршрут сильнее геометрии» застывшей линии
        // не достаётся.
        let candidate = LocationGates.candidateDistance(straight: 300, routeRemaining: nil,
                                                        announced: false, in: situation())
        XCTAssertEqual(candidate?.distance, 300)
        XCTAssertEqual(candidate?.onRoute, false)
    }

    // MARK: - Гейт направления: только с доказанными сторонами

    /// Встречная камера с ДОКАЗАННЫМИ сторонами (парная напротив) — молчим.
    func testOppositeDirectionMutesWhenSidesProven() {
        let oncoming = camera(ahead: 300, roadBearing: 0, dir: 180, twin: true)
        XCTAssertFalse(LocationGates.isOnOurRoad(oncoming, in: situation(),
                                                 isOnRoute: false))
    }

    /// Та же встречная, но стороны НЕ доказаны (дорога разделённая, пары нет):
    /// камера вполне снимает и нашу сторону — предупреждаем. Это главный
    /// предохранитель: таких камер половина базы.
    func testOppositeDirectionWarnsWhenSidesUnproven() {
        let unproven = camera(ahead: 300, roadBearing: 0, dir: 180,
                              split: true, twin: nil)
        XCTAssertTrue(LocationGates.isOnOurRoad(unproven, in: situation(),
                                                isOnRoute: false))
    }

    // MARK: - Гейт оси: мост и перпендикулярная улица

    /// Ось дороги камеры поперёк курса — мы едем НАД ней по мосту или по
    /// перпендикулярной улице развязки. Боковое отклонение тут ноль, различает
    /// только направление.
    func testCrossAxisMutes() {
        let underBridge = camera(ahead: 100, roadBearing: nil, axis: 90)
        XCTAssertFalse(LocationGates.isOnOurRoad(underBridge, in: situation(),
                                                 isOnRoute: false))
    }

    /// Но если снап посадил камеру на тротуар (класс не проезжий), её «оси»
    /// верить нельзя — предупреждаем, несмотря на перпендикуляр.
    func testCrossAxisIgnoredWithoutTrustedProfile() {
        let onFootway = camera(ahead: 100, roadBearing: nil, cls: "footway", axis: 90)
        XCTAssertTrue(LocationGates.isOnOurRoad(onFootway, in: situation(),
                                                isOnRoute: false))
    }

    // MARK: - Кусок дороги решает в обе стороны

    /// Мы на проезжей части камеры, камера впереди — наша.
    func testOwnCarriagewayAheadIsOurs() {
        let ahead = camera(ahead: 300, roadBearing: 0)
        XCTAssertTrue(LocationGates.isOnOurRoad(ahead, in: situation(),
                                                isOnRoute: false))
    }

    /// Камера позади по курсу — уже проехали, не пугаем.
    func testBehindIsNotOurs() {
        let behind = camera(ahead: -300, roadBearing: 0)
        XCTAssertFalse(LocationGates.isOnOurRoad(behind, in: situation(),
                                                 isOnRoute: false))
    }

    /// Одна и та же геометрия — 60 м вбок от дороги камеры — решается
    /// ПО-РАЗНОМУ в зависимости от доказанности сторон. Это сердце асимметрии:
    /// доказанные стороны глушат, недоказанные обязаны предупредить (камера
    /// может снимать и нашу, обратную для неё, проезжую часть).
    ///
    /// Дорога длинная (±350 м), чтобы её кусок дотягивался до нашей позиции:
    /// на коротком куске `lateralOffset` честно отвечает nil (мы за его
    /// концом), и решал бы коридор, а не гейт куска — первый прогон этого
    /// теста поймал ровно это.
    func testOffRoadMutesOnlyWithProvenSides() {
        let proven = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350,
                            twin: true)
        XCTAssertFalse(LocationGates.isOnOurRoad(proven, in: situation(),
                                                 isOnRoute: false))
        let unproven = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350,
                              split: true, twin: nil)
        XCTAssertTrue(LocationGates.isOnOurRoad(unproven, in: situation(),
                                                isOnRoute: false))
    }

    // MARK: - Коридор: старая база и внезапные точки

    /// Камера без профиля дороги прямо по курсу — коридор принимает.
    func testBareCameraAheadOnCourseIsOurs() {
        let bare = camera(ahead: 300, roadBearing: nil, cls: nil)
        XCTAssertTrue(LocationGates.isOnOurRoad(bare, in: situation(),
                                                isOnRoute: false))
    }

    /// Камера без профиля в 150 м вбок — параллельная улица. Ровно тот случай,
    /// что пропускал старый угловой конус (±70° на 400 м — это 375 м вбок).
    func testBareCameraFarAsideIsNot() {
        let aside = camera(ahead: 300, east: 150, roadBearing: nil, cls: nil)
        XCTAssertFalse(LocationGates.isOnOurRoad(aside, in: situation(),
                                                 isOnRoute: false))
    }

    /// Внезапная точка (краудсорс) получает щедрый коридор трассы: её
    /// координату ставил человек на ходу, и промолчать из-за смещённой точки
    /// хуже, чем предупредить с запасом.
    func testSuddenPointGetsGenerousCorridor() {
        let sudden = camera(ahead: 300, east: 60, roadBearing: nil, cls: nil,
                            type: "Передвижной радар")
        XCTAssertTrue(LocationGates.isOnOurRoad(sudden, in: situation(),
                                                isOnRoute: false))
    }

    /// Направление фильтрует только в движении и с достоверным курсом: стоящая
    /// машина не «едет мимо», а случайный курс не вправе заглушить камеру
    /// (аудит 19.10: прямого теста не было).
    func testDirectionFilterNeedsSpeedAndATrustedCourse() {
        XCTAssertTrue(LocationGates.isFilteringActive(situation(course: 90, speed: 60)))
        XCTAssertFalse(LocationGates.isFilteringActive(situation(course: -1, speed: 60)), "курса нет")
        XCTAssertFalse(LocationGates.isFilteringActive(
            situation(course: 90, speed: AppConfig.directionalMinSpeedKmh - 0.1)), "почти стоим")
        XCTAssertTrue(LocationGates.isFilteringActive(
            situation(course: 0, speed: AppConfig.directionalMinSpeedKmh)), "порог включительно, север — тоже курс")
    }
}
