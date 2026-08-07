//
//  RoadTilesTests.swift
//  RadarMapTests
//
//  Дорожные тайлы: контракт формата с server/build_roads.py, целостность
//  (подписанный индекс + sha256 тайлов, fail closed) и сеточный индекс.
//  Большинство тестов — про то, что НЕ должно случиться: подделанный индекс
//  принят, битый тайл нарисован, дубль с границы тайлов посчитан дважды.
//

import CoreLocation
import CryptoKit
import XCTest
@testable import RadarMap

final class RoadTilesTests: XCTestCase {

    // MARK: - Формат тайла

    /// Тайл, каким его пишет build_roads.py: дельты в 1e-5°, flags битами.
    private func tileData(_ roads: [[Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "roads": roads])
    }

    func testDecodeAccumulatesDeltas() throws {
        // Первая точка абсолютная, дальше дельты — как у сервера.
        let data = tileData([[3, 0, [4_131_000, 6_925_000, 100, 0, 100, 200]]])
        let lines = try XCTUnwrap(RoadTiles.decodeTile(data))
        XCTAssertEqual(lines.count, 1)
        let points = lines[0].points
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].latitude, 41.31, accuracy: 1e-9)
        XCTAssertEqual(points[0].longitude, 69.25, accuracy: 1e-9)
        XCTAssertEqual(points[1].latitude, 41.311, accuracy: 1e-9)
        XCTAssertEqual(points[2].longitude, 69.252, accuracy: 1e-9)
        XCTAssertEqual(lines[0].kind, .primary)
        XCTAssertTrue(lines[0].isDetailed, "тайлы знают класс по-настоящему")
    }

    func testFlagsBecomeLevelAndOneWay() throws {
        let data = tileData([
            [1, 3, [4_131_000, 6_925_000, 100, 0]],   // oneway | мост
            [2, 4, [4_132_000, 6_925_000, 100, 0]],   // тоннель
            [6, 0, [4_133_000, 6_925_000, 100, 0]],   // обычная
        ])
        let lines = try XCTUnwrap(RoadTiles.decodeTile(data))
        XCTAssertEqual(lines[0].level, 1, "мост — над землёй")
        XCTAssertTrue(lines[0].isOneWay)
        XCTAssertEqual(lines[1].level, -1, "тоннель — под землёй")
        XCTAssertEqual(lines[2].level, 0)
        XCTAssertFalse(lines[2].isOneWay)
    }

    func testClassCodesMapLikeServer() {
        // Коды — контракт с CLASS_CODES в build_roads.py.
        XCTAssertEqual(RoadTiles.roadClass(code: 1), .motorway)
        XCTAssertEqual(RoadTiles.roadClass(code: 4), .secondary)
        XCTAssertEqual(RoadTiles.roadClass(code: 7), .service)
        XCTAssertEqual(RoadTiles.roadClass(code: 99), .unknown,
                       "незнакомый код будущего формата — не падение, а «без обещаний»")
    }

    func testMalformedTileIsRejectedWholesale() {
        // sha сошёлся, а формат нет — это дрейф формата, и правильный ответ:
        // не рисовать ничего, а не рисовать наполовину разобранное.
        XCTAssertNil(RoadTiles.decodeTile(Data("мусор".utf8)))
        XCTAssertNil(RoadTiles.decodeTile(
            try! JSONSerialization.data(withJSONObject: ["version": 2, "roads": []])))
        // Нечётное число координат — битая дорога валит весь тайл.
        XCTAssertNil(RoadTiles.decodeTile(tileData([[3, 0, [4_131_000, 6_925_000, 100]]])))
    }

    // MARK: - Ключи тайлов

    func testTileKeyMatchesServerFormula() {
        // Та же точка считается в server/test_build_roads.py: "262_498".
        XCTAssertEqual(RoadTiles.tileKey(latitude: 41.31, longitude: 69.25,
                                         tileDegrees: 0.5), "262_498")
    }

    func testNeighborhoodIsNineTiles() {
        let keys = RoadTiles.neighborhood(
            of: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.25),
            tileDegrees: 0.5)
        XCTAssertEqual(Set(keys).count, 9)
        XCTAssertTrue(keys.contains("262_498"))
    }

    // MARK: - Целостность (fail closed)

    private func envelope(_ payload: Data,
                          key: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: payload)
        let json = ["payload": payload.base64EncodedString(),
                    "sig": signature.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testSignedIndexRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"version":1,"tileDegrees":0.5,"tiles":{"262_498":{"sha256":"ab","bytes":2}}}"#.utf8)
        let data = try envelope(payload, key: key)
        let parsed = try JSONDecoder().decode(SignedPayload<RoadTiles.Index>.self,
                                              from: data)
        let index = parsed.verified(
            publicKeyB64: key.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(index?.tiles["262_498"]?.sha256, "ab")
    }

    func testTamperedIndexIsRejected() throws {
        // Подпись от чужого ключа (= подменённый индекс) не проходит: без
        // валидного индекса не скачивается ни один тайл — fail closed.
        let stranger = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"version":1,"tileDegrees":0.5,"tiles":{}}"#.utf8)
        let data = try envelope(payload, key: stranger)
        let parsed = try JSONDecoder().decode(SignedPayload<RoadTiles.Index>.self,
                                              from: data)
        let honest = Curve25519.Signing.PrivateKey()
        XCTAssertNil(parsed.verified(
            publicKeyB64: honest.publicKey.rawRepresentation.base64EncodedString()))
    }

    func testShaMatchesKnownVector() {
        // sha256("radar") — проверка, что хэшируются РОВНО байты файла.
        XCTAssertEqual(RoadTiles.sha256Hex(of: Data("radar".utf8)),
                       "ff2e963ff6d0c33aae94a7f823b6e2bf7358004063f4275ba525539cb6ec6734")
    }

    // MARK: - Сеточный индекс и дубли с границ

    private func line(latitude: Double, kind: RoadClass = .secondary) -> RoadLine {
        let points = stride(from: 0.0, through: 300, by: 50).map {
            CLLocationCoordinate2D(latitude: latitude,
                                   longitude: 69.25 + $0 / 84_000)
        }
        return RoadLine(points: points, kind: kind, isDetailed: true)
    }

    func testGridFindsNearbyAndTrimsFar() {
        let network = TileRoadNetwork.build([[line(latitude: 41.31)]])
        let near = network.roads(near: .init(latitude: 41.3101, longitude: 69.2515),
                                 radius: 200)
        XCTAssertEqual(near.count, 1)
        XCTAssertGreaterThanOrEqual(near[0].points.count, 2)

        let far = network.roads(near: .init(latitude: 41.10, longitude: 69.25),
                                radius: 300)
        XCTAssertTrue(far.isEmpty, "за радиусом дорог нет — и не выдумываем")
    }

    func testBorderDuplicateCollapses() {
        // Одна и та же дорога из двух соседних тайлов (сервер кладёт её в оба
        // целиком) — в снимке обязана остаться одной, иначе граница тайлов
        // съедала бы бюджет линий дважды.
        let duplicated = line(latitude: 41.31)
        let network = TileRoadNetwork.build([[duplicated], [duplicated]])
        XCTAssertEqual(network.lines.count, 1)
    }

    func testFallbackUsedOnlyWhereNoCoverage() {
        struct Fixed: RoadNetworkSource {
            var lines: [RoadLine]
            func roads(near coordinate: CLLocationCoordinate2D,
                       radius: CLLocationDistance) -> [RoadLine] { lines }
        }
        let detailed = [RoadLine(points: [], kind: .primary, isDetailed: true)]
        let fallback = [RoadLine(points: [])]

        let covered = FallbackRoadNetwork(primary: Fixed(lines: detailed),
                                          fallback: Fixed(lines: fallback))
        XCTAssertEqual(covered.roads(near: .init(), radius: 100).first?.kind, .primary,
                       "есть тайлы — рисуем тайлы")

        let empty = FallbackRoadNetwork(primary: Fixed(lines: []),
                                        fallback: Fixed(lines: fallback))
        XCTAssertEqual(empty.roads(near: .init(), radius: 100).count, 1,
                       "нет покрытия — честный фолбэк на индекс лимитов, не пустота")
    }
}
