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
        // Версия из будущего. Двойка была здесь, пока не существовала: теперь
        // это рабочий формат, и брать её примером «неизвестного» нельзя.
        XCTAssertNil(RoadTiles.decodeTile(
            try! JSONSerialization.data(withJSONObject: ["version": 9, "roads": []])))
        // Нечётное число координат — битая дорога валит весь тайл.
        XCTAssertNil(RoadTiles.decodeTile(tileData([[3, 0, [4_131_000, 6_925_000, 100]]])))
        // Как и пустая.
        XCTAssertNil(RoadTiles.decodeTile(tileData([[3, 0, [Int]()]])))
    }

    /// Огрызок из одной точки (сервер выбросил нулевую дельту) — пропуск
    /// записи, а не тайла: тайл улиц центра Ташкента терял из-за пяти таких
    /// все 3 658 дорог (прогон 20.10).
    func testOnePointStubIsSkippedNotTheTile() {
        let lines = RoadTiles.decodeTile(tileData([
            [3, 0, [4_130_000, 6_925_000, 50, 0]],
            [4, 297, [4_130_100, 6_925_100]],
            [6, 32, [4_130_200, 6_925_200, 0, 50], "Бешагач улица"],
        ]))
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?.map(\.kind), [.primary, .residential])
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

    func testSameEndsDifferentRoadsAreBothKept() {
        // Мост над одноимённым участком: те же крайние точки, другой класс.
        // Ключ схлопывания обязан различать их — иначе «оптимизация» ключа до
        // пары координат молча стирает со схемы настоящие дороги. Тест стоит
        // здесь именно как забор от такой оптимизации.
        let ground = line(latitude: 41.31, kind: .secondary)
        let bridge = line(latitude: 41.31, kind: .motorway)
        let network = TileRoadNetwork.build([[ground, bridge]])
        XCTAssertEqual(network.lines.count, 2,
                       "разные дороги с общими концами схлопывать нельзя")
    }

    /// Код класса для ключей постоянен и у всех классов разный — до 19.10
    /// ключ брал hashValue (новый на каждый запуск), и тест выше падал раз в
    /// пару сотен прогонов.
    func testRoadClassCodesAreStableAndDistinct() {
        let all: [RoadClass] = [.motorway, .trunk, .primary, .secondary, .tertiary,
                                .residential, .service, .pedestrian, .unknown]
        XCTAssertEqual(Set(all.map(\.stableCode)).count, all.count)
        XCTAssertEqual(RoadClass.motorway.stableCode, 1)
    }

    func testSameEndsDifferentPointCountAreBothKept() {
        // Второй различающий признак ключа: число точек. Развязка и прямой
        // съезд между теми же узлами — разная геометрия при одинаковых концах.
        var detailed = line(latitude: 41.31)
        detailed.points.insert(CLLocationCoordinate2D(latitude: 41.3105,
                                                      longitude: 69.2512),
                               at: 1)
        let network = TileRoadNetwork.build([[line(latitude: 41.31), detailed]])
        XCTAssertEqual(network.lines.count, 2)
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

    // MARK: - Формат v2: генерализация уехала на сервер

    /// Байты взяты из настоящего выхода build_roads.py, а не написаны рукой:
    /// это контракт с сервером, и проверять его надо тем, что сервер реально
    /// пишет.
    private let goldenStreets = """
    {"version":2,"roads":[[3,0,[4130000,6925000,50,0,50,0,50,0,50,0,50,0,50,0]],    [6,0,[4130150,6925000,0,-50,0,-50,0,-50,0,-50]]]}
    """

    func testV2TileDecodes() {
        let lines = RoadTiles.decodeTile(Data(goldenStreets.utf8))
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?.first?.kind, .primary)
        XCTAssertEqual(lines?.first?.points.count, 7)
        XCTAssertEqual(lines?.first?.points.first?.latitude ?? 0, 41.3, accuracy: 1e-6)
        XCTAssertEqual(lines?.last?.kind, .residential)
    }

    func testV1TileStillDecodes() {
        // Сервер публикует оба формата, пока в проде есть сборки, знающие
        // только старый. Перестать читать v1 — значит оставить их без дорог.
        let v1 = #"{"version":1,"roads":[[3,0,[4130000,6925000,50,0]]]}"#
        XCTAssertEqual(RoadTiles.decodeTile(Data(v1.utf8))?.count, 1)
    }

    func testUnknownVersionIsRefused() {
        // Не «нарисуем что разобрали»: дрейф формата — повод не рисовать
        // ничего, а не рисовать наполовину.
        let future = #"{"version":9,"roads":[[3,0,[4130000,6925000,50,0]]]}"#
        XCTAssertNil(RoadTiles.decodeTile(Data(future.utf8)))
    }

    func testFileNamesMatchWhatServerWrites() {
        XCTAssertEqual(RoadTiles.fileName(key: "262_498", version: 1), "tile_262_498.json")
        XCTAssertEqual(RoadTiles.fileName(key: "2626_4985_s", version: 2),
                       "road2_2626_4985_s.json")
    }

    func testSetKeyIsComposite() {
        XCTAssertEqual(RoadTiles.setKey("2626_4985", .yards), "2626_4985_y")
        XCTAssertEqual(RoadTiles.setKey("2626_4985", .far), "2626_4985_f")
    }

    // MARK: - Устаревший индекс

    /// Тайл не сошёлся по sha — первый раз индекс перепроверяется сразу:
    /// набор перевыложен, а ждать плановой проверки — дни пустой схемы.
    func testStaleTileRechecksIndexAtOnce() {
        XCTAssertTrue(RoadNetworkService.shouldRecheckIndex(lastCheck: nil, now: Date()))
    }

    /// Но не на каждом тике: подменённый на сервере тайл свежий индекс не
    /// оправдает, и без паузы он превращал бы приборку в поток запросов.
    func testStaleTileRecheckIsThrottled() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let interval = AppConfig.roadsStaleIndexRecheck
        XCTAssertFalse(RoadNetworkService.shouldRecheckIndex(
            lastCheck: now.addingTimeInterval(-interval + 1), now: now))
        XCTAssertTrue(RoadNetworkService.shouldRecheckIndex(
            lastCheck: now.addingTimeInterval(-interval), now: now))
        XCTAssertGreaterThan(interval, 0, "нулевая пауза — запрос индекса на каждый тайл")
    }

    // MARK: - Имя улицы и кольца (из SketchAreaTests, 19.10)

    func testNameArrivesFromTheFourthElement() {
        // Четвёртый элемент необязателен: имя есть у одной дороги из семи.
        let tile = #"{"version":2,"roads":[[3,0,[4130000,6925000,100,0],"Амира Темура"],[3,0,[4130500,6925000,100,0]]]}"#
        let lines = RoadTiles.decodeTile(Data(tile.utf8))
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?.first?.name, "Амира Темура")
        XCTAssertEqual(lines?.last?.name, "", "нет имени — не «безымянная», а «не знаем»")
    }

    func testRingIsNeverDrawnAsOneWay() {
        // Бит кольца снимает одностороннесть: стрелки по кругу читаются как
        // ошибка рендера, а не как направление.
        let tile = #"{"version":2,"roads":[[3,9,[4130000,6925000,100,0,0,100,-100,0]]]}"#
        let line = RoadTiles.decodeTile(Data(tile.utf8))?.first
        XCTAssertEqual(line?.isRing, true)
        XCTAssertEqual(line?.isOneWay, false)
    }
}
