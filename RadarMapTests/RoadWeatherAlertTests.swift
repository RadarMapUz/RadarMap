//
//  RoadWeatherAlertTests.swift
//  RadarMapTests
//
//  Погода на перевалах (19.2): одна спокойная фраза за 20–40 км до опасной
//  точки на нашем пути — по маршруту или по ходу на трассе; не о том, что
//  позади или в стороне; не по устаревшим данным; не дважды за поездку; и
//  никогда поверх камеры — тогда «подождать», не теряя фразы.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class RoadWeatherAlertTests: XCTestCase {
    private typealias A = RoadWeatherAlert
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = CLLocationCoordinate2D(latitude: 40.90, longitude: 69.60)

    /// Трасса строго на восток: точка каждые 500 м, 80 км.
    private var eastPath: [CLLocationCoordinate2D] {
        (0...160).map { GeoMath.destination(from: start, bearing: 90, distanceMeters: Double($0) * 500) }
    }

    private func at(_ meters: Double, side: Double = 0, bearing: Double = 90) -> CLLocationCoordinate2D {
        let along = GeoMath.destination(from: start, bearing: bearing, distanceMeters: meters)
        return GeoMath.destination(from: along, bearing: bearing + 90, distanceMeters: side)
    }

    private func point(_ id: String = "kamchik-tunnel", group: String = "kamchik", at coordinate: CLLocationCoordinate2D,
                       radius: Double = 3000, hazards: [RoadWeatherPoint.Hazard] = [.fog],
                       from: TimeInterval = -1800, to: TimeInterval = 7200) -> RoadWeatherPoint {
        RoadWeatherPoint(id: id, group: group, isPass: true, coordinate: coordinate, radius: radius,
                         name: .init(ru: "Перевал Камчик", uz: "Qamchiq dovoni"),
                         place: .init(ru: "На перевале Камчик", uz: "Qamchiq dovonida"),
                         windows: hazards.map {
                             .init(hazard: $0, from: now.addingTimeInterval(from), to: now.addingTimeInterval(to))
                         })
    }

    private func snapshot(_ points: [RoadWeatherPoint], age: TimeInterval = 600) -> RoadWeatherSnapshot {
        RoadWeatherSnapshot(generated: now.addingTimeInterval(-age), points: points)
    }

    private func onRoute(_ path: [CLLocationCoordinate2D]? = nil) -> A.Situation {
        A.Situation(position: start, course: 90, speedKmh: 90, onHighway: true, pathAhead: path ?? eastPath)
    }

    private func noRoute(course: Double = 90, speed: Double = 90, highway: Bool = true) -> A.Situation {
        A.Situation(position: start, course: course, speedKmh: speed, onHighway: highway, pathAhead: nil)
    }

    private func decide(_ points: [RoadWeatherPoint], _ situation: A.Situation, cameraBusy: Bool = false,
                        voiced: Set<String> = [], age: TimeInterval = 600) -> A.Outcome {
        A.decide(snapshot: snapshot(points, age: age), situation: situation, cameraBusy: cameraBusy,
                 voiced: voiced, now: now)
    }

    private func announced(_ outcome: A.Outcome) -> A.Notice? {
        if case .announce(let notice) = outcome { return notice }
        return nil
    }

    // MARK: - На пути / не на пути

    func testPointOnRouteAheadIsAnnounced() throws {
        let notice = try XCTUnwrap(announced(decide([point(at: at(30_000, side: 150))], onRoute())))
        XCTAssertEqual(notice.key, "kamchik")
        XCTAssertEqual(notice.hazards, [.fog])
        XCTAssertEqual(notice.distance, 30_000, accuracy: 300, "расстояние — по маршруту")
        XCTAssertFalse(notice.isLate)
    }

    func testPointAwayFromTheRouteIsSilent() {
        XCTAssertEqual(decide([point(at: at(30_000, side: 3_000))], onRoute()), .silent,
                       "3 км в стороне от линии — другая дорога")
    }

    func testRouteTurningAwayBeforeThePointIsSilent() {
        // Маршрут сворачивает на север за 10 км до перевала.
        let turn = eastPath.prefix(21) + (1...60).map {
            GeoMath.destination(from: eastPath[20], bearing: 0, distanceMeters: Double($0) * 500)
        }
        XCTAssertEqual(decide([point(at: at(30_000))], onRoute(Array(turn))), .silent)
    }

    func testPointBehindIsSilent() {
        // Перевал позади: линия маршрута — только то, что впереди.
        XCTAssertEqual(decide([point(at: at(-20_000))], onRoute()), .silent)
        XCTAssertEqual(decide([point(at: at(-20_000))], noRoute()), .silent)
    }

    func testWithoutRouteOnlyAlongTheCourseOnAHighway() throws {
        let ahead = point(at: at(30_000, side: 1_500))
        XCTAssertNotNil(announced(decide([ahead], noRoute())), "по ходу, в коридоре")
        XCTAssertEqual(decide([ahead], noRoute(highway: false)), .silent, "в городе — молчим")
        XCTAssertEqual(decide([ahead], noRoute(course: -1)), .silent, "курс не доверен")
        XCTAssertEqual(decide([ahead], noRoute(speed: 20)), .silent, "ползём — курс шумит")
        XCTAssertEqual(decide([ahead], noRoute(course: 180)), .silent, "едем в другую сторону")
        XCTAssertEqual(decide([point(at: at(30_000, side: 6_000))], noRoute()), .silent,
                       "6 км вбок на 30 км — не по ходу")
    }

    // MARK: - Окно 20–40 км

    func testTooFarIsSilentUntilTheWindowOpens() throws {
        let pass = point(at: at(45_000))
        XCTAssertEqual(decide([pass], onRoute()), .silent, "45 км — рано")
        let moved = A.Situation(position: at(6_000), course: 90, speedKmh: 90, onHighway: true,
                                pathAhead: Array(eastPath.dropFirst(12)))
        let notice = try XCTUnwrap(announced(decide([pass], moved)))
        XCTAssertEqual(notice.distance, 39_000, accuracy: 600)
    }

    func testCloserThanTwentyIsStillSaidOnceButLate() throws {
        let notice = try XCTUnwrap(announced(decide([point(at: at(10_000))], onRoute())))
        XCTAssertTrue(notice.isLate, "поздно, но не молча")
    }

    func testInsideTheStretchIsSilent() {
        XCTAssertEqual(decide([point(at: at(2_000), radius: 3_000)], onRoute()), .silent,
                       "в самом тумане — водитель его видит")
    }

    // MARK: - Данные

    func testStaleDataIsSilent() {
        let pass = point(at: at(30_000))
        XCTAssertNotNil(announced(decide([pass], onRoute(), age: 3600)))
        XCTAssertEqual(decide([pass], onRoute(), age: 2 * 3600 + 60), .silent, "старше двух часов — данных нет")
        XCTAssertEqual(A.decide(snapshot: nil, situation: onRoute(), cameraBusy: false, voiced: [], now: now),
                       .silent)
    }

    func testOnlyHazardsThatWillMeetTheDriver() {
        XCTAssertEqual(decide([point(at: at(30_000), from: 3 * 3600, to: 4 * 3600)], onRoute()), .silent,
                       "туман через три часа нас не застанет")
        XCTAssertEqual(decide([point(at: at(30_000), from: -7200, to: -600)], onRoute()), .silent,
                       "туман уже рассеялся")
        XCTAssertNotNil(announced(decide([point(at: at(30_000), from: 1800, to: 9000)], onRoute())),
                        "начнётся через полчаса — застанет")
        XCTAssertEqual(decide([point(at: at(30_000), hazards: [])], onRoute()), .silent, "ясно")
    }

    // MARK: - Один раз и после камеры

    func testAlreadySaidThisTripIsSilent() throws {
        let kamchik = point(at: at(30_000))
        let plain = point("a373-buvayda", group: "a373-buvayda", at: at(35_000))
        let notice = try XCTUnwrap(announced(decide([kamchik, plain], onRoute(), voiced: ["kamchik"])))
        XCTAssertEqual(notice.key, "a373-buvayda", "о Камчике сказано — следующий участок свой")
        XCTAssertEqual(decide([kamchik], onRoute(), voiced: ["kamchik"]), .silent)
    }

    func testCameraAheadMakesItWaitNotDrop() throws {
        let pass = point(at: at(30_000))
        guard case .wait(let waiting) = decide([pass], onRoute(), cameraBusy: true) else {
            return XCTFail("камера впереди — погода ждёт")
        }
        let notice = try XCTUnwrap(announced(decide([pass], onRoute(), cameraBusy: false)))
        XCTAssertEqual(notice.key, waiting.key, "после камеры — та же фраза, она не потерялась")
        XCTAssertEqual(decide([], onRoute(), cameraBusy: true), .silent, "нечего сказать — нечего и ждать")
    }

    // MARK: - Перевал из нескольких точек

    func testPassPointsMakeOnePhrase() throws {
        let approach = point("kamchik-north", at: at(25_000), hazards: [.fog])
        let tunnel = point("kamchik-tunnel", at: at(45_000), hazards: [.ice, .snow])
        let notice = try XCTUnwrap(announced(decide([tunnel, approach], onRoute())))
        XCTAssertEqual(notice.pointID, "kamchik-north", "ближайшая опасная точка")
        XCTAssertEqual(notice.distance, 25_000, accuracy: 300)
        XCTAssertEqual(notice.hazards, [.ice, .snow], "по важности, не больше двух: гололёд главнее тумана")
    }

    func testNearestGroupWins() throws {
        let far = point("m39-bulungur", group: "m39-bulungur", at: at(38_000))
        let near = point(at: at(28_000))
        XCTAssertEqual(try XCTUnwrap(announced(decide([far, near], onRoute()))).key, "kamchik")
    }

    // MARK: - Файл

    func testDecodeServerFile() throws {
        let json = """
        {"v":1,"generated":1800000000,"points":[
         {"id":"kamchik-tunnel","group":"kamchik","kind":"pass","road":"A373","lat":41.08438,"lon":70.54011,"r":3000,
          "name":{"ru":"Перевал Камчик","uz":"Qamchiq dovoni"},"where":{"ru":"На перевале Камчик","uz":"Qamchiq dovonida"},
          "hazards":[{"k":"fog","from":1800000000,"to":1800007200},{"k":"hail","from":1800000000,"to":1800003600}],
          "until":1800007200,"t":-1.5,"vis":150},
         {"id":"m39-chinaz","kind":"plain","lat":40.949,"lon":68.74544,"r":10000,
          "name":{"ru":"Трасса M39 у Чиназа","uz":"M39 trassasi, Chinoz"},
          "where":{"ru":"На трассе у Чиназа","uz":"Chinoz yaqinidagi trassada"},
          "hazards":[],"until":null,"t":12.3,"vis":null},
         {"id":"broken","lat":41.0,"lon":70.0,"r":1000,"name":{"ru":"Без места"},"hazards":[]}
        ]}
        """
        let file = try XCTUnwrap(RoadWeatherSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(file.generated, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(file.points.map(\.id), ["kamchik-tunnel", "m39-chinaz"], "точка без where пропущена")
        let kamchik = file.points[0]
        XCTAssertTrue(kamchik.isPass)
        XCTAssertEqual(kamchik.group, "kamchik")
        XCTAssertEqual(kamchik.radius, 3000)
        XCTAssertEqual(kamchik.windows.map(\.hazard), [.fog], "незнакомый вид опасности — пропуск")
        XCTAssertEqual(file.points[1].group, "m39-chinaz", "без группы — своя группа")
        XCTAssertFalse(file.points[1].isPass)
        XCTAssertNil(RoadWeatherSnapshot.decode(Data(#"{"v":2,"generated":1,"points":[]}"#.utf8)),
                     "чужая версия — нет данных")
        XCTAssertNil(RoadWeatherSnapshot.decode(Data("<html>502</html>".utf8)))
    }

    func testFreshnessIsTwoHours() {
        let file = snapshot([])
        XCTAssertTrue(RoadWeatherSnapshot(generated: now.addingTimeInterval(-7_100), points: []).isFresh(now: now))
        XCTAssertFalse(RoadWeatherSnapshot(generated: now.addingTimeInterval(-7_300), points: []).isFresh(now: now))
        XCTAssertTrue(file.isFresh(now: now))
    }

    // MARK: - Слова

    func testPhraseIsCalmAndShort() {
        let notice = A.Notice(key: "kamchik", pointID: "kamchik-tunnel", hazards: [.fog], distance: 32_000,
                              name: .init(ru: "Перевал Камчик", uz: "Qamchiq dovoni"),
                              place: .init(ru: "На перевале Камчик", uz: "Qamchiq dovonida"), isLate: false)
        let two = A.Notice(key: "kamchik", pointID: "kamchik-tunnel", hazards: [.ice, .snow], distance: 32_000,
                           name: notice.name, place: notice.place, isLate: false)
        if A.Notice.isUzbek {
            XCTAssertEqual(notice.spoken, "Qamchiq dovonida tuman")
        } else {
            XCTAssertEqual(notice.spoken, "На перевале Камчик туман")
            XCTAssertEqual(two.spoken, "На перевале Камчик гололёд и снег")
            XCTAssertTrue(notice.subtitle.hasPrefix("Туман · через 32"), notice.subtitle)
        }
        XCTAssertFalse(notice.spoken.contains("м "), "без расстояния до метра")
        XCTAssertEqual(two.symbol, "thermometer.snowflake")
    }

    // MARK: - Рубильник пульта

    func testPultSwitchDefaultsToOn() throws {
        let off = try JSONDecoder().decode(RemoteConfig.self, from: Data(#"{"features":{"roadWeather":false}}"#.utf8))
        XCTAssertFalse(off.isRoadWeatherEnabled)
        let old = try JSONDecoder().decode(RemoteConfig.self, from: Data(#"{"features":{"traffic":false}}"#.utf8))
        XCTAssertTrue(old.isRoadWeatherEnabled, "старый пульт без поля — включено")
        XCTAssertTrue(RemoteConfig.default.isRoadWeatherEnabled)
    }
}
