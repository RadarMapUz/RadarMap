//
//  VenueBookTests.swift
//  RadarMapTests
//
//  Заведения для поиска: формат клетки «v», ближайшие по виду, поиск словом
//  вида и по имени.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class VenueBookTests: XCTestCase {

    /// Байты в том виде, в каком их пишет build_roads.venues_by_cell.
    private let golden = #"""
    {"version":1,"venues":[[1,"Lukoil",4130000,6925000],[1,"Узбекнефтегаз",4131000,6925000],\#
    [2,"",4130100,6925100],[99,"Новый вид",4130000,6925000],[1,"битая",null,6925000]]}
    """#

    private func book() -> VenueBook {
        guard let book = VenueBook.decode(Data(golden.utf8)) else {
            XCTFail("золотой файл не разобрался"); return VenueBook(venues: [])
        }
        return book
    }

    func testDecodeSkipsUnknownKindsAndBrokenRows() {
        let book = self.book()
        XCTAssertEqual(book.venues.count, 3, "незнакомый код и битая запись — пропущены, клетка цела")
        XCTAssertEqual(book.venues[0].point.latitude, 41.30, accuracy: 1e-6)
        XCTAssertNil(VenueBook.decode(Data("чушь".utf8)))
    }

    func testUnnamedParkingIsCalledByItsKind() {
        XCTAssertEqual(book().venues[2].title, Venue.Kind.parking.title)
    }

    func testNearestOfKindComesFirst() {
        let near = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.25)
        XCTAssertEqual(book().nearest(.fuel, to: near).first?.name, "Узбекнефтегаз")
        XCTAssertEqual(book().nearest(.parking, to: near).count, 1)
    }

    func testKindWordAnswersWithNearestOfThatKind() {
        XCTAssertEqual(VenueBook.kind(for: "заправ"), .fuel)
        XCTAssertEqual(VenueBook.kind(for: "АЗС"), .fuel)
        XCTAssertEqual(VenueBook.kind(for: "парковка"), .parking)
        XCTAssertNil(VenueBook.kind(for: "Навои"))
        XCTAssertEqual(book().search("азс", near: nil).count, 2)
    }

    func testNameSearchAcrossAlphabets() {
        XCTAssertEqual(book().search("lukoil", near: nil).first?.name, "Lukoil")
        XCTAssertEqual(book().search("Uzbekneftegaz", near: nil).first?.name, "Узбекнефтегаз")
        XCTAssertTrue(book().search("Х", near: nil).isEmpty, "одна буква — не запрос")
    }

    func testCellKeyIsTheAddressCellWithItsOwnLetter() {
        let point = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)
        XCTAssertEqual(VenueBook.key(for: point), "262_498_v")
        XCTAssertEqual(AddressBook.key(for: point), "262_498_a")
    }
}
