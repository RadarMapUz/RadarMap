//
//  RegionCatalogTests.swift
//  RadarMapTests
//
//  Каталог офлайн-регионов: телефон и сервер (server/build_regions.py) обязаны
//  считать клетку точки ОДИНАКОВО — иначе дом окажется «не в той области» и
//  предложится не тот файл. Эталонные клетки посчитаны тем же кодом, что
//  режет регионы, и сверены с опубликованным каталогом (Ташкент → UZ-TK,
//  Самарканд → UZ-SA, Нукус → UZ-QR, Фергана → UZ-FA).
//

import CoreLocation
import CryptoKit
import XCTest
@testable import RadarMap

final class RegionCatalogTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func testCellMatchesServer() {
        XCTAssertTrue(RegionCatalog.cell(of: point(41.3111, 69.2797), zoom: 12) == (2836, 1530))
        XCTAssertTrue(RegionCatalog.cell(of: point(39.6542, 66.9597), zoom: 12) == (2809, 1555))
        XCTAssertTrue(RegionCatalog.cell(of: point(42.46, 59.61), zoom: 12) == (2726, 1513))
        XCTAssertTrue(RegionCatalog.cell(of: point(40.3864, 71.7843), zoom: 12) == (2864, 1544))
    }

    private let payload = """
    {"cellZoom":12,"version":7,"regions":[
     {"id":"UZ-TK","name":{"ru":"Ташкент","uz":"Toshkent"},"bbox":[69.1,41.2,69.4,41.4],"cells":3,
      "rows":[[1530,2835,2837]],
      "files":{"mvt":{"file":"UZ-TK.mvt.pmtiles","bytes":100,"sha256":"aa","tiles":1},
               "omt":{"file":"UZ-TK.omt.pmtiles","bytes":50,"sha256":"bb","tiles":1}}},
     {"id":"UZ-SA","name":{"ru":"Самаркандская область"},"bbox":[66,39,68,40],"cells":1,
      "rows":[[1555,2809,2809]],
      "files":{"mvt":{"file":"UZ-SA.mvt.pmtiles","bytes":10,"sha256":"cc","tiles":1}}}]}
    """

    private func catalog() throws -> RegionCatalog {
        try JSONDecoder().decode(RegionCatalog.self, from: Data(payload.utf8))
    }

    func testDecodesServerPayloadAndFindsRegion() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.version, 7)
        XCTAssertEqual(catalog.region(containing: point(41.3111, 69.2797))?.id, "UZ-TK")
        XCTAssertEqual(catalog.region(containing: point(39.6542, 66.9597))?.id, "UZ-SA")
        XCTAssertNil(catalog.region(containing: point(43.2, 76.9)), "Алматы — не наша страна")
        XCTAssertEqual(catalog.totalBytes, 160)
    }

    func testTitleFollowsLanguage() throws {
        let catalog = try catalog()
        let tashkent = try XCTUnwrap(catalog.regions.first { $0.id == "UZ-TK" })
        XCTAssertEqual(tashkent.title(language: "uz"), "Toshkent")
        XCTAssertEqual(tashkent.title(language: "ru"), "Ташкент")
        let samarkand = try XCTUnwrap(catalog.regions.first { $0.id == "UZ-SA" })
        XCTAssertEqual(samarkand.title(language: "uz"), "Самаркандская область", "нет перевода — берём русское")
    }

    func testUnsignedCatalogIsRejected() throws {
        let data = Data(payload.utf8)
        let unsigned = try JSONEncoder().encode(
            SignedPayload<RegionCatalog>(payload: data.base64EncodedString(), sig: nil))
        XCTAssertNil(OfflineMapService.verify(unsigned), "неподписанный каталог не скачивает ни байта")
        let stranger = Curve25519.Signing.PrivateKey()
        let foreign = try JSONEncoder().encode(SignedPayload<RegionCatalog>(
            payload: data.base64EncodedString(),
            sig: try stranger.signature(for: data).base64EncodedString()))
        XCTAssertNil(OfflineMapService.verify(foreign))
    }

    func testFileDigestIsStreamedCorrectly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let streamed = try await OfflineMapService.sha256(of: url)
        XCTAssertEqual(streamed, expected, "sha по кускам = sha целиком")
    }
}
