//
//  PlaceMergeTests.swift
//  RadarMapTests
//
//  Одна улица — одна строка (34): «улица Навои» дважды подряд сливается, время
//  складывается; безымянные места не сливаются никогда.
//

import XCTest
@testable import RadarMap

final class PlaceMergeTests: XCTestCase {

    private struct Row: Equatable {
        let street: String?
        let minutes: Int
    }

    private func merged(_ rows: [Row]) -> [Row] {
        PlaceMerge.byStreet(rows, street: \.street) { Row(street: $0.street, minutes: $0.minutes + $1.minutes) }
    }

    func testSameStreetMergesAndSums() {
        let rows = [Row(street: "улица Навои", minutes: 4), Row(street: "проспект Бунёдкор", minutes: 2),
                    Row(street: "улица Навои", minutes: 3)]
        XCTAssertEqual(merged(rows), [Row(street: "улица Навои", minutes: 7),
                                      Row(street: "проспект Бунёдкор", minutes: 2)])
    }

    func testCaseAndSpacesIgnored() {
        let rows = [Row(street: "Улица Навои ", minutes: 1), Row(street: "улица навои", minutes: 1)]
        XCTAssertEqual(merged(rows).count, 1)
        XCTAssertEqual(merged(rows).first?.minutes, 2)
    }

    func testUnnamedPlacesNeverMerge() {
        let rows = [Row(street: nil, minutes: 1), Row(street: nil, minutes: 2), Row(street: "  ", minutes: 3)]
        XCTAssertEqual(merged(rows), rows)
    }

    func testOrderIsFirstAppearance() {
        let rows = [Row(street: "B", minutes: 1), Row(street: "A", minutes: 5), Row(street: "B", minutes: 1)]
        XCTAssertEqual(merged(rows).map(\.street), ["B", "A"])
    }
}
