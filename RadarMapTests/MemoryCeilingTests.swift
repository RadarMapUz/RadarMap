//
//  MemoryCeilingTests.swift
//  RadarMapTests
//
//  Потолок памяти в поездке (36A): чистка выше потолка и не чаще интервала —
//  иначе рабочий набор выше потолка перечитывал бы тайлы с диска на каждой
//  проверке. Повод «фон» не отдаёт то, что нужно видимому экрану машины.
//

import XCTest
@testable import RadarMap

final class MemoryCeilingTests: XCTestCase {
    private let ceiling: UInt64 = 200 * 1024 * 1024

    func testBelowCeilingNeverTrims() {
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: ceiling - 1, ceiling: ceiling, lastTrim: nil, now: 0))
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: ceiling, ceiling: ceiling, lastTrim: nil, now: 0))
    }

    func testAboveCeilingTrimsOnceAndThenWaits() {
        let over = ceiling + 50 * 1024 * 1024
        XCTAssertTrue(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: nil, now: 100))
        XCTAssertFalse(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: 100,
                                                 now: 100 + AppConfig.engineMemoryCheckSeconds),
                       "следующая проверка через 15 с — рано")
        XCTAssertTrue(MemoryPressure.shouldTrim(footprint: over, ceiling: ceiling, lastTrim: 100,
                                                now: 100 + AppConfig.engineMemoryTrimIntervalSeconds))
    }

    func testIntervalIsLongerThanTheCheck() {
        XCTAssertGreaterThan(AppConfig.engineMemoryTrimIntervalSeconds, AppConfig.engineMemoryCheckSeconds * 4)
    }

    /// Уход телефона в фон — не тесная память: книги поиска машины остаются.
    func testBackgroundIsNotTight() {
        XCTAssertFalse(MemoryPressure.Reason.background.isTight)
        XCTAssertTrue(MemoryPressure.Reason.warning.isTight)
        XCTAssertTrue(MemoryPressure.Reason.ceiling(footprint: 0).isTight)
    }

    func testFootprintIsReadable() {
        let bytes = MemoryPressure.footprintBytes()
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1024 * 1024)
    }

    // MARK: - Машина подключена (40I)

    /// Замер 11.10 с машиной: 278 МБ стоя, 302–310 в езде, 326 на осмотре.
    /// Потолок с машиной выше всего замера — иначе чистка каждые 2 мин всю
    /// поездку; без машины — прежний.
    func testCarCeilingSitsAboveTheMeasuredCarWorkingSet() {
        let mb: UInt64 = 1024 * 1024
        let car = MemoryPressure.ceiling(carConnected: true)
        XCTAssertEqual(MemoryPressure.ceiling(carConnected: false), AppConfig.engineMemoryCeilingBytes)
        for measured: UInt64 in [278, 310, 326] {
            XCTAssertFalse(MemoryPressure.shouldTrim(footprint: measured * mb, ceiling: car, lastTrim: nil, now: 0),
                           "\(measured) МБ — рабочий набор карты машины, не повод чистить")
            XCTAssertTrue(MemoryPressure.shouldTrim(footprint: measured * mb,
                                                    ceiling: MemoryPressure.ceiling(carConnected: false),
                                                    lastTrim: nil, now: 0),
                          "без машины столько — прогрев кэша, чистим как раньше")
        }
        XCTAssertLessThan(car, 512 * mb, "потолок — не отказ от потолка")
    }

    /// Видимая карта машины на потолке не отдаёт ничего; скрытая карта
    /// телефона рядом с ней чистится как раньше.
    func testVisibleCarMapKeepsItsWorkingSetOnTheCeiling() {
        let over = MemoryPressure.Reason.ceiling(footprint: 380 * 1024 * 1024)
        XCTAssertEqual(MemoryPressure.release(over, hidden: false, inCar: true), .nothing)
        XCTAssertEqual(MemoryPressure.release(over, hidden: true, inCar: false), .selectionAndEngine,
                       "карта телефона в кармане")
        XCTAssertEqual(MemoryPressure.release(over, hidden: true, inCar: true), .selectionAndEngine,
                       "машина на чужом навигаторе — нашей карты не видно")
        XCTAssertEqual(MemoryPressure.release(over, hidden: false, inCar: false), .selectionAndEngine,
                       "открытая карта телефона в поездке — как в 36A")
    }

    /// Выше жёсткого верха отдаёт и видимая карта машины: след — на процесс
    /// (экран, плитка и приборка вместе), выгрузка хуже перечитанных тайлов.
    func testVisibleCarMapGivesUpAboveTheHardCeiling() {
        let hard = AppConfig.engineMemoryHardCeilingCarPlayBytes
        XCTAssertGreaterThan(hard, AppConfig.engineMemoryCeilingCarPlayBytes)
        XCTAssertEqual(MemoryPressure.release(.ceiling(footprint: hard), hidden: false, inCar: true), .nothing)
        XCTAssertEqual(MemoryPressure.release(.ceiling(footprint: hard + 1), hidden: false, inCar: true),
                       .selectionAndEngine)
    }

    func testBackgroundAndWarningAreUnchanged() {
        XCTAssertEqual(MemoryPressure.release(.background, hidden: false, inCar: true), .nothing)
        XCTAssertEqual(MemoryPressure.release(.background, hidden: true, inCar: false), .selectionAndEngine)
        XCTAssertEqual(MemoryPressure.release(.warning, hidden: false, inCar: true), .selection,
                       "система предупредила — тесно на самом деле; движок отвечает сам")
    }
}
