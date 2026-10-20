//
//  UzbekApostropheTests.swift
//  RadarMapTests
//
//  Узбекский апостроф — по стандарту одним знаком (11.9): «oʻ», «gʻ» —
//  U+02BB, тутуқ белгиси («maʼlumot», «CarPlayʼda») — U+02BC. До 20.10 в
//  каталоге жили «'», «‘» и «’» вперемешку: шрифт рисует их по-разному, и
//  одно слово на соседних экранах выглядело по-разному.
//

import XCTest

final class UzbekApostropheTests: XCTestCase {
    func testUzbekStringsUseStandardApostrophes() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                                  inDirectory: nil, forLocalization: "uz"),
                                 "в сборке нет узбекского каталога")
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertGreaterThan(table.count, 500)
        let wrong = table.filter { _, value in value.contains { "'‘’`".contains($0) } }
        XCTAssertEqual(wrong.map(\.value).sorted(), [])
    }
}
