//
//  RoadEventTests.swift
//  RadarMapTests
//
//  Перекрытия и ремонт (12б.5): вариант через подтверждённое перекрытие в
//  нашу сторону — «на пути перекрытие» и не первым; отметка на встречке не
//  мешает; голос — раз, впереди, по курсу; камерой событие не становится.
//

import XCTest
import CoreLocation
@testable import RadarMap

final class RoadEventTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = CLLocationCoordinate2D(latitude: 41.30, longitude: 69.28)

    /// Прямая на север, 2 км, точка каждые 100 м.
    private var northPath: [CLLocationCoordinate2D] {
        (0...20).map { GeoMath.destination(from: start, bearing: 0, distanceMeters: Double($0) * 100) }
    }

    private func event(_ kind: RoadEvent.Kind = .closure, at meters: Double = 1000, side: Double = 0,
                       course: Double = 0, confirmed: Bool = true, id: Int = 1) -> RoadEvent {
        let along = GeoMath.destination(from: start, bearing: 0, distanceMeters: meters)
        let point = GeoMath.destination(from: along, bearing: 90, distanceMeters: side)
        return RoadEvent(id: id, kind: kind, lat: point.latitude, lon: point.longitude, course: course,
                         expires: now.addingTimeInterval(3600), confirmed: confirmed)
    }

    func testClosureOnOurSideBlocksTheVariant() {
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event()], now: now), 1)
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event(course: 180)], now: now), 0,
                       "перекрыта встречная половина — нашей дороге не мешает")
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event(course: -1)], now: now), 1,
                       "курс отметившего неизвестен — считаем перекрытым всё")
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event(side: 80)], now: now), 0,
                       "80 м в стороне — соседняя улица")
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event(confirmed: false)], now: now), 0,
                       "неподтверждённое — не повод менять выбор маршрута")
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [event(.roadwork)], now: now), 0,
                       "ремонт маршрут не двигает — только голос")
        var expired = event()
        expired = RoadEvent(id: 1, kind: .closure, lat: expired.lat, lon: expired.lon, course: 0,
                            expires: now.addingTimeInterval(-1), confirmed: true)
        XCTAssertEqual(RoadEventRules.closures(on: northPath, events: [expired], now: now), 0)
    }

    func testBlockedVariantIsNotRecommended() {
        func input(time: TimeInterval, closures: Int) -> RouteChoice.Input {
            RouteChoice.Input(path: northPath, distance: 2000, travelTime: time, cameraIDs: [],
                              hardManeuvers: nil, closures: closures)
        }
        let verdict = RouteChoice.decide([input(time: 600, closures: 1), input(time: 720, closures: 0)],
                                         history: nil)
        XCTAssertEqual(verdict.recommended, 1, "быстрый, но через перекрытие — не первым")
        XCTAssertEqual(verdict.assessments[0].labels.first, .blocked, "предупреждение — первым ярлыком")
        let allBlocked = RouteChoice.decide([input(time: 600, closures: 1), input(time: 720, closures: 2)],
                                            history: nil)
        XCTAssertEqual(allBlocked.recommended, 0, "перекрыты все — выбор прежний, ярлык скажет сам")
        let single = RouteChoice.decide([input(time: 600, closures: 1)], history: nil)
        XCTAssertEqual(single.assessments[0].labels, [.blocked], "один вариант — о перекрытии всё равно сказать")
    }

    func testVoiceOnceAheadOnOurCourse() {
        let roadwork = event(.roadwork, at: 300)
        XCTAssertEqual(RoadEventRules.ahead(of: start, course: 0, events: [roadwork], voiced: [], now: now)?.id, 1)
        XCTAssertNil(RoadEventRules.ahead(of: start, course: 0, events: [roadwork], voiced: [1], now: now),
                     "уже сказано в этой поездке")
        XCTAssertNil(RoadEventRules.ahead(of: start, course: 180, events: [roadwork], voiced: [], now: now),
                     "позади")
        XCTAssertNil(RoadEventRules.ahead(of: start, course: -1, events: [roadwork], voiced: [], now: now),
                     "курса нет — молчим")
        XCTAssertNil(RoadEventRules.ahead(of: start, course: 0, events: [event(.roadwork, at: 900)],
                                          voiced: [], now: now), "далеко")
        XCTAssertNil(RoadEventRules.ahead(of: start, course: 0, events: [event(.roadwork, at: 300, course: 180)],
                                          voiced: [], now: now), "ремонт на встречке")
        XCTAssertNil(RoadEventRules.ahead(of: start, course: 0,
                                          events: [event(.roadwork, at: 300, confirmed: false)],
                                          voiced: [], now: now), "неподтверждённый ремонт — не повод говорить")
        XCTAssertNotNil(RoadEventRules.ahead(of: start, course: 0,
                                             events: [event(.closure, at: 300, confirmed: false)],
                                             voiced: [], now: now),
                        "перекрытие — и неподтверждённое: упереться в него дороже фразы")
        let near = event(.roadwork, at: 200, id: 2)
        XCTAssertEqual(RoadEventRules.ahead(of: start, course: 0, events: [roadwork, near], voiced: [], now: now)?.id,
                       2, "ближайшее первым")
    }

    func testPhrasesNameTheSource() {
        XCTAssertTrue(RoadEventRules.phrase(for: event(confirmed: false)).contains("Отметка водителей"),
                      "слух не продаём как факт")
        XCTAssertFalse(RoadEventRules.phrase(for: event(.roadwork)).contains("метр"), "без расстояния до метра")
    }

    /// Ремонт и перекрытие — не камеры: в общем списке их нет, а свой тип
    /// отметки знает, что он событие дороги.
    func testRoadKindsAreNotCameras() {
        XCTAssertTrue(ReportKind.closure.isRoadEvent)
        XCTAssertTrue(ReportKind.roadwork.isRoadEvent)
        XCTAssertFalse(ReportKind.offered.contains(where: \.isRoadEvent),
                       "в основной набор «Радар!» дорога не входит — только вторым рядом при поддержке сервера")
        XCTAssertNil(ReportKind.radar.roadEventKind)
        XCTAssertNotNil(UIImage(systemName: ReportKind.roadwork.symbol), "знак ремонта есть в системе")
        XCTAssertNotNil(UIImage(systemName: ReportKind.closure.symbol))
    }

    func testOldQueueRecordWithoutCourseDecodes() throws {
        let old = #"{"kind":"radar","lat":41.3,"lon":69.2,"cls":"","at":0}"#
        let item = try JSONDecoder().decode(PendingReport.self, from: Data(old.utf8))
        XCTAssertNil(item.course)
    }
}
