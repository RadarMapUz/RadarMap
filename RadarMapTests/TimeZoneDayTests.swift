//
//  TimeZoneDayTests.swift
//  RadarMapTests
//
//  Правки поездок после смены часового пояса (S16): строка дня лежит под
//  ключом старого пояса — удаление и разделение находят её, а не
//  промахиваются (удалённая оставалась в итогах, разделённая задваивалась).
//  И подписи своих камер — на языке интерфейса.
//

import XCTest
@testable import RadarMap

final class TimeZoneDayTests: XCTestCase {
    private func calendar(_ hours: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: hours * 3600)!
        return c
    }

    private func trip(_ id: Double, at date: Date, km: Double = 10) -> TripRecord {
        TripRecord(id: id, startedAt: date, endedAt: date.addingTimeInterval(1800),
                   distanceMeters: km * 1000, maxSpeedKmh: 60, passed: [])
    }

    func testDeleteAfterTimeZoneChangeFindsTheRow() {
        let tashkent = calendar(5), moscow = calendar(3)
        // 01:30 по Ташкенту — 23:30 предыдущего дня по Москве.
        let start = tashkent.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 1, minute: 30))!
        let days = TripDayBook.folded(trip(1, at: start), into: [], calendar: tashkent)
        XCTAssertNotEqual(moscow.startOfDay(for: start), days[0].day, "ключ другого пояса — другой")
        let after = TripDayBook.unfolded(trip(1, at: start), from: days, calendar: moscow)
        XCTAssertNotEqual(after, days, "строка найдена, а не пропущена")
        XCTAssertEqual(after.reduce(0) { $0 + $1.trips }, 0, "удалённая поездка уходит и из итогов дня")
        XCTAssertEqual(after.reduce(0) { $0 + $1.distanceMeters }, 0)
    }

    func testSplitAfterTimeZoneChangeStaysInItsRow() {
        let tashkent = calendar(5), moscow = calendar(3)
        let start = tashkent.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 1, minute: 30))!
        let original = trip(1, at: start, km: 10)
        let days = TripDayBook.folded(original, into: [], calendar: tashkent)
        let legs = [trip(1, at: start, km: 6), trip(2, at: start.addingTimeInterval(900), km: 4)]
        let after = TripDayBook.replaced([original], with: legs, in: days, calendar: moscow)
        XCTAssertEqual(after.count, 1, "одна строка, а не две")
        XCTAssertEqual(after[0].trips, 2)
        XCTAssertEqual(after[0].distanceMeters, 10_000, accuracy: 0.1)
        XCTAssertEqual(TripDayBook.replaced([trip(9, at: start.addingTimeInterval(-5 * 86_400))], with: legs,
                                            in: days, calendar: moscow), days,
                       "строки нет вовсе — ничего, иначе задвоили бы")
    }

    func testDefaultCustomLabelsFollowTheInterfaceLanguage() {
        let saved = Camera(id: 1_000_001, region: "Mening kameram", city: "", location: "Qo'lda qo'shilgan",
                           lat: 41.3, lon: 69.2, type: "Стационар радар", violations: [], needsReview: nil)
        let shown = CameraStore.relabeled(saved)
        XCTAssertEqual(shown.region, String(localized: "Моя камера"))
        XCTAssertEqual(shown.location, String(localized: "Добавлено вручную"))
        let named = Camera(id: 1_000_002, region: "Моя камера", city: "", location: "У школы",
                           lat: 41.3, lon: 69.2, type: "Стационар радар", violations: [], needsReview: nil)
        XCTAssertEqual(CameraStore.relabeled(named).location, "У школы", "подпись человека не трогаем")
    }
}
