import XCTest
@testable import RadarMap

final class ControlBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshCommandIsTaken() {
        XCTAssertEqual(ControlBridge.fresh(raw: "report", at: now.addingTimeInterval(-3), now: now), .report)
        XCTAssertEqual(ControlBridge.fresh(raw: "soundOff", at: now, now: now), .soundOff)
    }

    /// Старое нажатие поставило бы радар не там, где его видели.
    func testOldCommandIsDropped() {
        XCTAssertNil(ControlBridge.fresh(raw: "report", at: now.addingTimeInterval(-ControlBridge.maxAge - 1), now: now))
        XCTAssertNil(ControlBridge.fresh(raw: "report", at: now.addingTimeInterval(5), now: now), "время из будущего")
        XCTAssertNil(ControlBridge.fresh(raw: nil, at: now, now: now))
        XCTAssertNil(ControlBridge.fresh(raw: "start", at: now, now: now))
    }

    func testCommandsMapToActivityDoors() {
        guard case .report = ControlBridge.Command.report.action else { return XCTFail() }
        guard case .setSound(on: true) = ControlBridge.Command.soundOn.action else { return XCTFail() }
        guard case .setSound(on: false) = ControlBridge.Command.soundOff.action else { return XCTFail() }
    }
}
