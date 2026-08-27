//
//  AddressBookTests.swift
//  RadarMapTests
//
//  Поиск адреса без сети.
//
//  Сторожатся три вещи, каждая из которых уже стоила бы доверия к поиску:
//  адрес не должен разъехаться по чужим домам при битом файле; «Навои 12»
//  должно находиться, как его ни напиши; и ближний дом должен стоять выше
//  дальнего — улица с одним названием есть в каждом районе.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class AddressBookTests: XCTestCase {

    /// Байты в том же виде, в каком их пишет build_roads.py.
    private let golden = #"""
    {"version":1,"streets":[{"n":"Alisher Navoiy ko'chasi","h":["12","12/1","14"],\#
    "p":[4130000,6925000,100,0,100,0]},\#
    {"n":"Amir Temur shoh ko'chasi","h":["1"],"p":[4131000,6928000]}]}
    """#

    private func book() -> AddressBook {
        guard let book = AddressBook.decode(Data(golden.utf8)) else {
            XCTFail("золотой файл не разобрался"); return AddressBook(addresses: [])
        }
        return book
    }

    func testDecodesHousesWithDeltas() {
        let book = self.book()
        XCTAssertEqual(book.addresses.count, 4)
        XCTAssertEqual(book.addresses.first?.street, "Alisher Navoiy ko'chasi")
        XCTAssertEqual(book.addresses.first?.house, "12")
        XCTAssertEqual(book.addresses[0].point.latitude, 41.30, accuracy: 1e-6)
        XCTAssertEqual(book.addresses[1].point.latitude, 41.301, accuracy: 1e-6)
        XCTAssertEqual(book.addresses[2].point.latitude, 41.302, accuracy: 1e-6)
    }

    func testStreetWithMismatchedCountsIsSkippedNotFatal() {
        // Номеров и координат разное число — адреса этой улицы разъехались бы
        // по чужим домам. Правильный ответ — не показать улицу, а не выбросить
        // весь город: соседние улицы человек найти должен.
        let broken = #"""
        {"version":1,"streets":[{"n":"Кривая","h":["1","2"],"p":[4130000,6925000]},\#
        {"n":"Целая","h":["1"],"p":[4130000,6925000]}]}
        """#
        let book = AddressBook.decode(Data(broken.utf8))
        XCTAssertEqual(book?.addresses.count, 1)
        XCTAssertEqual(book?.addresses.first?.street, "Целая")
    }

    func testGarbageIsNotAnAddressBook() {
        XCTAssertNil(AddressBook.decode(Data("не json".utf8)))
    }

    // MARK: - Поиск

    func testFindsStreetAndHouse() {
        XCTAssertEqual(book().search("Navoiy 12", near: nil).first?.house, "12")
    }

    // MARK: - Два алфавита

    func testCyrillicQueryFindsLatinStreet() {
        // Замерено на живом файле: из 630 улиц центра Ташкента 72 % записаны
        // в OSM латиницей и 28 % кириллицей. Без приведения водитель не
        // находит большинство города, на каком бы языке ни писал.
        XCTAssertEqual(book().search("Навои 12", near: nil).first?.house, "12")
        XCTAssertFalse(book().search("Темур", near: nil).isEmpty)
    }

    func testUzbekLatinAndRussianSpellingMeet() {
        // «Мустакиллик» против «Mustaqillik»: узбекская латиница и русская
        // транслитерация расходятся ровно на этих буквах.
        XCTAssertEqual(AddressBook.fold("Мустакиллик"),
                       AddressBook.fold("Mustaqillik"))
        // «Чиланзар» против «Chilonzor» — систематическое о/а.
        XCTAssertEqual(AddressBook.fold("Чиланзар"),
                       AddressBook.fold("Chilonzor"))
        XCTAssertEqual(AddressBook.fold("Ташкент"), AddressBook.fold("Toshkent"))
    }

    func testStreetWordsDoNotBlockTheMatch() {
        // «улица Навои» обязано находить «Alisher Navoiy ko'chasi»: слова
        // «улица» в нём нет, и оно не должно ничего решать.
        XCTAssertFalse(book().search("улица Навои", near: nil).isEmpty)
        XCTAssertFalse(book().search("Navoiy ko'chasi", near: nil).isEmpty)
    }

    func testWordOrderAndExtraWordsInDataDoNotMatter() {
        // Человек пишет «Темур Амир», в данных «Amir Temur shoh ko'chasi».
        XCTAssertFalse(book().search("Temur Amir", near: nil).isEmpty)
    }

    func testCaseAndApostropheDoNotMatter() {
        // «ko'chasi» пишут тремя разными апострофами; совпадение по знаку не
        // нашлось бы никогда.
        XCTAssertFalse(book().search("navoiy ko\u{2019}chasi", near: nil).isEmpty)
        XCTAssertFalse(book().search("NAVOIY", near: nil).isEmpty)
    }

    func testPartOfTheNameIsEnough() {
        // Человек пишет «Темура», а не «Amir Temur shoh ko'chasi».
        XCTAssertEqual(book().search("Temur", near: nil).first?.street,
                       "Amir Temur shoh ko'chasi")
    }

    func testExactHouseComesBeforeSimilar() {
        // «12» до «12/1»: иначе точный адрес прячется за похожим.
        XCTAssertEqual(book().search("Navoiy 12", near: nil).first?.house, "12")
    }

    func testHouseFilterActuallyFilters() {
        let found = book().search("Navoiy 14", near: nil)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.house, "14")
    }

    func testNearerComesFirst() {
        // Улица с одним названием есть в каждом районе; без этого первым
        // покажется случайный из них.
        let far = CLLocationCoordinate2D(latitude: 41.302, longitude: 69.25)
        let found = book().search("Navoiy", near: far)
        XCTAssertEqual(found.first?.house, "14")
    }

    func testTooShortQueryFindsNothing() {
        // Одна буква — это не запрос: он вернул бы полгорода.
        XCTAssertTrue(book().search("A", near: nil).isEmpty)
    }

    func testWordThatLooksLikeAStreetIsNotAHouseNumber() {
        XCTAssertTrue(book().search("Navoiy", near: nil).count >= 3)
    }

    // MARK: - Клетка

    func testCellKeyMatchesTheServer() {
        // Ключ считается ровно так же, как в build_roads.address_key:
        // (41.31 + 90) / 0.5 = 262, (69.28 + 180) / 0.5 = 498.
        XCTAssertEqual(
            AddressBook.key(for: CLLocationCoordinate2D(latitude: 41.31,
                                                        longitude: 69.28)),
            "262_498_a")
    }

    func testCellKeyHandlesNegativeCoordinates() {
        // Смещение в положительные придумано ровно ради этого случая.
        XCTAssertEqual(
            AddressBook.key(for: CLLocationCoordinate2D(latitude: -0.25,
                                                        longitude: -0.25)),
            "179_359_a")
    }
}
