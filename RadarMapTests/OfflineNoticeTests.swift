//
//  OfflineNoticeTests.swift
//  RadarMapTests
//
//  Плашка «нет связи»: со связью её нет вовсе, на новой карте она различает
//  «карта из скачанной области» и «карта не грузится», и скачать область
//  предлагает только там, где области нет.
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
        XCTAssertEqual(notice?.offersDownload, false, "область уже на телефоне — качать нечего")
    }

    func testNoRegionOffersDownload() {
        let notice = OfflineNotice.resolve(online: false, modernMap: true, hasRegionFiles: false)
        XCTAssertEqual(notice, .noMap)
        XCTAssertEqual(notice?.offersDownload, true)
    }

    func testOtherMapKeepsGeneralBanner() {
        for files in [true, false] {
            let notice = OfflineNotice.resolve(online: false, modernMap: false, hasRegionFiles: files)
            XCTAssertEqual(notice, .general, "на карте Apple скачанная область ничего не меняет")
            XCTAssertEqual(notice?.offersDownload, false)
        }
    }
}
