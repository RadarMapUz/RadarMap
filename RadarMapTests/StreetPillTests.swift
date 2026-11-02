//
//  StreetPillTests.swift
//  RadarMapTests
//
//  Плашка улицы (29.F): поперечная улица перекрёстка не перебивает ту, по
//  которой едем; кусок без имени не мигает плашкой; стоя — прежнее имя.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class StreetPillTests: XCTestCase {

    private func c(_ name: String, _ bearing: Double?, _ distance: Double) -> StreetPill.Candidate {
        StreetPill.Candidate(name: name, bearing: bearing, distance: distance)
    }

    func testCrossStreetAtJunctionDoesNotWin() {
        // Едем на север по Навои; поперечная Рашидова ближе к значку.
        let name = StreetPill.choose([c("Navoiy", 2, 6), c("Rashidov", 91, 1)], course: 0, previous: nil)
        XCTAssertEqual(name, "Navoiy")
    }

    func testDirectionDoesNotMatterOnlyAxis() {
        // Лента нарисована против хода (одностороннее обратное направление
        // кусков) — та же ось, та же улица.
        XCTAssertEqual(StreetPill.choose([c("Navoiy", 182, 3)], course: 0, previous: nil), "Navoiy")
    }

    func testPreviousNameHoldsWhileStillUnderTheCar() {
        let name = StreetPill.choose([c("Stub", 10, 1), c("Navoiy", 5, 7)], course: 0, previous: "Navoiy")
        XCTAssertEqual(name, "Navoiy")
    }

    func testNoAlignedRoadMeansNothing() {
        XCTAssertNil(StreetPill.choose([c("Rashidov", 90, 2)], course: 0, previous: nil))
    }

    func testEmptyNamesAreIgnored() {
        XCTAssertEqual(StreetPill.choose([c("  ", 0, 1), c("Furqat", 0, 9)], course: 0, previous: nil), "Furqat")
        XCTAssertNil(StreetPill.choose([c("", 0, 1)], course: 0, previous: nil))
    }

    func testStandingWithoutCourseKeepsPreviousElseNearest() {
        XCTAssertEqual(StreetPill.choose([c("A", 90, 1), c("B", 0, 5)], course: -1, previous: "B"), "B")
        XCTAssertEqual(StreetPill.choose([c("A", 90, 1), c("B", 0, 5)], course: -1, previous: nil), "A")
    }

    func testTrackerHidesOnlyAfterRepeatedMisses() {
        var tracker = StreetPill.Tracker()
        XCTAssertEqual(tracker.update([c("Navoiy", 0, 2)], course: 0), "Navoiy")
        // Одна пустая проба посреди перекрёстка — плашка остаётся.
        XCTAssertEqual(tracker.update([], course: 0), "Navoiy")
        XCTAssertEqual(tracker.update([], course: 0), AppConfig.streetPillMissesToHide <= 2 ? nil : "Navoiy")
        XCTAssertEqual(tracker.update([c("Furqat", 0, 2)], course: 0), "Furqat")
    }

    func testParentheticalSuffixIsDroppedSoTheTypeIsRecognised() {
        XCTAssertEqual(StreetPill.cleanName("Furqat ko'chasi (dublyor)"), "Furqat ko'chasi")
        XCTAssertEqual(StreetName.display(StreetPill.cleanName("Furqat ko'chasi (dublyor)"), language: "ru"),
                       StreetName.display("Furqat ko'chasi", language: "ru"))
        XCTAssertEqual(StreetPill.cleanName(" Navoiy shoh ko'chasi "), "Navoiy shoh ko'chasi")
        XCTAssertEqual(StreetPill.cleanName("(только скобки)"), "(только скобки)", "имя целиком в скобках не теряем")
    }

    func testNearestSegmentDistanceAndBearing() {
        let base = CLLocationCoordinate2D(latitude: 41.3, longitude: 69.25)
        // Ломаная на север, в ~10 м восточнее точки.
        let east = 10 / (111_320 * cos(41.3 * .pi / 180))
        let line = [CLLocationCoordinate2D(latitude: 41.299, longitude: 69.25 + east),
                    CLLocationCoordinate2D(latitude: 41.301, longitude: 69.25 + east)]
        let hit = StreetPill.nearest(line, to: base)
        XCTAssertEqual(hit?.distance ?? 0, 10, accuracy: 0.5)
        XCTAssertEqual(hit?.bearing ?? -1, 0, accuracy: 0.5)
        XCTAssertNil(StreetPill.nearest([base], to: base))
    }

    // MARK: - Подпись в машине (40J, D10)

    func testCarPillUsesTheMapAbbreviation() {
        // На карте — «ул. Фуркат», на плашке машины — то же сокращение.
        XCTAssertEqual(StreetPill.label("Furqat ko'chasi (dublyor)", language: "ru", mapForm: true), "ул. Фуркат")
        XCTAssertEqual(StreetPill.label("Amir Temur prospekti", language: "ru", mapForm: true), "просп. Амир Темур")
        // Телефон — как был.
        XCTAssertEqual(StreetPill.label("Furqat ko'chasi (dublyor)", language: "ru"), "улица Фуркат")
        // Узбекская версия — имя не трогается.
        XCTAssertEqual(StreetPill.label("Furqat ko'chasi", language: "uz", mapForm: true), "Furqat ko'chasi")
        // Без узнанного типа — как есть.
        XCTAssertEqual(StreetPill.label("Tashkent City", language: "ru", mapForm: true), "Tashkent City")
    }
}
