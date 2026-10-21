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

    /// Снап на проезд или жилую зону — промах сопоставления: радары 3135 и
    /// 3136 стоят на трассе D006, а снап посадил их на поперечный проезд и
    /// жилую улицу, и гейт оси глушил их на 100 км/ч (прогон 13.3). Такой
    /// оси не верим; на настоящей проезжей части гейт оси работает как раньше.
    func testCrossAxisFromMinorRoadSnapDoesNotMute() {
        for cls in ["service", "living_street", "track"] {
            let radar = camera(ahead: 300, east: 15, roadBearing: 90, cls: cls, axis: 90)
            XCTAssertTrue(LocationGates.isOnOurRoad(radar, in: situation(), isOnRoute: false), cls)
        }
        let onCarriageway = camera(ahead: 300, east: 15, roadBearing: 90, cls: "primary", axis: 90)
        XCTAssertFalse(LocationGates.isOnOurRoad(onCarriageway, in: situation(), isOnRoute: false),
                       "поперёк по оси настоящей проезжей части — по-прежнему не наша")
    }

    /// «Стороны поделены» на второстепенном снапе тоже не доказаны: twin и
    /// split посчитаны для чужого проезда.
    func testMinorRoadSnapNeverProvesSides() {
        let twin = camera(ahead: 300, roadBearing: 0, cls: "service", dir: 180, twin: true)
        XCTAssertFalse(twin.sidesAreProven)
        XCTAssertTrue(LocationGates.isOnOurRoad(twin, in: situation(), isOnRoute: false),
                      "встречная по направлению, но доказательства нет — предупреждаем")
        let proven = camera(ahead: 300, roadBearing: 0, cls: "primary", dir: 180, twin: true)
        XCTAssertFalse(LocationGates.isOnOurRoad(proven, in: situation(), isOnRoute: false))
    }

    // MARK: - Непроверенная позиция (needsReview, 14.13)

    /// Камера с непроверенной позицией (снап не нашёл её дорогу по имени)
    /// прямо по курсу на нашей дороге, а профиль ей снап дал поперечной
    /// улицы: ось и кусок дороги поперёк нас. Такая ось — не доказательство:
    /// предупреждаем. Та же геометрия у проверенной камеры — по-прежнему
    /// поперечная улица.
    func testNeedsReviewCrossAxisDoesNotMute() {
        let doubtful = camera(ahead: 300, roadBearing: 90, axis: 90, needsReview: true)
        XCTAssertTrue(LocationGates.isOnOurRoad(doubtful, in: situation(), isOnRoute: false))
        XCTAssertEqual(LocationGates.verdict(doubtful, in: situation(), isOnRoute: false), .ours)
        let bare = camera(ahead: 100, roadBearing: nil, axis: 90, needsReview: true)
        XCTAssertTrue(LocationGates.isOnOurRoad(bare, in: situation(), isOnRoute: false),
                      "одна ось без куска дороги — тоже не доказательство")
        let checked = camera(ahead: 300, roadBearing: 90, axis: 90)
        XCTAssertEqual(LocationGates.verdict(checked, in: situation(), isOnRoute: false), .provenAxis)
    }

    /// Направление и «вне её проезжей части» при поделённых сторонах — тоже
    /// профиль, снятый в непроверенной точке: стороны не доказаны, камера не
    /// глушится, решает щедрый коридор.
    func testNeedsReviewNeverProvesDirectionOrCarriageway() {
        let oncoming = camera(ahead: 300, roadBearing: 0, dir: 180, twin: true, needsReview: true)
        XCTAssertFalse(oncoming.profileMayMute)
        XCTAssertFalse(oncoming.sidesAreProven)
        XCTAssertFalse(oncoming.allowsDirectionGate)
        XCTAssertNil(oncoming.markerDirection, "клин на маркере — только там, где гейт вправе молчать")
        XCTAssertEqual(LocationGates.verdict(oncoming, in: situation(), isOnRoute: false), .ours)
        let aside = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350, twin: true, needsReview: true)
        XCTAssertTrue(LocationGates.isOnOurRoad(aside, in: situation(), isOnRoute: false))
        // Контроль: проверенные — по-прежнему доказанная тишина.
        XCTAssertEqual(LocationGates.verdict(camera(ahead: 300, roadBearing: 0, dir: 180, twin: true),
                                             in: situation(), isOnRoute: false), .provenDirection)
        XCTAssertEqual(LocationGates.verdict(camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350,
                                                    twin: true),
                                             in: situation(), isOnRoute: false), .provenOffCarriageway)
    }

    /// Коридор для непроверенной позиции — трассовый и в городе: камера в
    /// 70 м вбок на 300 м впереди (городской коридор там 52 м) — наша, если
    /// позиция не проверена, и нет, если проверена.
    func testNeedsReviewGetsTheGenerousCorridor() {
        let doubtful = camera(ahead: 300, east: 70, roadBearing: nil, cls: nil, needsReview: true)
        XCTAssertEqual(LocationGates.verdict(doubtful, in: situation(), isOnRoute: false), .ours)
        let checked = camera(ahead: 300, east: 70, roadBearing: nil, cls: nil)
        XCTAssertEqual(LocationGates.verdict(checked, in: situation(), isOnRoute: false), .outsideCorridor)
        // Позади — и для неё позади: «щедрый» не значит «всегда».
        let behind = camera(ahead: -300, roadBearing: nil, cls: nil, needsReview: true)
        XCTAssertFalse(LocationGates.isOnOurRoad(behind, in: situation(), isOnRoute: false))
    }

    /// Новый подъезд после разворота: «своя дорога» камеры с непроверенной
    /// позицией — не её профиль (он может быть поперечной улицы), а линия, по
    /// которой мы мимо неё проехали.
    func testNeedsReviewReapproachUsesThePassLine() {
        let doubtful = camera(ahead: 300, roadBearing: 90, axis: 90, needsReview: true)
        XCTAssertNil(PassGeometry.ownRoadOffset(camera: doubtful, at: me))
        let passLine = AlertEngine.PassLine(lat: doubtful.lat, lon: doubtful.lon, course: 0, distance: 5,
                                              accuracy: 5)
        XCTAssertTrue(LocationGates.isReapproach(doubtful, in: situation(), passLine: passLine),
                      "едем по той же линии, что проезжали, — подъезд новый")
        let checked = camera(ahead: 300, roadBearing: 90, axis: 90)
        XCTAssertNotNil(PassGeometry.ownRoadOffset(camera: checked, at: me))
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

    // MARK: - Погрешность фикса (14.14)

    /// Фикс в 40 м вбок от своей дороги: каньон испортил позицию, а
    /// доплеровский курс уверенный, и LocationFilter ему верит — гейты
    /// работают. Камера своей дороги впереди в ближней зоне, её кусок до нас
    /// не дотягивается — решает коридор, а он мерится от линии курса через
    /// НАШУ точку: на 40 м вбок узкий коридор доказанных сторон (18 м) и
    /// городской (30 м) выталкивали свою камеру. Допуск растёт с погрешностью
    /// фикса — камера наша. На хорошем фиксе та же геометрия — по-прежнему
    /// чужая проезжая часть: 40 м вбок при точности 5 м — не погрешность.
    func testPoorFixSidewaysKeepsTheOwnCamera() {
        let proven = camera(ahead: 120, east: 40, roadBearing: 0, roadHalf: 30, dir: 0, twin: true)
        XCTAssertTrue(proven.sidesAreProven)
        let unproven = camera(ahead: 120, east: 40, roadBearing: 0, roadHalf: 30, split: true)
        let bare = camera(ahead: 120, east: 40, roadBearing: nil, cls: nil)
        for own in [proven, unproven, bare] {
            XCTAssertEqual(LocationGates.verdict(own, in: situation(accuracy: 40), isOnRoute: false), .ours,
                           "точность 40 м, сдвиг 40 м: \(own.cls ?? "без профиля"), стороны \(own.sidesAreProven)")
            XCTAssertEqual(LocationGates.verdict(own, in: situation(accuracy: 5), isOnRoute: false),
                           .outsideCorridor, "хороший фикс — без изменений")
        }
        // Трасса — так же, у неё коридор шире.
        XCTAssertEqual(LocationGates.verdict(camera(ahead: 120, east: 70, roadBearing: nil, cls: nil),
                                             in: situation(accuracy: 40, context: .highway), isOnRoute: false),
                       .ours)
    }

    /// «Вне её проезжей части» — доказательство, и на нём камера с
    /// поделёнными сторонами молчит. Фикс хуже `courseProofMaxAccuracyMeters`
    /// его не даёт: боковое отклонение от куска дороги меряется от точки,
    /// которая сама может стоять на соседней проезжей части. До порога
    /// включительно доказательство прежнее; хуже — решает коридор (тоже
    /// расширенный погрешностью), и вердикт — эвристика, а не «доказано».
    func testPoorFixProvesNothingOffTheCarriageway() {
        let aside = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350, twin: true)
        XCTAssertEqual(LocationGates.verdict(aside, in: situation(accuracy: 5), isOnRoute: false),
                       .provenOffCarriageway)
        XCTAssertEqual(LocationGates.verdict(aside, in: situation(
            accuracy: AppConfig.courseProofMaxAccuracyMeters), isOnRoute: false), .provenOffCarriageway,
                       "на пороге доказательство ещё в силе")
        let justWorse = LocationGates.verdict(aside, in: situation(
            accuracy: AppConfig.courseProofMaxAccuracyMeters + 1), isOnRoute: false)
        XCTAssertEqual(justWorse.provenNotOurs, false, "хуже порога — не доказательство: \(justWorse)")
        XCTAssertEqual(LocationGates.verdict(aside, in: situation(accuracy: 40), isOnRoute: false), .ours,
                       "на 300 м коридор с погрешностью 40 м её принимает")
        // Направление и ось — от курса, а не от точки: доплеровскому курсу на
        // плохой позиции гейты верят (14.13), их доказательства не тронуты.
        XCTAssertEqual(LocationGates.verdict(camera(ahead: 300, roadBearing: 0, dir: 180, twin: true),
                                             in: situation(accuracy: 50), isOnRoute: false), .provenDirection)
        XCTAssertEqual(LocationGates.verdict(camera(ahead: 100, roadBearing: nil, axis: 90),
                                             in: situation(accuracy: 50), isOnRoute: false), .provenAxis)
    }

    /// Расширение ограничено: параллельная улица в 120 м вбок вне коридора
    /// и на хорошем фиксе, и на плохом — 40 м погрешности не делают её нашей.
    func testParallelStreetStaysOutsideOnAnyFix() {
        let bare = camera(ahead: 200, east: 120, roadBearing: nil, cls: nil)
        let proven = camera(ahead: 200, east: 120, roadBearing: 0, roadHalf: 30, dir: 0, twin: true)
        for parallel in [bare, proven] {
            for accuracy in [5.0, 25, 40] {
                XCTAssertEqual(LocationGates.verdict(parallel, in: situation(accuracy: accuracy), isOnRoute: false),
                               .outsideCorridor, "точность \(Int(accuracy)) м")
            }
        }
    }

    /// Точность неизвестна (≤ 0) — фильтр такой фикс не пропускает, и с
    /// курсом гейты его не видят; но если увидят — неизвестность в пользу
    /// предупреждения: как худший принятый фикс, без доказательства по точке.
    func testUnknownAccuracyIsTreatedAsThePoorest() {
        let aside = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350, twin: true)
        XCTAssertNotEqual(LocationGates.verdict(aside, in: situation(accuracy: -1), isOnRoute: false),
                          .provenOffCarriageway)
        let own = camera(ahead: 120, east: 40, roadBearing: 0, roadHalf: 30, dir: 0, twin: true)
        XCTAssertEqual(LocationGates.verdict(own, in: situation(accuracy: -1), isOnRoute: false), .ours)
    }

    // MARK: - Новый подъезд на плохом фиксе (14.15)

    /// Линия проезда через камеру по курсу `course`; точка сближения — в
    /// `west` м к западу от камеры (сдвинутый фикс), снятая с точностью `accuracy`.
    private func passLine(through camera: Camera, west: Double = 0, course: Double = 0,
                          accuracy: Double) -> AlertEngine.PassLine {
        let at = GeoMath.destination(from: camera.coordinate, bearing: 270, distanceMeters: west)
        return AlertEngine.PassLine(lat: at.latitude, lon: at.longitude, course: course, distance: 5,
                                    accuracy: accuracy)
    }

    /// После разворота едем обратно к проеханной камере по встречной
    /// проезжей части (12 м от её дороги; на неразделённой — соседняя полоса,
    /// 4 м), а фикс уехал от её дороги на свою погрешность. Своя дорога
    /// мерится от НАШЕЙ точки: 12 + 50 = 62 м при пределе 50 — до 14.15
    /// «чужая дорога», серия не забывалась, и камера молчала весь обратный
    /// подъезд. Теперь предел шире на погрешность сверх 10 м, как коридор.
    /// У треноги своя дорога — линия проезда, и сближение было на таком же
    /// фиксе, сдвинутом в другую сторону: ошибается и сама линия — запас на
    /// обе точки (с одной только нашей 12 + 2·35 = 82 м не влезали бы в 75).
    func testPoorFixUTurnBackPastTheSameCameraRearms() {
        for accuracy in [35.0, 50, AppConfig.maxHorizontalAccuracyMeters] {
            let poor = situation(accuracy: accuracy)
            let snapped = camera(ahead: 300, east: -(12 + accuracy), roadBearing: 0, axis: 0, split: true)
            let undivided = camera(ahead: 300, east: -(4 + accuracy), roadBearing: 0, axis: 0, split: false)
            XCTAssertFalse(snapped.sidesAreProven)
            XCTAssertTrue(undivided.sidesAreProven)
            let tripod = camera(ahead: 300, east: -(12 + accuracy), roadBearing: nil, cls: nil, type: "Тренога")
            let line = passLine(through: tripod, west: accuracy, accuracy: accuracy)
            let cases: [(Camera, AlertEngine.PassLine?, String)] = [
                (snapped, nil, "снап"), (undivided, nil, "неразделённая"), (tripod, line, "тренога"),
            ]
            for (own, passLine, label) in cases {
                XCTAssertTrue(LocationGates.isReapproach(own, in: poor, passLine: passLine),
                              "\(label), точность и сдвиг \(Int(accuracy)) м")
            }
        }
        // Неизвестная точность (≤ 0) — как худшая принятая.
        let snapped = camera(ahead: 300, east: -62, roadBearing: 0, axis: 0, split: true)
        XCTAssertTrue(LocationGates.isReapproach(snapped, in: situation(accuracy: -1), passLine: nil))
        // Хороший фикс в той же геометрии: 62 м при точности 5 м — другая дорога.
        XCTAssertFalse(LocationGates.isReapproach(snapped, in: situation(accuracy: 5), passLine: nil))
    }

    /// На хорошем GPS (до базы 10 м включительно) предел своей дороги —
    /// ровно прежний: у предела — новый подъезд, чуть за ним — нет (дублёр,
    /// петля клевера). Камера в 500 м впереди: коридор там шире предела, и
    /// решает именно своя дорога.
    func testGoodFixReapproachLimitIsUnchanged() {
        for accuracy in [5.0, AppConfig.corridorAccuracyBaselineMeters] {
            let good = situation(accuracy: accuracy)
            for split in [true, false] {
                let limit = PassGeometry.reapproachLimit(for: camera(ahead: 500, roadBearing: 0, axis: 0, split: split))
                let near = camera(ahead: 500, east: -(limit - 1), roadBearing: 0, axis: 0, split: split)
                let far = camera(ahead: 500, east: -(limit + 1), roadBearing: 0, axis: 0, split: split)
                let label = "split \(split), предел \(Int(limit)), точность \(Int(accuracy))"
                XCTAssertTrue(LocationGates.isOnOurRoad(far, in: good, isOnRoute: false), "коридор пропускает — \(label)")
                XCTAssertTrue(LocationGates.isReapproach(near, in: good, passLine: nil), label)
                XCTAssertFalse(LocationGates.isReapproach(far, in: good, passLine: nil), label)
            }
            let tripodNear = camera(ahead: 500, east: -49, roadBearing: nil, cls: nil, type: "Тренога")
            let tripodFar = camera(ahead: 500, east: -51, roadBearing: nil, cls: nil, type: "Тренога")
            XCTAssertEqual(PassGeometry.reapproachLimit(for: tripodFar), AppConfig.reapproachUnprovenMeters)
            XCTAssertTrue(LocationGates.isReapproach(tripodNear, in: good,
                                                     passLine: passLine(through: tripodNear, accuracy: accuracy)))
            XCTAssertFalse(LocationGates.isReapproach(tripodFar, in: good,
                                                      passLine: passLine(through: tripodFar, accuracy: accuracy)))
        }
    }

    /// Плохой фикс чужую дорогу своей не делает. Мы на дороге в 200 м от
    /// дороги камеры, и курс смотрит прямо на камеру (дорога сходится к её
    /// перекрёстку под 27°: гейт оси пропускает, коридор тоже — решает своя
    /// дорога). На худшем принятом фиксе предел шире на 55 м, у линии
    /// проезда — на 110, если и сближение было на худшем: до 200 м далеко.
    func testPoorFixDoesNotRearmFromAnotherRoad() {
        let snapped = camera(ahead: 400, east: -200, roadBearing: 0, axis: 0, split: true)
        let tripod = camera(ahead: 400, east: -200, roadBearing: nil, cls: nil, type: "Тренога")
        let line = passLine(through: tripod, accuracy: AppConfig.maxHorizontalAccuracyMeters)
        let cases: [(Camera, AlertEngine.PassLine?, String)] = [(snapped, nil, "снап"), (tripod, line, "тренога")]
        let course = GeoMath.bearing(from: me, to: snapped.coordinate)
        for accuracy in [5.0, 35, AppConfig.maxHorizontalAccuracyMeters, -1] {
            let s = situation(course: course, accuracy: accuracy)
            for (other, passLine, label) in cases {
                let text = "\(label), точность \(Int(accuracy))"
                XCTAssertTrue(LocationGates.isClearlyAhead(other, in: s), text)
                XCTAssertTrue(LocationGates.isOnOurRoad(other, in: s, isOnRoute: false), "решает своя дорога — \(text)")
                XCTAssertFalse(LocationGates.isReapproach(other, in: s, passLine: passLine), text)
            }
        }
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

    // MARK: - Вердикт с причиной (14.10)

    /// Охват предупреждений не считает промахом тишину, которую гейт ДОКАЗАЛ:
    /// встречный двойник, поперечная ось, чужая проезжая часть при поделённых
    /// сторонах. Причина — из той же функции, что решает «наша ли».
    func testVerdictNamesTheProof() {
        let oncoming = camera(ahead: 300, roadBearing: 0, dir: 180, twin: true)
        XCTAssertEqual(LocationGates.verdict(oncoming, in: situation(), isOnRoute: false), .provenDirection)
        let crossing = camera(ahead: 100, roadBearing: nil, axis: 90)
        XCTAssertEqual(LocationGates.verdict(crossing, in: situation(), isOnRoute: false), .provenAxis)
        let aside = camera(ahead: 300, east: 60, roadBearing: 0, roadHalf: 350, twin: true)
        XCTAssertEqual(LocationGates.verdict(aside, in: situation(), isOnRoute: false), .provenOffCarriageway)
        for proven in [oncoming, crossing, aside] {
            XCTAssertEqual(LocationGates.verdict(proven, in: situation(), isOnRoute: false).provenNotOurs, true)
        }
    }

    /// Эвристика и «позади» — не доказательство; стоим без курса — гейты
    /// воздержались. Снап на проезд не доказывает «не наша» и по оси.
    func testVerdictWithoutProofIsNotAProof() {
        let farAside = camera(ahead: 300, east: 150, roadBearing: nil, cls: nil)
        XCTAssertEqual(LocationGates.verdict(farAside, in: situation(), isOnRoute: false), .outsideCorridor)
        // Кусок дороги дотягивается до нас: мы на её проезжей части, она позади.
        let behind = camera(ahead: -300, roadBearing: 0, roadHalf: 350)
        XCTAssertEqual(LocationGates.verdict(behind, in: situation(), isOnRoute: false), .behind)
        let minorCrossing = camera(ahead: 300, east: 15, roadBearing: 90, cls: "service", axis: 90)
        XCTAssertEqual(LocationGates.verdict(minorCrossing, in: situation(), isOnRoute: false).provenNotOurs,
                       false)
        let unprovenOncoming = camera(ahead: 300, roadBearing: 0, dir: 180, split: true)
        XCTAssertEqual(LocationGates.verdict(unprovenOncoming, in: situation(), isOnRoute: false), .ours,
                       "стороны не доказаны — наша, как и раньше")
        XCTAssertEqual(LocationGates.verdict(behind, in: situation(course: -1), isOnRoute: false), .unfiltered)
        XCTAssertNil(LocationGates.Verdict.unfiltered.provenNotOurs)
        XCTAssertEqual(LocationGates.verdict(farAside, in: situation(), isOnRoute: true), .ours,
                       "маршрут сильнее геометрии")
    }

    /// «Наша ли» — ровно вердикт: один ответ на оба вызова, на всей сетке
    /// положений, курсов и профилей.
    func testIsOnOurRoadIsExactlyTheVerdict() {
        var checked = 0
        for ahead in stride(from: -400.0, through: 400, by: 100) {
            for east in [0.0, 30, 70, 160] {
                for course in [-1.0, 0, 45, 90, 180] {
                    for (dir, axis, twin) in [(Int?.none, Int?.none, Bool?.none), (180, nil, true),
                                              (nil, 90, nil), (0, nil, true)] {
                        let cam = camera(ahead: ahead, east: east, roadBearing: axis.map(Double.init) ?? 0,
                                         dir: dir, axis: axis, twin: twin)
                        for onRoute in [false, true] {
                            let s = situation(course: course)
                            XCTAssertEqual(LocationGates.isOnOurRoad(cam, in: s, isOnRoute: onRoute),
                                           LocationGates.verdict(cam, in: s, isOnRoute: onRoute).isOurs)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 9 * 4 * 5 * 4 * 2)
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
