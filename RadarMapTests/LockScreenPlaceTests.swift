import CoreLocation
import XCTest
@testable import RadarMap

final class LockScreenPlaceTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 41.311, longitude: 69.279)
    private let work = CLLocationCoordinate2D(latitude: 41.350, longitude: 69.330)
    private let cafe = CLLocationCoordinate2D(latitude: 41.280, longitude: 69.200)

    private func label(_ name: String, _ destination: CLLocationCoordinate2D?, privateMode: Bool = false) -> LockScreenPlace {
        LockScreenPlace.label(routeName: name, destination: destination, home: home, work: work, privateMode: privateMode)
    }

    func testHomeAddressNeverReachesTheLockScreen() {
        XCTAssertEqual(label("ул. Нурафшон, 14, кв. 7", home), .home)
        let beside = CLLocationCoordinate2D(latitude: home.latitude + 0.002, longitude: home.longitude)
        XCTAssertEqual(label("Нурафшон 16", beside), .home, "соседний дом — тот же адрес для чужого глаза")
    }

    func testWorkIsNamedByTheWord() {
        XCTAssertEqual(label("Улица Амира Темура, 108", work), .work)
    }

    func testPrivateModeHidesEverything() {
        XCTAssertEqual(label("Кафе", cafe, privateMode: true), .hidden)
        XCTAssertEqual(label("Дом", home, privateMode: true), .hidden)
    }

    func testOtherPlacesKeepTheirName() {
        XCTAssertEqual(label("Чорсу", cafe), .named("Чорсу"))
        XCTAssertEqual(label("", cafe), .hidden)
        XCTAssertEqual(label("Чорсу", nil), .named("Чорсу"), "цель неизвестна — близость не доказана")
    }
}
