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

    func testTierOrderExactPrefixOld() {
        let venues = VenueBook(venues: [
            Venue(kind: .food, name: "Кафе", point: near, oldNames: ["Хамза"]),    // старое имя
            Venue(kind: .food, name: "Хамзаабад", point: near),                     // начало
            Venue(kind: .food, name: "Хамза", point: near),                         // точное
        ])
        let found = SearchIndex(book: nil, venues: venues).search("хамза ", near: near).venues.map(\.name)
        XCTAssertEqual(found, ["Хамза", "Хамзаабад", "Кафе"])
    }

    func testFuzzyOnlyWhenNothingPreciseWasFound() {
        let venues = VenueBook(venues: [Venue(kind: .food, name: "Хамса", point: near),
                                        Venue(kind: .fuel, name: "Лукойл", point: near)])
        let index = SearchIndex(book: nil, venues: venues)
        XCTAssertEqual(index.search("хамза ", near: near).venues.map(\.name), ["Хамса"], "опечатка — находит")
        // Точный ответ есть — нечёткий хвост не показываем (ревью 03.11: «лукойл»
        // давал девять улиц «Suhayl ko'chasi» над ответами Apple).
        let streets = AddressBook(addresses: [Address(street: "Suhayl ko'chasi", house: "1", point: near)])
        let mixed = SearchIndex(book: streets, venues: venues).search("лукойл", near: near)
        XCTAssertEqual(mixed.venues.map(\.name), ["Лукойл"])
        XCTAssertTrue(mixed.addresses.isEmpty)
    }

    func testFormerCaptionOnlyForAnOldNameMatch() {
        // Нечёткое попадание рядом со старым именем — без «бывш.»: подпись
        // объясняет, почему нашлось, и не должна выдавать догадку за факт.
        let venues = VenueBook(venues: [Venue(kind: .food, name: "Кафе", point: near, oldNames: ["Хамза"])])
        let answer = SearchIndex(book: nil, venues: venues).search("хамса ", near: near)
        XCTAssertEqual(answer.venues.count, 1)
        XCTAssertTrue(answer.formerNames.isEmpty)
    }

    func testNumberedQuarterIsAPlaceNotAHouse() {
        let venues = VenueBook(venues: [Venue(kind: .place, name: "Юнусабад-11", point: near),
                                        Venue(kind: .place, name: "Чиланзар-9", point: near)])
        let streets = AddressBook(addresses: [Address(street: "Eski Yunusobod ko'chasi", house: "11", point: near)])
        let index = SearchIndex(book: streets, venues: venues)
        let answer = index.search("Юнусабад 11", near: near)
        XCTAssertEqual(answer.venues.map(\.name), ["Юнусабад-11"], "число — часть имени квартала")
        XCTAssertEqual(answer.addresses.first?.title, "Eski Yunusobod ko'chasi, 11", "и дом с этим номером")
        XCTAssertTrue(answer.venuesFirst)
        XCTAssertEqual(index.search("чиланзар 9", near: near).venues.map(\.name), ["Чиланзар-9"])
    }

    func testShortWordNeverMeansStreetType() {
        // «ka» — начало «kachasi» (так приводится «ko'chasi» без «ў») у каждой
        // улицы: «ka 1» не должен значить «дом 1 любой улицы».
        let streets = AddressBook(addresses: [Address(street: "Navoiy ko'chasi", house: "1", point: near),
                                              Address(street: "Kamolon ko'chasi", house: "1", point: near)])
        let answer = SearchIndex(book: streets, venues: nil).search("ka 1", near: near)
        XCTAssertEqual(answer.addresses.map(\.street), ["Kamolon ko'chasi"])
    }

    func testInitialWithADotIsSearchedAsAPrefix() {
        let streets = AddressBook(addresses: [Address(street: "K.G'ofurov ko'chasi", house: "1", point: near)])
        let venues = VenueBook(venues: [Venue(kind: .place, name: "Гулистан (колхоз Правда)", point: near)])
        let index = SearchIndex(book: streets, venues: venues)
        let answer = index.search("K.G‘", near: near)
        XCTAssertEqual(answer.addresses.count, 1, "старый поиск находил — и этот")
        XCTAssertTrue(answer.venues.isEmpty, "инициал началом — только улицы, не полгорода мест")
        XCTAssertEqual(index.search("K.G‘ofurov", near: near).addresses.count, 1)
    }

    func testStreetTypeWordBeingTypedDoesNotBlankTheAnswer() {
        // Повторное ревью 03.11: «шо», «йу», «йул» — начало «shoh», «yo'li»;
        // посреди набора ответ пропадал до следующей буквы.
        let streets = AddressBook(addresses: [
            Address(street: "Amir Temur shoh ko'chasi", house: "1", point: near),
            Address(street: "Buyuk Ipak yo'li ko'chasi", house: "2", point: near),
        ])
        let index = SearchIndex(book: streets, venues: nil)
        for (query, street) in [("амир темур шо", "Amir Temur shoh ko'chasi"),
                                ("буюк ипак йу", "Buyuk Ipak yo'li ko'chasi"),
                                ("буюк ипак йул", "Buyuk Ipak yo'li ko'chasi"),
                                ("амир темур шох", "Amir Temur shoh ko'chasi")] {
            XCTAssertEqual(index.search(query, near: near).addresses.first?.street, street, query)
        }
        // Единственное слово и две буквы перед номером — по-прежнему не «все улицы».
        XCTAssertTrue(index.search("ko", near: near).addresses.isEmpty)
        XCTAssertTrue(index.search("ka 1", near: near).addresses.isEmpty)
    }

    func testCloserWinsWithinTheSameTier() {
        let far = CLLocationCoordinate2D(latitude: 41.40, longitude: 69.40)
        let venues = VenueBook(venues: [Venue(kind: .food, name: "Лаваш", point: far),
                                        Venue(kind: .food, name: "Лаваш", point: near)])
        let found = SearchIndex(book: nil, venues: venues).search("лаваш", near: near).venues
        XCTAssertEqual(found.first?.point.latitude, near.latitude)
    }

    func testStreetTypeWordWithHouseFindsTheHouse() {
        for query in ["Xamza ko'chasi 3", "хамза кўчаси 3", "улица Хамза 3"] {
            XCTAssertEqual(index().search(query, near: near).addresses.first?.title, "Xamza ko'chasi, 3", query)
        }
    }

    /// Номер дома у многих улиц сразу (индекс номеров + отбор первых без
    /// полной сортировки): точный номер выше начала номера, ближе — выше,
    /// начало номера добирается, только если точных не хватило.
    func testHouseAcrossManyStreetsKeepsTheOrder() {
        var addresses: [Address] = []
        for i in 0..<40 {
            let lat = near.latitude + 0.001 * Double((i * 17) % 40 + 1)
            for (house, shift) in [("1", 0.0), ("10", 0.0002), ("1a", 0.0003), ("21", 0.0004)] {
                addresses.append(Address(street: "Kamolon-\(i) ko'chasi", house: house,
                                         point: CLLocationCoordinate2D(latitude: lat + shift, longitude: near.longitude)))
            }
        }
        for i in 0..<30 {
            addresses.append(Address(street: "Navoiy-\(i) ko'chasi", house: "1",
                                     point: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude + 0.0001 * Double(i))))
        }
        let index = SearchIndex(book: AddressBook(addresses: addresses), venues: nil)

        let exact = index.search("ka 1", near: near).addresses
        XCTAssertEqual(exact.count, 12)
        XCTAssertTrue(exact.allSatisfy { $0.house == "1" && $0.street.hasPrefix("Kamolon") })
        XCTAssertEqual(exact.map(\.point.latitude), exact.map(\.point.latitude).sorted(), "ближе — выше")
        XCTAssertEqual(exact.first?.point.latitude ?? 0, near.latitude + 0.001, accuracy: 1e-9)

        let prefix = index.search("ka 2", near: near).addresses
        XCTAssertEqual(prefix.count, 12, "точного «2» нет — начало номера")
        XCTAssertTrue(prefix.allSatisfy { $0.house == "21" })
        XCTAssertEqual(prefix.map(\.point.latitude), prefix.map(\.point.latitude).sorted())

        // Kamolon-3 и Kamolon-30…39: одиннадцать домов «1», двенадцатый —
        // начало номера у улицы, совпавшей точно.
        let mixed = index.search("kamolon-3 1", near: near).addresses
        XCTAssertEqual(mixed.count, 12)
        XCTAssertEqual(mixed.first?.title, "Kamolon-3 ko'chasi, 1")
        XCTAssertTrue(mixed.prefix(11).allSatisfy { $0.house == "1" })
        XCTAssertEqual(mixed.last?.title, "Kamolon-3 ko'chasi, 10")

        let typed = index.search("ko", near: near).addresses
        XCTAssertEqual(typed.count, 12)
        XCTAssertTrue(typed.allSatisfy { $0.street.hasPrefix("Kamolon") }, "«ko» — не каждая «… ko'chasi»")
    }

    func testOneAddressIsOneRow() {
        let contour = CLLocationCoordinate2D(latitude: near.latitude + 0.0001, longitude: near.longitude)
        let streets = AddressBook(addresses: [Address(street: "Xamza ko'chasi", house: "1", point: near),
                                              Address(street: "Xamza ko'chasi", house: "1", point: contour)])
        XCTAssertEqual(SearchIndex(book: streets, venues: nil).search("хамза 1", near: near).addresses.count, 1)
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
