//
//  RegionEnterQueueTests.swift
//  RadarMapTests
//
//  Входы в геозоны до загрузки базы камер (сценарий S3, 20.10): вход ждёт
//  базу и не теряется; повтор не множится; вошли и вышли — камера позади.
//

import XCTest
@testable import RadarMap

final class RegionEnterQueueTests: XCTestCase {
    func testEntersWaitForTheDatabaseOncePerRegion() {
        var queue = RegionEnterQueue()
        queue.enter("cam-1")
        queue.enter("cam-2")
        queue.enter("cam-1")
        XCTAssertEqual(queue.drain(), ["cam-1", "cam-2"])
        XCTAssertTrue(queue.drain().isEmpty, "разобранное второй раз не приходит")
    }

    func testExitBeforeTheDatabaseCancelsTheEnter() {
        var queue = RegionEnterQueue()
        queue.enter("cam-1")
        queue.enter("cam-2")
        queue.exit("cam-1")
        XCTAssertEqual(queue.drain(), ["cam-2"], "вошли и вышли — камера уже позади")
    }
}
