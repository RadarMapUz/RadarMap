import XCTest
@testable import RadarMap

final class DeepLinkTests: XCTestCase {
    private func parse(_ s: String) -> DeepLink? { DeepLink.parse(URL(string: s)!) }

    func testWidgetsOpenTheOverview() {
        XCTAssertEqual(parse("radarmap://stats"), .stats)
        XCTAssertEqual(parse("radarmap://trip"), .stats)
    }

    /// Пуш про конкретную поездку открывает её, а не обзор (до 19.10 путь
    /// игнорировался).
    func testTripSummaryPushOpensThatTrip() {
        let id = 1_760_870_400.25
        XCTAssertEqual(DeepLink.parse(DeepLink.trip(id)), .trip(id: id))
        // Пуши старых версий, уже лежащие в Центре уведомлений.
        XCTAssertEqual(parse("radarmap://trip/last"), .lastTrip)
    }

    func testUnknownPathStillOpensTheOverview() {
        XCTAssertEqual(parse("radarmap://trip/whatever"), .stats)
    }

    func testForeignLinksAreNotOurs() {
        XCTAssertNil(parse("radarmap://start-trip"), "старт поездки разбирает RootView")
        XCTAssertNil(parse("radarmap://map"))
        XCTAssertNil(parse("https://soulmed.uz/radarmap/trip"))
    }
}
