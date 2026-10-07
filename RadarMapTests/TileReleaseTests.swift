//
//  TileReleaseTests.swift
//  RadarMapTests
//
//  Выпуск тайлов по версии и новая карта. Две вещи сразу: телефон и сервер
//  (server/tile_buckets.py) режут индекс на корзины ОДИНАКОВО — иначе тайл
//  искался бы не в той корзине и карта была бы пустой, — и охрана не
//  ослабла: тайл чужого выпуска или неподписанный корень не проходят.
//

import CryptoKit
import XCTest
@testable import RadarMap

final class TileReleaseTests: XCTestCase {

    private let base = URL(string: "https://soulmed.uz/radarmap")!

    /// Ровно в том виде, в каком корень пишет server/tile_buckets.py.
    private let payload = """
    {"bucketZoom":10,"sets":{"mvt":{"buckets":{"708_382":"aa","low":"bb"},"ext":"mvt","path":"mvt","tiles":2},\
    "omt":{"buckets":{"708_382":"cc","low":"dd"},"ext":"pbf","path":"omt","tiles":2}},"version":2610071018}
    """

    private func release() throws -> TileRelease {
        try JSONDecoder().decode(TileRelease.self, from: Data(payload.utf8))
    }

    // MARK: - Контракт с сервером

    func testDecodesServerPayload() throws {
        let release = try release()
        XCTAssertEqual(release.version, 2610071018)
        XCTAssertEqual(release.bucketZoom, 10)
        XCTAssertEqual(release.sets["omt"]?.ext, "pbf")
    }

    func testBucketNamesMatchServer() {
        // Те же значения, что в test_tile_buckets.py.
        XCTAssertEqual(TileRelease.bucket(z: 15, x: 22686, y: 12246, bucketZoom: 10), "708_382")
        XCTAssertEqual(TileRelease.bucket(z: 11, x: 1417, y: 765, bucketZoom: 10), "708_382")
        XCTAssertEqual(TileRelease.bucket(z: 10, x: 708, y: 382, bucketZoom: 10), "708_382")
        XCTAssertEqual(TileRelease.bucket(z: 9, x: 354, y: 191, bucketZoom: 10), "low")
        XCTAssertEqual(TileRelease.bucket(z: 0, x: 0, y: 0, bucketZoom: 10), "low")
    }

    // MARK: - Адреса

    func testParsesReleaseTileURL() throws {
        let url = URL(string: "https://soulmed.uz/radarmap/v/2610071018/mvt/15/22686/12246.mvt")!
        let tile = try XCTUnwrap(TileRelease.parse(url))
        XCTAssertEqual(tile, TileRelease.Tile(version: 2610071018, set: "mvt", z: 15, x: 22686, y: 12246))
        XCTAssertEqual(tile.key, "15/22686/12246")
        XCTAssertEqual(try release().tile(at: url), tile)
    }

    func testLegacyAndForeignURLsAreNotReleaseTiles() throws {
        XCTAssertNil(TileRelease.parse(URL(string: "https://soulmed.uz/radarmap/mvt/15/22686/12246.mvt")!))
        XCTAssertNil(TileRelease.parse(URL(string: "https://soulmed.uz/radarmap/v/1/idx/mvt/708_382.bin")!))
        XCTAssertNil(TileRelease.parse(URL(string: "https://soulmed.uz/radarmap/v/1/mvt/2/9/0.mvt")!),
                     "координата вне сетки зума")
    }

    func testTileOfAnotherReleaseIsRefused() throws {
        // Старый адрес после смены выпуска — не наш тайл: его корзины нет в корне.
        let url = URL(string: "https://soulmed.uz/radarmap/v/1/mvt/15/22686/12246.mvt")!
        XCTAssertNotNil(TileRelease.parse(url))
        XCTAssertNil(try release().tile(at: url))
        let wrongExt = URL(string: "https://soulmed.uz/radarmap/v/2610071018/omt/14/1/1.mvt")!
        XCTAssertNil(try release().tile(at: wrongExt), "расширение задаёт набор")
    }

    func testBucketDigestAndURLs() throws {
        let release = try release()
        let tile = TileRelease.Tile(version: release.version, set: "omt", z: 14, x: 11343, y: 6123)
        let bucket = try XCTUnwrap(release.bucketDigest(for: tile))
        XCTAssertEqual(bucket.name, "708_382")
        XCTAssertEqual(bucket.sha256, "cc")
        XCTAssertEqual(release.bucketURL(base: base, set: "omt", name: bucket.name).absoluteString,
                       "https://soulmed.uz/radarmap/v/2610071018/idx/omt/708_382.bin")
        XCTAssertEqual(release.tilesTemplate(base: base, set: "mvt"),
                       "https://soulmed.uz/radarmap/v/2610071018/mvt/{z}/{x}/{y}.mvt")
        let empty = TileRelease.Tile(version: release.version, set: "omt", z: 14, x: 0, y: 0)
        XCTAssertNil(release.bucketDigest(for: empty), "клетки нет в корне — тайла нет вовсе")
    }

    // MARK: - Корзина

