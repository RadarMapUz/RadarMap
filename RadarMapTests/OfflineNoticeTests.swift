//
//  OfflineNoticeTests.swift
//  RadarMapTests
//
//  Плашка «нет связи»: со связью её нет вовсе, на новой карте она различает
//  «карта из скачанной области» и «карта не грузится».
//

import XCTest
@testable import RadarMap

final class OfflineNoticeTests: XCTestCase {

    func testOnlineShowsNothing() {
        for modern in [true, false] {
            for files in [true, false] {
                XCTAssertNil(OfflineNotice.resolve(online: true, modernMap: modern, hasRegionFiles: files))
            }
        }
    }

    func testDownloadedRegionIsCalm() {
        let notice = OfflineNotice.resolve(online: false, modernMap: true, hasRegionFiles: true)
        XCTAssertEqual(notice, .downloadedRegion)
    }

    func testNoRegionSaysNoMap() {
        let notice = OfflineNotice.resolve(online: false, modernMap: true, hasRegionFiles: false)
        XCTAssertEqual(notice, .noMap)
    }

    func testOtherMapKeepsGeneralBanner() {
        for files in [true, false] {
            let notice = OfflineNotice.resolve(online: false, modernMap: false, hasRegionFiles: files)
            XCTAssertEqual(notice, .general, "на карте Apple скачанная область ничего не меняет")
        }
    }
}
