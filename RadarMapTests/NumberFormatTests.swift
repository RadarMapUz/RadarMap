//
//  NumberFormatTests.swift
//  RadarMapTests
//
//  Язык чисел — язык текста приложения. В бандле есть en.lproj (фразы Siri),
//  и на телефоне с английским языком системы числа выходили с точкой посреди
//  русского текста: «11.7 км» на карточке прибытия (поездка владельца 21.10).
//

import XCTest
@testable import RadarMap

final class NumberFormatTests: XCTestCase {

    func testEnglishPhoneStillFormatsNumbersInTheAppsTextLanguage() {
        XCTAssertEqual(NumberFormat.contentLanguage(["en"]), "ru")
        XCTAssertEqual(NumberFormat.contentLanguage(["en-US", "uz"]), "uz")
        XCTAssertEqual(NumberFormat.contentLanguage([]), "ru")
    }

    func testRussianAndUzbekPassThrough() {
        XCTAssertEqual(NumberFormat.contentLanguage(["ru"]), "ru")
        XCTAssertEqual(NumberFormat.contentLanguage(["uz-Latn"]), "uz")
        XCTAssertEqual(NumberFormat.contentLanguage(["uz", "ru"]), "uz")
    }

    func testDecimalUsesCommaForBothContentLanguages() {
        for language in ["ru", "uz"] {
            let text = NumberFormat.decimal(11.7, locale: Locale(identifier: language))
            XCTAssertEqual(text, "11,7", "дробь через запятую: \(language)")
        }
    }
}
