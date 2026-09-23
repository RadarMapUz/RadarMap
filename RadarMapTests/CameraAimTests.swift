//
//  CameraAimTests.swift
//  RadarMapTests
//
//  Догадка о направлении камеры по профилю скорости. Тесты здесь в основном
//  про то, когда движок обязан ПРОМОЛЧАТЬ: ошибочная уверенность в направлении
//  камеры дороже отсутствия догадки.
//

import XCTest
@testable import RadarMap

final class CameraAimTests: XCTestCase {

    private func samples(course: Double, brake: Double, count: Int) -> [CameraAim.Sample] {
        (0..<count).map { _ in CameraAim.Sample(courseDegrees: course, brakeKmh: brake) }
    }

    /// Классический случай: на восток тормозят перед камерой и разгоняются
    /// после, на запад — едут ровно.
    func testBrakingOneWayOnlyGivesADirection() {
        let east = samples(course: 90, brake: 14, count: 6)
        let west = samples(course: 270, brake: 1, count: 6)
        guard case .oneWay(let bearing) = CameraAim.verdict(samples: east + west) else {
            return XCTFail("ожидался односторонний вердикт")
        }
        XCTAssertEqual(bearing, 90, accuracy: 1)
    }

    /// Конфаунд №1: светофор или лежачий полицейский сразу за камерой —
    /// тормозят ВСЕ и в обе стороны. Это не направление камеры.
    func testBrakingBothWaysIsNotADirection() {
        let east = samples(course: 90, brake: 15, count: 8)
        let west = samples(course: 270, brake: 16, count: 8)
        XCTAssertEqual(CameraAim.verdict(samples: east + west), .bothWays)
    }

    /// Конфаунд №2: ездим только в одну сторону. Сравнивать не с чем, и
    /// «тормозит всегда» с равным правом объясняется привычкой, рельефом и
    /// перекрёстком. Молчим.
    func testWithoutACounterSampleTheVerdictIsUnknown() {
        let east = samples(course: 90, brake: 20, count: 30)
        XCTAssertEqual(CameraAim.verdict(samples: east), .unknown)
    }

    /// Мало проездов — молчим, сколько бы ни был выразителен провал.
    func testTooFewPassesStayUnknown() {
        let east = samples(course: 90, brake: 25, count: 3)
        let west = samples(course: 270, brake: 0, count: 3)
        XCTAssertEqual(CameraAim.verdict(samples: east + west), .unknown)
    }

    /// Никто нигде не тормозит — камера себя ничем не выдаёт.
    func testNoBrakingAnywhereIsUnknown() {
        let east = samples(course: 90, brake: 1, count: 8)
        let west = samples(course: 270, brake: 2, count: 8)
        XCTAssertEqual(CameraAim.verdict(samples: east + west), .unknown)
    }

    /// Конфаунд №3: одна пробка. Медиана не даёт ей перевесить восемь
    /// спокойных проездов — среднее дало бы.
    func testOneTrafficJamDoesNotDecide() {
        var west = samples(course: 270, brake: 1, count: 8)
        west.append(CameraAim.Sample(courseDegrees: 270, brakeKmh: 60))
        let east = samples(course: 90, brake: 14, count: 8)
        guard case .oneWay(let bearing) = CameraAim.verdict(samples: east + west) else {
            return XCTFail("пробка не должна менять вердикт")
        }
        XCTAssertEqual(bearing, 90, accuracy: 1)
        // Среднее по встречной выборке (≈7,6) обошло бы порог 8 не намного,
        // но именно оно и сломало бы вердикт на менее выраженной картине.
        XCTAssertEqual(CameraAim.median(west.map(\.brakeKmh)), 1, accuracy: 0.001)
    }

    /// Поперечное движение (свернул у камеры) в разбор не идёт вовсе.
    func testCrossTrafficIsIgnored() {
        let east = samples(course: 90, brake: 14, count: 6)
        let west = samples(course: 270, brake: 1, count: 6)
        let across = samples(course: 0, brake: 30, count: 10)
        guard case .oneWay(let bearing) = CameraAim.verdict(samples: east + west + across) else {
            return XCTFail("поперечные проезды не должны менять вердикт")
        }
        XCTAssertEqual(bearing, 90, accuracy: 1)
    }

    /// Средний курс считается по кратчайшей дуге: 350° и 10° — это север,
    /// а не юг. Обычное среднее дало бы 180°, то есть ровно наоборот.
    func testMeanBearingWrapsAroundNorth() {
        XCTAssertEqual(CameraAim.meanBearing([350, 10]), 0, accuracy: 0.001)
        XCTAssertEqual(CameraAim.meanBearing([80, 100]), 90, accuracy: 0.001)
    }

    func testCardinalNamesTheRhumb() {
        XCTAssertEqual(CameraAim.cardinal(0), String(localized: "на север"))
        XCTAssertEqual(CameraAim.cardinal(90), String(localized: "на восток"))
        XCTAssertEqual(CameraAim.cardinal(359), String(localized: "на север"))
        XCTAssertEqual(CameraAim.cardinal(225), String(localized: "на юго-запад"))
    }

    /// Проезды без курса или без замера «после» в разбор не попадают:
    /// у старых записей этих полей нет вовсе.
    func testPassesWithoutCourseOrAfterSpeedAreSkipped() {
        let now = Date()
        var withoutCourse = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                         location: "", speedKmh: 40, date: now)
        withoutCourse.speedAfterKmh = 60
        var withoutAfter = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                        location: "", speedKmh: 40, date: now)
        withoutAfter.courseDegrees = 90
        XCTAssertEqual(CameraAim.verdict(passes: [withoutCourse, withoutAfter],
                                         cameraID: 1, now: now), .unknown)
    }

    /// Проезды старше окна не учитываются: камеру могли развернуть.
    func testOldPassesFallOutOfTheWindow() {
        let now = Date()
        let old = now.addingTimeInterval(-Double(AppConfig.aimWindowDays + 10) * 86400)
        let passes = (0..<20).map { index -> PassedCamera in
            var pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                                    location: "", speedKmh: 40, date: old)
            pass.courseDegrees = index.isMultiple(of: 2) ? 90 : 270
            pass.speedAfterKmh = index.isMultiple(of: 2) ? 60 : 41
            return pass
        }
        XCTAssertEqual(CameraAim.verdict(passes: passes, cameraID: 1, now: now), .unknown)
    }

    /// Проезды ЧУЖОЙ камеры не участвуют в разборе этой.
    func testOnlyTheAskedCameraIsAnalysed() {
        let now = Date()
        let passes = (0..<20).map { index -> PassedCamera in
            var pass = PassedCamera(id: UUID(), cameraID: 2, typeRaw: "Стационар радар",
                                    location: "", speedKmh: 40, date: now)
            pass.courseDegrees = index.isMultiple(of: 2) ? 90 : 270
            pass.speedAfterKmh = index.isMultiple(of: 2) ? 60 : 41
            return pass
        }
        XCTAssertEqual(CameraAim.verdict(passes: passes, cameraID: 1, now: now), .unknown)
    }
}
