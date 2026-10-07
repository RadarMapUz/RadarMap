//
//  StreetNameTests.swift
//  RadarMapTests
//
//  Имя улицы в манёвре на языке приложения. Жалоба с дороги: в русской версии
//  баннер и голос говорили «держитесь правее на Beruniy shoh ko'chasi».
//

import XCTest
@testable import RadarMap

final class StreetNameTests: XCTestCase {

    private func ru(_ name: String) -> String {
        StreetName.display(name, language: "ru")
    }

    func testTheComplaintFromTheRoad() {
        XCTAssertEqual(ru("Beruniy shoh ko'chasi"), "улица Беруни")
    }

    func testUzbekTypesBecomeRussianWords() {
        XCTAssertEqual(ru("Navoiy ko'chasi"), "улица Навои")
        XCTAssertEqual(ru("Amir Temur prospekti"), "проспект Амир Темур")
        XCTAssertEqual(ru("Mustaqillik maydoni"), "площадь Мустакиллик")
        XCTAssertEqual(ru("Bunyodkor shoh ko'chasi"), "улица Бунёдкор")
        XCTAssertEqual(ru("Toshkent halqa yo'li"), "кольцевая дорога Тошкент")
        XCTAssertEqual(ru("Furqat tor ko'chasi"), "переулок Фуркат")
    }

    /// Все виды апострофа — одна буква: OSM пишет кто как привык.
    func testApostropheVariants() {
        XCTAssertEqual(ru("Navoiy ko\u{02BB}chasi"), "улица Навои")
        XCTAssertEqual(ru("Navoiy ko\u{2019}chasi"), "улица Навои")
        XCTAssertEqual(ru("G\u{2018}afur G\u{2018}ulom ko\u{2018}chasi"), "улица Гафур Гулом")
    }

    /// «berk ko'chasi» — тупик, а не улица «… берк»: длинный тип раньше короткого.
    func testLongerTypeWinsAndOrdinalMoves() {
        XCTAssertEqual(ru("Shota Rustaveli 1-berk ko'chasi"), "1-й тупик Шота Руставели")
        XCTAssertEqual(ru("Shota Rustaveli berk ko'chasi"), "тупик Шота Руставели")
    }

    /// «yo'» — это «ю» (Yo'ldosh → Юлдош), а не «ё» с лишним апострофом; но в
    /// «yog'och» апостроф принадлежит «g», и там честное «ё».
    func testDigraphs() {
        XCTAssertEqual(StreetName.russianName("Yo'ldosh"), "Юлдош")
        XCTAssertEqual(StreetName.russianName("Beshyog'och"), "Бешёгоч")
        XCTAssertEqual(StreetName.russianName("Yunusobod"), "Юнусобод")
        XCTAssertEqual(StreetName.russianName("Chilonzor"), "Чилонзор")
        XCTAssertEqual(StreetName.russianName("Shayxontohur"), "Шайхонтохур")
        XCTAssertEqual(StreetName.russianName("Ziyolilar"), "Зиёлилар")
    }

    func testUzbekCyrillicToo() {
        XCTAssertEqual(ru("Навоий кўчаси"), "улица Навои")
        XCTAssertEqual(ru("Беруний шоҳ кўчаси"), "улица Беруни")
    }

    /// Без узнанного типа — как есть: переписывать не за что, угадывать опасно.
    func testNamesWithoutTypeStayAsIs() {
        XCTAssertEqual(ru("Tashkent City"), "Tashkent City")
        XCTAssertEqual(ru("улица Фурката"), "улица Фурката")
        XCTAssertEqual(ru("Амира Темура"), "Амира Темура")
        XCTAssertEqual(ru("Ko'chasi"), "Ko'chasi", "один тип без имени не трогаем")
        XCTAssertEqual(ru(""), "")
    }

    /// В узбекской версии имя не меняется никогда.
    func testUzbekVersionKeepsTheName() {
        XCTAssertEqual(StreetName.display("Beruniy shoh ko'chasi", language: "uz"),
                       "Beruniy shoh ko'chasi")
    }

    /// Во фразе манёвра — винительный: «на улицу Беруни».
    func testAccusativeForTheManeuverPhrase() {
        XCTAssertEqual(StreetName.display("Beruniy shoh ko'chasi", language: "ru",
                                          grammaticalCase: .accusative), "улицу Беруни")
        XCTAssertEqual(StreetName.display("Amir Temur prospekti", language: "ru",
                                          grammaticalCase: .accusative), "проспект Амир Темур")
        XCTAssertEqual(StreetName.display("Shota Rustaveli 2-ko'chasi", language: "ru",
                                          grammaticalCase: .accusative), "2-ю улицу Шота Руставели")
    }

    /// Манёвр собирает фразу с тем же именем, что и голос (onManeuver несёт step.text).
    func testManeuverPhraseUsesTheDisplayName() {
        let step = RouteService.maneuverStep(
            RouteService.OSRMResponse.Step(
                distance: 100, name: "Beruniy shoh ko'chasi",
                maneuver: RouteService.OSRMResponse.Maneuver(type: "fork", modifier: "right",
                                                             exit: nil)),
            at: 500, language: "ru")
        XCTAssertNotNil(step)
        XCTAssertFalse(step?.text.contains("ko'chasi") ?? true)
        XCTAssertTrue(step?.text.contains("Беруни") ?? false)
    }
}
