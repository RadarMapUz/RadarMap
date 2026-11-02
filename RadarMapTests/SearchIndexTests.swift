//
//  SearchIndexTests.swift
//  RadarMapTests
//
//  Свой поиск по всем именам (40G): «метро хамза» находит «Новзу», имена на
//  трёх письменностях равны, опечатка находит, порядок — точное > начало >
//  старое имя > нечёткое; новые поля клетки необязательны для старых файлов.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class SearchIndexTests: XCTestCase {

    private let near = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)

    /// Адреса в виде build_roads.addresses_by_cell + search_names (поля a/o).
    private let addressCell = #"""
    {"version":1,"streets":[\#
    {"n":"Amir Temur shoh ko'chasi","h":["5","51","7"],"p":[4131000,6928000,100,0,100,0],\#
    "a":["Амира Темура проспект"],"o":["Московская улица"]},\#
    {"n":"Botkin ko'chasi","h":["1"],"p":[4130500,6930700],"a":["Mirzo Ulugbek Avenue"]},\#
    {"n":"Mirzo Ulug'bek shoh ko'chasi","h":["2"],"p":[4132000,6933000]},\#
    {"n":"Xamza ko'chasi","h":["3"],"p":[4129900,6930000],"o":["улица Сельмашская"]},\#
    {"n":"Novza ko'chasi","h":["4"],"p":[4129100,6922300]},\#
    {"n":"Chorsu maydoni","h":["6"],"p":[4132600,6923700]}]}
    """#

    /// Заведения: метро (14) с именами пятым/шестым элементом, места (15).
    private let venueCell = #"""
    {"version":1,"venues":[\#
    [14,"Новза",4129187,6922362,[],["Хамза"]],\#
    [14,"Чорсу",4132586,6923682],\#
    [14,"Дружба Народов",4131190,6924310,["Xalqlar doʻstligi"],["Bunyodkor"]],\#
    [15,"Ташкент",4131234,6927871,["Toshkent"],["Chach"]],\#
    [15,"Чорсу",4131950,6923070,["Chorsu mavzesi"]],\#
    [7,"Oqtepa Lavash - Chorsu 2",4132256,6923855],\#
    [1,"Lukoil",4130000,6925000],[99,"Будущий вид",4130000,6925000]]}
    """#

    private func index() -> SearchIndex {
        guard let book = AddressBook.decode(Data(addressCell.utf8)),
              let venues = VenueBook.decode(Data(venueCell.utf8)) else {
            XCTFail("клетки не разобрались"); return SearchIndex(book: nil, venues: nil)
        }
        return SearchIndex(book: book, venues: venues)
    }

    // MARK: - Формат

    func testNewFieldsAreReadAndOldFilesStillDecode() {
        let book = AddressBook.decode(Data(addressCell.utf8))
        XCTAssertEqual(book?.streets.first?.aliases, ["Амира Темура проспект"])
        XCTAssertEqual(book?.streets.first?.oldNames, ["Московская улица"])
        let venues = VenueBook.decode(Data(venueCell.utf8))
        XCTAssertEqual(venues?.venues.count, 7, "незнакомый вид 99 пропущен, как раньше")
        XCTAssertEqual(venues?.venues.first?.kind, .metro)
        XCTAssertEqual(venues?.venues.first?.oldNames, ["Хамза"])
        XCTAssertEqual(venues?.venues.first?.aliases, [])
        // Старый формат без a/o и пятого элемента — те же записи, имена пусты.
        let old = AddressBook.decode(Data(#"{"streets":[{"n":"A","h":["1"],"p":[4130000,6925000]}]}"#.utf8))
        XCTAssertEqual(old?.streets.first?.aliases, [])
        XCTAssertEqual(VenueBook.decode(Data(#"{"venues":[[1,"A",4130000,6925000]]}"#.utf8))?.venues.first?.oldNames, [])
        // Мусор вместо имён — запись цела, имён нет.
        let junk = VenueBook.decode(Data(#"{"venues":[[14,"A",4130000,6925000,7,"x"]]}"#.utf8))
        XCTAssertEqual(junk?.venues.first?.aliases, [])
        XCTAssertEqual(junk?.venues.first?.name, "A")
    }

    // MARK: - Жалоба владельца

    func testMetroHamzaFindsNovzaByItsOldName() {
        for query in ["метро хамза", "hamza metro", "Метро Ҳамза", "xamza bekati"] {
            let answer = index().search(query, near: near)
            XCTAssertEqual(answer.venues.first?.name, "Новза", query)
            XCTAssertEqual(answer.formerNames[answer.venues.first?.id ?? ""], "Хамза", query)
            XCTAssertTrue(answer.venuesFirst, "«метро …» — станция выше улицы: \(query)")
        }
    }

    func testCurrentNameIsFoundWithoutTheFormerCaption() {
        for query in ["новза", "novza", "метро новза", "Novz"] {
            let answer = index().search(query, near: near)
            XCTAssertEqual(answer.venues.first?.name, "Новза", query)
            XCTAssertNil(answer.formerNames[answer.venues.first?.id ?? ""], "нашлось по нынешнему имени: \(query)")
        }
    }

    func testChorsuIsTheStationAndThePlaceBeforeTheCafe() {
        for query in ["Чорсу", "chorsu", "CHORSU"] {
            let names = index().search(query, near: near).venues.map(\.kind)
            XCTAssertEqual(Array(names.prefix(3)), [.metro, .place, .food], query)
        }
    }

    func testCityByItsUzbekName() {
        let answer = index().search("Тошкент шахри", near: near)
        XCTAssertEqual(answer.venues.first?.name, "Ташкент")
        XCTAssertEqual(answer.venues.first?.kind, .place)
    }

    func testTyposAndRussianCaseFindAmirTemur() {
        for query in ["амир темур", "амира тимура", "Amir Timur", "амир темр"] {
            XCTAssertEqual(index().search(query, near: near).addresses.first?.street,
                           "Amir Temur shoh ko'chasi", query)
        }
    }

    func testHouseNumberOnAnyNameOfTheStreet() {
        let answer = index().search("амира тимура 5", near: near)
        XCTAssertEqual(answer.addresses.first?.title, "Amir Temur shoh ko'chasi, 5", "точный номер — первым")
        XCTAssertEqual(answer.addresses.count, 2, "5 и 51")
        XCTAssertTrue(answer.venues.isEmpty, "с номером дома — только дома")
    }

    func testOldStreetNameIsCaptioned() {
        let answer = index().search("Московская", near: near)
        XCTAssertEqual(answer.addresses.first?.street, "Amir Temur shoh ko'chasi")
        XCTAssertEqual(answer.formerNames[answer.addresses.first?.id ?? ""], "Московская улица")
    }

    func testStreetWordIsOptional() {
        for query in ["улица Хамза", "Xamza ko'chasi", "хамза ул"] {
            XCTAssertEqual(index().search(query, near: near).addresses.first?.street, "Xamza ko'chasi", query)
        }
    }

    func testKindWordAloneAnswersWithNearestOfKind() {
        let answer = index().search("метро", near: near)
        XCTAssertEqual(answer.venues.count, 3)
        XCTAssertTrue(answer.venues.allSatisfy { $0.kind == .metro })
        XCTAssertEqual(index().search("азс", near: near).venues.first?.name, "Lukoil")
    }

    func testPrimaryNameBeatsTheSameNameWrittenSecond() {
        // У куска «Botkin ko'chasi» в OSM int_name «Mirzo Ulugbek Avenue», и он
        // ближе к машине — но улица, которая так и называется, выше.
        XCTAssertEqual(index().search("мирзо улугбек", near: near).addresses.first?.street,
                       "Mirzo Ulug'bek shoh ko'chasi")
    }

    // MARK: - Порядок

    func testTierOrderExactPrefixOldFuzzy() {
        let venues = VenueBook(venues: [
            Venue(kind: .food, name: "Хамса", point: near),                         // нечёткое
            Venue(kind: .food, name: "Кафе", point: near, oldNames: ["Хамза"]),    // старое имя
            Venue(kind: .food, name: "Хамзаабад", point: near),                     // начало
            Venue(kind: .food, name: "Хамза", point: near),                         // точное
        ])
        let found = SearchIndex(book: nil, venues: venues).search("хамза ", near: near).venues.map(\.name)
        XCTAssertEqual(found, ["Хамза", "Хамзаабад", "Кафе", "Хамса"])
    }

    func testCloserWinsWithinTheSameTier() {
        let far = CLLocationCoordinate2D(latitude: 41.40, longitude: 69.40)
        let venues = VenueBook(venues: [Venue(kind: .food, name: "Лаваш", point: far),
                                        Venue(kind: .food, name: "Лаваш", point: near)])
        let found = SearchIndex(book: nil, venues: venues).search("лаваш", near: near).venues
        XCTAssertEqual(found.first?.point.latitude, near.latitude)
    }

    // MARK: - Приведение и расстояние

    func testFoldMakesTheThreeScriptsEqual() {
        let groups = [
            ["Ўзбекистон", "O'zbekiston", "Oʻzbekiston", "о'збекистон", "Узбекистон"],
            ["Ғафур Ғулом", "G'afur G'ulom", "Gʻafur Gʻulom", "гʻафур гʻулом", "Гафур Гулом"],
            ["Ҳамза", "Hamza", "Xamza", "Хамза", "Khamza"],
            ["Қўйлиқ", "Qo'yliq", "Куйлик"],
            ["Алимджан", "Olimjon", "Alimdjan"],
            ["Ёшлик", "Yoshlik"],
            ["Навоий", "Navoiy", "Навои"],
        ]
        for group in groups {
            let folded = Set(group.map { SearchIndex.fold($0) })
            XCTAssertEqual(folded.count, 1, "\(group) → \(folded)")
        }
    }

    func testYoAndYeAreOneLetterForTheRussianTypist() {
        let venues = VenueBook(venues: [Venue(kind: .place, name: "Бунёдкор", point: near)])
        XCTAssertEqual(SearchIndex(book: nil, venues: venues).search("бунедкор", near: near).venues.count, 1)
    }

    func testDamerauLevenshtein() {
        func d(_ a: String, _ b: String) -> Int { SearchIndex.osa(Array(a.utf8), Array(b.utf8), limit: 3) }
        XCTAssertEqual(d("hamza", "hamza"), 0)
        XCTAssertEqual(d("hamza", "hmaza"), 1, "перестановка соседних — одна правка")
        XCTAssertEqual(d("timura", "temur"), 2)
        XCTAssertEqual(d("abc", "xyzabc"), 3)
        XCTAssertEqual(SearchIndex.prefixOSA(Array("hamzq".utf8), Array("hamzaabad".utf8), limit: 2), 1)
        XCTAssertGreaterThan(SearchIndex.prefixOSA(Array("navza".utf8), Array("navai".utf8), limit: 1), 1,
                             "начало короче запроса не считается: «новза» — не «Навои»")
    }

    func testShortWordsAreNeverFuzzy() {
        XCTAssertEqual(SearchIndex.maxEdits(3), 0)
        XCTAssertEqual(SearchIndex.maxEdits(5), 1)
        XCTAssertEqual(SearchIndex.maxEdits(9), 2)
        let venues = VenueBook(venues: [Venue(kind: .food, name: "Уч", point: near)])
        XCTAssertTrue(SearchIndex(book: nil, venues: venues).search("ук", near: near).venues.isEmpty)
    }

    func testMetroAndPlaceWordsAreWholeWordsOnly() {
        XCTAssertNil(VenueBook.kind(for: "мах"), "«мах» — начало «Махтумкули», а не все махалли")
        XCTAssertNil(VenueBook.kind(for: "метр"))
        XCTAssertEqual(VenueBook.kind(for: "метро"), .metro)
        XCTAssertEqual(VenueBook.kind(for: "махалля"), .place)
        XCTAssertEqual(VenueBook.kind(for: "мет"), .cng, "начало «метана» — как было")
    }

    func testEmptyAndTooShortQueries() {
        XCTAssertTrue(index().search("", near: near).addresses.isEmpty)
        XCTAssertTrue(index().search("а", near: near).venues.isEmpty)
        XCTAssertTrue(SearchIndex(book: nil, venues: nil).search("хамза", near: near).venues.isEmpty)
    }
}
