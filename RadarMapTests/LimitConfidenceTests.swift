//
//  LimitConfidenceTests.swift
//  RadarMapTests
//
//  Можно ли вменять найденный лимит. Правило выросло из жалобы «в Ташкенте
//  нет лимита 50» и из замера боевой базы: 99,7 % городских сегментов несут
//  меньше 70, а 84,6 % — ровно 60 при норме ПДД 70.
//

import XCTest
@testable import RadarMap

final class LimitConfidenceTests: XCTestCase {

    /// Тот самый случай: проспект с тегом ниже законного.
    func testLowTagOnAnAvenueIsDoubtful() {
        XCTAssertEqual(LimitConfidence.of(limitKmh: 60, roadClass: .primary, inSettlement: true),
                       .doubtful)
        XCTAssertEqual(LimitConfidence.of(limitKmh: 50, roadClass: .secondary, inSettlement: true),
                       .doubtful)
    }

    /// Законное и большее — верим без оговорок.
    func testLegalOrHigherIsSigned() {
        XCTAssertEqual(LimitConfidence.of(limitKmh: 70, roadClass: .primary, inSettlement: true),
                       .signed)
        XCTAssertEqual(LimitConfidence.of(limitKmh: 90, roadClass: .primary, inSettlement: true),
                       .signed)
    }

    /// На малом классе малое число законно: двор, проезд, обычная улица.
    /// Сомневаться здесь значило бы отменить настоящие ограничения.
    func testSmallRoadsKeepTheirSmallLimits() {
        XCTAssertEqual(LimitConfidence.of(limitKmh: 20, roadClass: .service, inSettlement: true),
                       .signed)
        XCTAssertEqual(LimitConfidence.of(limitKmh: 30, roadClass: .residential, inSettlement: true),
                       .signed)
        XCTAssertEqual(LimitConfidence.of(limitKmh: 40, roadClass: .tertiary, inSettlement: true),
                       .signed)
    }

    /// За городом тег обычно и есть правда: 90 на трассе встречается
    /// по-настоящему, и превышение по нему настоящее.
    func testOutsideSettlementWeDoNotSecondGuess() {
        XCTAssertEqual(LimitConfidence.of(limitKmh: 90, roadClass: .motorway, inSettlement: false),
                       .signed)
        XCTAssertEqual(LimitConfidence.of(limitKmh: 60, roadClass: .primary, inSettlement: false),
                       .signed)
    }

    /// Класс неизвестен — файл формата 1 или камера без профиля. Догадка не
    /// вправе отменять данные: молчим и верим тегу.
    func testUnknownClassIsNotAReasonToDoubt() {
        XCTAssertEqual(LimitConfidence.of(limitKmh: 60, roadClass: .unknown, inSettlement: true),
                       .signed)
    }
}