    func testBucketIsAcceptedOnlyWithItsDigest() {
        let index = TileDigestIndex(version: 1, tiles: ["15/1/1": String(repeating: "ab", count: 32)])
        let data = index.serialized()
        let digest = TileReleaseStore.hex(SHA256.hash(data: data))
        XCTAssertNotNil(TileReleaseStore.parse(data, digest: digest))
        XCTAssertNotNil(TileReleaseStore.parse(data, digest: digest.uppercased()))
        XCTAssertNil(TileReleaseStore.parse(data, digest: String(repeating: "0", count: 64)),
                     "подменённая корзина не принимается")
    }

    // MARK: - Подпись корня

    func testRootSignedByOwnerIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data(payload.utf8)
        let envelope = SignedPayload<TileRelease>(payload: data.base64EncodedString(),
                                                  sig: try key.signature(for: data).base64EncodedString())
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(envelope.verified(publicKeyB64: publicKey)?.version, 2610071018)
    }

    func testUnsignedOrForeignRootIsRejected() throws {
        let data = Data(payload.utf8)
        XCTAssertNil(TileReleaseStore.verify(try JSONEncoder().encode(
            SignedPayload<TileRelease>(payload: data.base64EncodedString(), sig: nil))))
        let stranger = Curve25519.Signing.PrivateKey()
        XCTAssertNil(TileReleaseStore.verify(try JSONEncoder().encode(
            SignedPayload<TileRelease>(payload: data.base64EncodedString(),
                                       sig: try stranger.signature(for: data).base64EncodedString()))),
                     "корень, подписанный не владельцем, не открывает ни одного тайла")
    }

    // MARK: - Сторож

    #if canImport(MapLibre)
    func testGuardFetchesWholeTileEvenOnRevalidation() {
        // Движок переспрашивает протухший тайл с If-None-Match; 304 без тела
        // сторожу нечем проверить — тайл объявлялся неподписанным.
        var request = URLRequest(url: URL(string: "https://soulmed.uz/radarmap/v/1/mvt/15/1/1.mvt")!)
        request.setValue("\"abc\"", forHTTPHeaderField: "If-None-Match")
        request.setValue("Tue, 07 Oct 2026 10:00:00 GMT", forHTTPHeaderField: "If-Modified-Since")
        let own = EngineTileGuard.guardRequest(from: request)
        XCTAssertNil(own.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(own.value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertNotNil(own.value(forHTTPHeaderField: "X-RadarMap-Tile-Guard"))
    }
    #endif

    // MARK: - Новая карта

    private func modernStyle(daylight: Bool, houses: Bool = true) throws -> [String: Any] {
        let json = try XCTUnwrap(EngineModernStyle.json(daylight: daylight, base: base,
                                                        release: try release(), houses: houses))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testModernStyleIsBundledForBothThemes() throws {
        for daylight in [true, false] {
            let style = try modernStyle(daylight: daylight)
            let text = String(data: try JSONSerialization.data(withJSONObject: style), encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("{{"), "плейсхолдер остался в стиле")
            XCTAssertNil(style["center"], "камеру ставит приложение, а не стиль")
        }
    }

    func testModernStyleTilesComeFromTheSignedRelease() throws {
        let sources = try XCTUnwrap(try modernStyle(daylight: true)["sources"] as? [String: Any])
        let omt = try XCTUnwrap(sources["openmaptiles"] as? [String: Any])
        let mvt = try XCTUnwrap(sources["radar"] as? [String: Any])
        XCTAssertEqual(omt["tiles"] as? [String], ["https://soulmed.uz/radarmap/v/2610071018/omt/{z}/{x}/{y}.pbf"])
        XCTAssertEqual(mvt["tiles"] as? [String], ["https://soulmed.uz/radarmap/v/2610071018/mvt/{z}/{x}/{y}.mvt"])
        for name in EngineModernStyle.liveSources { XCTAssertNotNil(sources[name], name) }
    }

    func testRouteUnderLabelsAndMarkersOnTop() throws {
        let layers = try XCTUnwrap(try modernStyle(daylight: true)["layers"] as? [[String: Any]])
        let ids = layers.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids).count, ids.count, "id слоёв уникальны")
        let route = try XCTUnwrap(ids.firstIndex(of: "route"))
        let firstLabel = try XCTUnwrap(layers.firstIndex {
            $0["type"] as? String == "symbol" && $0["source"] as? String == "openmaptiles"
        })
        XCTAssertLessThan(route, firstLabel, "маршрут под подписями основы")
        XCTAssertEqual(ids.last, "user-location", "«я» — над всем")
        XCTAssertTrue(ids.contains("camera-icons"))
    }

    func testHousesSwitchRemovesBuildingLayers() throws {
        let with = try XCTUnwrap(try modernStyle(daylight: true, houses: true)["layers"] as? [[String: Any]])
        let without = try XCTUnwrap(try modernStyle(daylight: true, houses: false)["layers"] as? [[String: Any]])
        XCTAssertTrue(with.contains { $0["source-layer"] as? String == "building" })
        XCTAssertFalse(without.contains { $0["source-layer"] as? String == "building" })
    }

    func testReleaseWithoutNeededSetFallsBack() throws {
        let partial = try JSONDecoder().decode(TileRelease.self, from: Data("""
        {"bucketZoom":10,"sets":{"mvt":{"buckets":{},"ext":"mvt","path":"mvt"}},"version":1}
        """.utf8))
        XCTAssertNil(EngineModernStyle.json(daylight: true, base: base, release: partial, houses: true),
                     "без основы в выпуске — остаёмся на прежнем стиле")
    }
}
