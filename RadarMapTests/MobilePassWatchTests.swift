//
//  MobilePassWatchTests.swift
//  RadarMapTests
//
//  «Тренога ещё стоит?» — обоим направлениям (владелец, 02.11: треноги
//  снимают и встречных), но не поперечной улице на развязке. Курс проезда
//  уходит с голосом: вес «Убрали» встречного решает сервер.
//

import CoreLocation
import XCTest
@testable import RadarMap

extension XCTestCase {
    /// Проезд в одну сторону с отметившим (курс отметки = наш) — то, что
    /// проверяют старые тесты про «когда спрашивать».
    func passWatch(tracks: inout [Int: MobilePassWatch.Track], mobileCameras: [Camera],
                   from coordinate: CLLocationCoordinate2D, course: Double = 90,
                   excluded: Set<Int> = [], canAsk: Bool = true, now: Date = Date()) -> Int? {
        MobilePassWatch.update(tracks: &tracks, mobileCameras: mobileCameras, from: coordinate,
                               course: course,
                               courses: Dictionary(uniqueKeysWithValues: mobileCameras.map { ($0.id, course) }),
                               excluded: excluded, canAsk: canAsk, now: now)
    }
}

final class MobilePassWatchTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.3)

    private func east(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: origin, bearing: 90, distanceMeters: meters)
    }

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: origin, bearing: 0, distanceMeters: meters)
    }

    private var tripod: Camera {
        Camera(id: MobileCameraService.idOffset + 11, region: "", city: "", location: "",
               lat: origin.latitude, lon: origin.longitude, type: CameraType.tripod.sourceString,
               violations: [], needsReview: nil, mobileConfirmed: false)
    }

    /// Проехать вдоль востока мимо точки: подъезд, вплотную, отъезд.
    private func drivePast(reportCourse: Double?, ourCourse: Double) -> Int? {
        var tracks: [Int: MobilePassWatch.Track] = [:]
        let courses = reportCourse.map { [tripod.id: $0] } ?? [:]
        var asked: Int?
        for meters in [-300.0, -40, 0, 40, 200, 260] {
            let at = ourCourse == 90 || ourCourse == 270 ? east(ourCourse == 90 ? meters : -meters)
                                                         : north(ourCourse == 0 ? meters : -meters)
            asked = asked ?? MobilePassWatch.update(tracks: &tracks, mobileCameras: [tripod], from: at,
                                                    course: ourCourse, courses: courses)
        }
        return asked
    }

    func testSameDirectionIsAsked() {
        XCTAssertEqual(drivePast(reportCourse: 85, ourCourse: 90), tripod.id)
    }

    func testOncomingIsAskedToo() {
        XCTAssertEqual(drivePast(reportCourse: 90, ourCourse: 270), tripod.id,
                       "тренога снимает обе стороны — встречный видел её так же")
        XCTAssertTrue(MobilePassWatch.oncoming(course: 270, reportCourse: 90))
        XCTAssertFalse(MobilePassWatch.oncoming(course: 85, reportCourse: 90))
    }

    func testCrossStreetIsNotAsked() {
        XCTAssertNil(drivePast(reportCourse: 90, ourCourse: 0), "поперечная улица на развязке — не спрашиваем")
    }

    func testUnknownCourseStillAsks() {
        XCTAssertEqual(drivePast(reportCourse: nil, ourCourse: 90), tripod.id,
                       "курс отметки неизвестен (старый сервер) — спрашиваем, как раньше")
        XCTAssertFalse(MobilePassWatch.crosses(course: -1, reportCourse: 90))
    }

    func testCrossingIsJudgedByAxis() {
        XCTAssertFalse(MobilePassWatch.crosses(course: 350, reportCourse: 20), "через север — та же ось")
        XCTAssertFalse(MobilePassWatch.crosses(course: 190, reportCourse: 15), "встречный — та же ось")
        XCTAssertTrue(MobilePassWatch.crosses(course: 90, reportCourse: 0))
    }

    func testQuestionIsTheSameOnPhoneAndCar() {
        // Машина берёт вопрос отсюда для всех типов — «%@ ещё на месте?» больше нет.
        let q = MobilePassWatch.question(for: .tripod)
        XCTAssertEqual(q.title, "Тренога ещё стоит?")
        XCTAssertEqual([q.yes, q.no], ["Стоит", "Уже нет"])
        XCTAssertLessThanOrEqual(q.title.count, 24, "влезает в баннер машины")
        XCTAssertLessThanOrEqual(max(q.yes.count, q.no.count), 10, "влезает в CPAlertAction")
    }
}
