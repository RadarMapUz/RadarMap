//
//  TileDigestIndexTests.swift
//  RadarMapTests
//
//  Компактный индекс подписей тайлов. Тесты здесь про ДВЕ вещи сразу: что
//  память экономится и что от этого не ослабла охрана — индекс решает, какая
//  геометрия попадёт водителю на экран.
//

import XCTest
@testable import RadarMap

final class TileDigestIndexTests: XCTestCase {

    private func hex(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private var sample: TileDigestIndex {
        TileDigestIndex(version: 7, tiles: [
            "15/22686/12247": hex(0xAB),
            "11/1417/765": hex(0x01),
            "15/22686/12248": hex(0xCD),
        ])
    }

    // MARK: - Ключ

    func testPacksAndRejects() {
        XCTAssertNotNil(TileDigestIndex.packed("15/22686/12247"))
        // Разные тайлы — разные числа: на этом стоит весь поиск.
        XCTAssertNotEqual(TileDigestIndex.packed("15/22686/12247"),
                          TileDigestIndex.packed("15/22686/12248"))
        XCTAssertNotEqual(TileDigestIndex.packed("11/1417/765"),
                          TileDigestIndex.packed("15/1417/765"))
        // Мусор не сворачивается в «какое-нибудь» число.
        for bad in ["", "15", "15/22686", "15/22686/12247/9", "a/1/2", "15//2",
                    "15/22686/", "-1/2/3", "15/22686/12247 "] {
            XCTAssertNil(TileDigestIndex.packed(bad), "«\(bad)» не должен паковаться")
        }
    }

    func testHexParsing() {
        XCTAssertEqual(TileDigestIndex.bytes(fromHex: String(repeating: "ff", count: 32))?.count, 32)
        XCTAssertEqual(TileDigestIndex.bytes(fromHex: String(repeating: "00", count: 32))?.first, 0)
        // Регистр не важен, длина и алфавит — важны.
        XCTAssertEqual(TileDigestIndex.bytes(fromHex: String(repeating: "AB", count: 32)),
                       TileDigestIndex.bytes(fromHex: String(repeating: "ab", count: 32)))
        XCTAssertNil(TileDigestIndex.bytes(fromHex: String(repeating: "ab", count: 31)))
        XCTAssertNil(TileDigestIndex.bytes(fromHex: String(repeating: "zz", count: 32)))
    }

    // MARK: - Охрана

    func testMatchesOnlyTheSignedDigest() {
        let index = sample
        let right = [UInt8](repeating: 0xAB, count: 32)
        var wrong = right; wrong[31] = 0xAC        // отличие в последнем байте
        XCTAssertTrue(index.matches(tileKey: "15/22686/12247", digest: right))
        XCTAssertFalse(index.matches(tileKey: "15/22686/12247", digest: wrong))
        // Правильный дайджест, но ЧУЖОГО тайла — тоже отказ.
        XCTAssertFalse(index.matches(tileKey: "15/22686/12248", digest: right))
    }

    /// Тайла нет в индексе — отказ. Это и есть правило fail-closed: пустая
    /// карта честнее подделанной.
    func testUnknownTileIsRefused() {
        let index = sample
        XCTAssertFalse(index.contains(tileKey: "15/1/1"))
        XCTAssertFalse(index.matches(tileKey: "15/1/1",
                                     digest: [UInt8](repeating: 0xAB, count: 32)))
        XCTAssertFalse(index.contains(tileKey: "мусор"))
    }

    /// Дайджест не той длины не сравнивается «по префиксу».
    func testShortDigestNeverMatches() {
        XCTAssertFalse(sample.matches(tileKey: "15/22686/12247",
                                      digest: [UInt8](repeating: 0xAB, count: 31)))
        XCTAssertFalse(sample.matches(tileKey: "15/22686/12247", digest: []))
    }

    /// Битая запись в подписанном JSON выбрасывается, а не портит соседей.
    func testBrokenEntriesAreDroppedNotGuessed() {
        let index = TileDigestIndex(version: 1, tiles: [
            "15/1/1": hex(0x11),
            "мусор": hex(0x22),                              // ключ не тайл
            "15/2/2": "коротко",                             // дайджест не тот
        ])
        XCTAssertEqual(index.count, 1)
        XCTAssertTrue(index.contains(tileKey: "15/1/1"))
        XCTAssertFalse(index.contains(tileKey: "15/2/2"))
    }

    // MARK: - Диск

    func testRoundTripThroughDisk() throws {
        let index = try XCTUnwrap(TileDigestIndex(serialized: sample.serialized()))
        XCTAssertEqual(index.version, 7)
        XCTAssertEqual(index.count, 3)
        XCTAssertTrue(index.matches(tileKey: "15/22686/12247",
                                    digest: [UInt8](repeating: 0xAB, count: 32)))
        XCTAssertTrue(index.matches(tileKey: "11/1417/765",
                                    digest: [UInt8](repeating: 0x01, count: 32)))
        // И охрана после круга через диск не ослабла.
        XCTAssertFalse(index.matches(tileKey: "11/1417/765",
                                     digest: [UInt8](repeating: 0xAB, count: 32)))
    }

    /// Испорченный файл не разбирается «как получится»: тогда индекс качается
    /// заново. Половина индекса — это половина охраны, то есть её отсутствие.
    func testCorruptFileIsRefusedEntirely() {
        let good = sample.serialized()
        XCTAssertNil(TileDigestIndex(serialized: Data()))
        XCTAssertNil(TileDigestIndex(serialized: good.prefix(10)))          // обрезан
        XCTAssertNil(TileDigestIndex(serialized: good.dropLast(5)))         // не сошлась длина
        var alien = Data(good); alien[0] = 0x00                             // чужая магия
        XCTAssertNil(TileDigestIndex(serialized: alien))
        var wrongFormat = Data(good); wrongFormat[4] = 99                   // чужой формат
        XCTAssertNil(TileDigestIndex(serialized: wrongFormat))
    }

    /// Файл с переставленными ключами отвергается: на порядке стоит двоичный
    /// поиск, и «почти отсортированный» индекс молча терял бы тайлы.
    func testUnsortedFileIsRefused() {
        var data = Data(sample.serialized())
        let header = 17
        // Меняем местами первый и второй ключ.
        for offset in 0..<8 {
            data.swapAt(header + offset, header + 8 + offset)
        }
        XCTAssertNil(TileDigestIndex(serialized: data))
    }

    // MARK: - Ради чего всё

    /// Размер на диске — линейный и маленький: 40 байт на тайл вместо строки
    /// ключа и 64-символьного hex. На боевом индексе в 165 054 тайла это
    /// 6,6 МБ против тридцати с лишним у прежнего словаря.
    func testSizeIsFortyBytesPerTile() {
        let bytes = sample.serialized().count
        XCTAssertEqual(bytes, 17 + 3 * (8 + 32))
        let production = 17 + 165_054 * (8 + 32)
        XCTAssertLessThan(production, 7 * 1024 * 1024)
    }
}
