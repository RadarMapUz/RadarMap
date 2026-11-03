//
//  CameraOverrideTests.swift
//  RadarMapTests
//
//  Правки модератора — единственный внешний вход, способный СКРЫТЬ камеру,
//  то есть произвести молчание там, где камера стоит. Поэтому проверяем в
//  первую очередь предохранители, а уже потом полезное действие.
//

import CryptoKit
import XCTest
@testable import RadarMap

final class CameraOverrideTests: XCTestCase {

    private func camera(id: Int, lat: Double = 41.31, lon: Double = 69.25,
                        type: String = "Стационар камера") -> Camera {
        Camera(id: id, region: "Ташкент", city: "Ташкент", location: "Тест",
               lat: lat, lon: lon, type: type,
               violations: Camera.defaultViolations(forType: type), needsReview: nil,
               axis: 90, dir: 90, lanes: 2, cls: "primary",
               road: [0, 0, 100, 100], split: false, twin: true)
    }

    private func overrides(_ items: [CameraOverride]) -> CameraOverrides {
        CameraOverrides(version: 1, updatedAt: "2026-08-06", items: items)
    }

    // MARK: - Полезное действие

    func testHideRemovesCameraFromList() {
        let base = [camera(id: 1), camera(id: 2), camera(id: 3)]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 2, op: .hide)]), to: base)
        XCTAssertEqual(result.cameras.map(\.id), [1, 3])
        XCTAssertEqual(result.hidden, 1)
    }

    func testMoveUpdatesCoordinate() {
        let base = [camera(id: 1, lat: 41.31, lon: 69.25)]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .move, lat: 41.3110, lon: 69.2510)]), to: base)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.cameras.first?.lat ?? 0, 41.3110, accuracy: 1e-6)
        XCTAssertEqual(result.cameras.first?.lon ?? 0, 69.2510, accuracy: 1e-6)
    }

    func testMoveDropsRoadProfileMeasuredAtOldPoint() throws {
        let base = [camera(id: 1)]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .move, lat: 41.3110, lon: 69.2510)]), to: base)
        let moved = try XCTUnwrap(result.cameras.first)
        // road — это дельты ОТ координаты камеры: вместе с ней уехала бы и
        // «проезжая часть», и гейты стали бы глушить по чужой геометрии.
        XCTAssertNil(moved.road, "профиль дороги измерен в другой точке")
        XCTAssertNil(moved.dir)
        XCTAssertNil(moved.axis)
        XCTAssertFalse(moved.allowsDirectionGate,
                       "сдвинутая камера обязана предупреждать чаще, а не реже")
    }

    func testRetypeRebuildsViolations() {
        let base = [camera(id: 1, type: "Стационар камера")]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .retype, type: "Стационар радар")]), to: base)
        XCTAssertEqual(result.retyped, 1)
        XCTAssertEqual(result.cameras.first?.type, "Стационар радар")
        XCTAssertEqual(result.cameras.first?.violations,
                       Camera.defaultViolations(forType: "Стационар радар"),
                       "нарушения выводятся из типа — иначе радар остался бы со списком камеры")
    }

    func testUntouchedCamerasPassThroughUnchanged() {
        let base = (1...5).map { camera(id: $0) }
        let result = CameraOverrideEngine.apply(overrides([]), to: base)
        XCTAssertEqual(result.cameras, base)
        XCTAssertEqual(result.rejected, 0)
    }

    // MARK: - Предохранители

    func testImplausibleMoveIsRejectedAndCameraSurvives() {
        let base = [camera(id: 1, lat: 41.31, lon: 69.25)]
        // Самарканд вместо Ташкента: перепутанная камера или запятая в координате.
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .move, lat: 39.65, lon: 66.96)]), to: base)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.cameras.first?.lat ?? 0, 41.31, accuracy: 1e-6,
                       "камера должна остаться на месте, а не потеряться")
    }

    func testMoveOutsideUzbekistanIsRejected() {
        let base = [camera(id: 1)]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .move, lat: 55.75, lon: 37.61)]), to: base)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertEqual(result.cameras.count, 1)
    }

    func testIncompleteOverrideIsRejectedNotApplied() {
        let base = [camera(id: 1)]
        for broken in [CameraOverride(id: 1, op: .move, lat: 41.311, lon: nil),
                       CameraOverride(id: 1, op: .retype, type: "")] {
            let result = CameraOverrideEngine.apply(overrides([broken]), to: base)
            XCTAssertEqual(result.rejected, 1, "неполная правка не должна применяться")
            XCTAssertEqual(result.cameras.count, 1)
        }
    }

    func testMassHideIsRefusedWholesale() {
        let base = (1...1000).map { camera(id: $0) }
        let tooMany = overrides((1...100).map { .init(id: $0, op: .hide) })
        XCTAssertFalse(CameraOverrideEngine.isSane(tooMany, baseCount: base.count),
                       "файл, гасящий 10% базы, вероятнее опечатка в SQL, чем решение")

        let reasonable = overrides((1...20).map { .init(id: $0, op: .hide) })
        XCTAssertTrue(CameraOverrideEngine.isSane(reasonable, baseCount: base.count))
    }

    func testMassMoveIsRefusedWholesale() {
        let base = (1...1000).map { camera(id: $0) }
        // Сто переносов на соседнюю улицу — сто камер, молчащих на своих местах.
        let manyMoves = overrides((1...100).map {
            .init(id: $0, op: .move, lat: 41.3101, lon: 69.2501)
        })
        XCTAssertFalse(CameraOverrideEngine.isSane(manyMoves, baseCount: base.count),
                       "массовый перенос гасит камеры так же, как скрытие")
        let result = CameraOverrideEngine.apply(manyMoves, to: base)
        XCTAssertEqual(result.moved, 100, "предохранитель — в isSane, а не в apply: файл отвергается до применения")

        let fewMoves = overrides((1...30).map {
            .init(id: $0, op: .move, lat: 41.3101, lon: 69.2501)
        })
        XCTAssertTrue(CameraOverrideEngine.isSane(fewMoves, baseCount: base.count))
    }

    func testMovesHaveTheirOwnLimitBelowTheShare() {
        let base = (1...1000).map { camera(id: $0) }
        // 40 переносов — меньше общей доли (50), но больше предела переносов (30).
        let moves = overrides((1...40).map {
            .init(id: $0, op: .move, lat: 41.3101, lon: 69.2501)
        })
        XCTAssertFalse(CameraOverrideEngine.isSane(moves, baseCount: base.count))
    }

    func testHidesAndMovesShareOneLimit() {
        let base = (1...1000).map { camera(id: $0) }
        // По отдельности каждое в норме, вместе — 60 молчащих камер из 1000 (> 5 %).
        let items: [CameraOverride] = (1...30).map { .init(id: $0, op: .hide) }
            + (31...60).map { .init(id: $0, op: .move, lat: 41.3101, lon: 69.2501) }
        XCTAssertFalse(CameraOverrideEngine.isSane(overrides(items), baseCount: base.count))

        let within: [CameraOverride] = (1...25).map { .init(id: $0, op: .hide) }
            + (26...50).map { .init(id: $0, op: .move, lat: 41.3101, lon: 69.2501) }
        XCTAssertTrue(CameraOverrideEngine.isSane(overrides(within), baseCount: base.count))
    }

    func testRetypesDoNotCountTowardTheSilenceLimit() {
        let base = (1...100).map { camera(id: $0) }
        // Смена типа камеру не гасит: оповещение остаётся (молчит только у тех,
        // кто сам отфильтровал этот тип в настройках).
        let retypes = overrides((1...60).map { .init(id: $0, op: .retype, type: "Стационар радар") })
        XCTAssertTrue(CameraOverrideEngine.isSane(retypes, baseCount: base.count))
    }

    func testCanonicalPublishedPayloadDecodes() throws {
        // Ровно эти байты пишет overrides_diff.canonical (CANONICAL_SAMPLE в
        // server/test_overrides_diff.py) — их подписывает publish_overrides.sh.
        let sample = #"{"version":3,"updatedAt":"2026-11-03","items":[{"id":1,"op":"hide"},"#
            + #"{"id":2,"op":"move","lat":41.3001,"lon":69.2},"#
            + #"{"id":3,"op":"retype","type":"Стационар радар"}]}"#
        let decoded = try JSONDecoder().decode(CameraOverrides.self, from: Data(sample.utf8))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.updatedAt, "2026-11-03")
        XCTAssertEqual(decoded.items, [
            CameraOverride(id: 1, op: .hide),
            CameraOverride(id: 2, op: .move, lat: 41.3001, lon: 69.2),
            CameraOverride(id: 3, op: .retype, type: "Стационар радар"),
        ])
    }

    func testEmptyBaseIsNeverSane() {
        XCTAssertFalse(CameraOverrideEngine.isSane(overrides([.init(id: 1, op: .hide)]),
                                                   baseCount: 0),
                       "база ещё не загрузилась — применять правки не к чему")
    }

    func testLastOverrideWinsForSameCamera() {
        let base = [camera(id: 1)]
        let result = CameraOverrideEngine.apply(
            overrides([.init(id: 1, op: .hide),
                       .init(id: 1, op: .retype, type: "Стационар радар")]), to: base)
        XCTAssertEqual(result.hidden, 0, "две противоречивые правки не применяются обе")
        XCTAssertEqual(result.retyped, 1)
    }

    // MARK: - Подпись

    func testSignedOverridesRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let value = overrides([.init(id: 42, op: .hide)])
        let payload = try JSONEncoder().encode(value)
        let envelope = CameraOverridesEnvelope(
            payload: payload.base64EncodedString(),
            sig: try key.signature(for: payload).base64EncodedString())
        XCTAssertEqual(
            envelope.verified(publicKeyB64: key.publicKey.rawRepresentation.base64EncodedString()),
            value)
    }

    func testUnsignedOverridesAreRejected() throws {
        let payload = try JSONEncoder().encode(overrides([.init(id: 42, op: .hide)]))
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        XCTAssertNil(
            CameraOverridesEnvelope(payload: payload.base64EncodedString(), sig: nil)
                .verified(publicKeyB64: key),
            "неподписанный файл умеет гасить камеры — верить ему нельзя никогда")
    }
}
