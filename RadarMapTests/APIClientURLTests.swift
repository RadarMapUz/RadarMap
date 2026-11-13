//
//  APIClientURLTests.swift
//  RadarMapTests
//
//  DEBUG `-apiBase`: прогон отметок на симуляторе обязан уходить на подменный
//  сервер целиком — любой `api/…`, иначе фейковая тренога встанет у реальных
//  водителей. Карта и файлы при этом остаются на своём корне.
//

import XCTest
@testable import RadarMap

final class APIClientURLTests: XCTestCase {

    private let base = URL(string: "https://example.org/radarmap")!
    private let mock = URL(string: "http://127.0.0.1:8796")!

    func testWithoutOverrideEverythingGoesToBase() {
        XCTAssertEqual(APIClient.url("api/report", base: base, apiOverride: nil).absoluteString,
                       "https://example.org/radarmap/api/report")
        XCTAssertEqual(APIClient.url("version.json", base: base, apiOverride: nil).absoluteString,
                       "https://example.org/radarmap/version.json")
    }

    func testEveryApiPathGoesToOverride() {
        for path in ["api/report", "api/report/cancel", "api/vote", "api/mobile", "api/road",
                     "api/mine", "api/traffic", "api/stat", "api/metrics", "api/eta"] {
            XCTAssertEqual(APIClient.url(path, base: base, apiOverride: mock).absoluteString,
                           "http://127.0.0.1:8796/" + path, path)
        }
    }

    func testFilesStayOnBaseWithOverride() {
        for path in ["version.json", "traffic/now.json", "hotspots.json", "mvt_index.json"] {
            XCTAssertEqual(APIClient.url(path, base: base, apiOverride: mock).absoluteString,
                           "https://example.org/radarmap/" + path, path)
        }
    }

    func testReleaseHasNoOverride() {
        // В тестовом процессе ключа нет — подмены нет.
        XCTAssertNil(AppConfig.debugAPIBaseURL)
    }
}
