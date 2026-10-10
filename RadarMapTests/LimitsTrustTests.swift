//
//  LimitsTrustTests.swift
//  RadarMapTests
//
//  Подписанные лимиты скорости: таблица храповика, проверка индекса и файла,
//  чтение кэша с диска. Большинство тестов — про то, что НЕ должно случиться:
//  подменённый файл принят, срезанный индекс вернул телефон на неподписанные
//  данные, кэш на диске прочитан без подписи после храповика.
//
//  Подписи — от одноразовых ключей теста (как в RoadTilesTests): настоящий
//  ключ владельца живёт только на его машине.
//

import CryptoKit
import XCTest
@testable import RadarMap

final class LimitsTrustTests: XCTestCase {

    // MARK: - Набор для тестов

    private let key = Curve25519.Signing.PrivateKey()
    private var publicKeyB64: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// Файл лимитов формата 2 — как его пишет extract_speed_limits.py.
    private let limitsData = Data(#"{"version":1759000000,"format":2,"segments":[[60,3,[41.31,69.25,41.312,69.252]]]}"#.utf8)

    private func file(for data: Data, format: Int = 2,
                      name: String? = nil) -> [String: Any] {
        let sha = RoadTiles.sha256Hex(of: data)
        return ["format": format,
                "name": name ?? "limits/speed_limits_v2.\(sha.prefix(16)).json",
                "sha256": sha, "bytes": data.count, "segments": 1]
    }

    private func payload(files: [[String: Any]], format: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": format, "version": 1_759_000_000, "built": 1_760_000_000, "files": files,
        ])
    }

    private func envelope(_ payload: Data,
                          signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let signature = try (signer ?? key).signature(for: payload)
        return try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "sig": signature.base64EncodedString(),
        ])
    }

    private func validIndex() throws -> Data {
        try envelope(payload(files: [file(for: limitsData)]))
    }

    private func manifest() throws -> LimitsManifest {
        try LimitsTrust.verifyIndex(validIndex(), publicKeyB64: publicKeyB64).get()
    }

    // MARK: - Храповик: таблица решений

    func testValidSignedIndexAlwaysWins() throws {
        let manifest = try manifest()
        for ratchet in [false, true] {
            for accept in [false, true] {
                XCTAssertEqual(LimitsTrust.decide(signedIndex: .valid(manifest),
                                                  ratchetSet: ratchet, acceptUnsigned: accept),
                               .useSigned(manifest), "храповик \(ratchet), переход \(accept)")
            }
        }
    }

    func testBeforeRatchetMissingIndexFallsBackToLegacy() {
        // Переход: владелец ещё не подписал — обновление не вправе оставить
        // людей без лимитов.
        XCTAssertEqual(LimitsTrust.decide(signedIndex: .absent, ratchetSet: false,
                                          acceptUnsigned: true), .useLegacy)
    }

    func testAfterRatchetMissingIndexNeverReturnsToLegacy() {
        // Главное: срезать индекс (404) не должно возвращать телефон на
        // неподписанные данные — держим проверенное или живём без лимитов.
        for accept in [false, true] {
            XCTAssertEqual(LimitsTrust.decide(signedIndex: .absent, ratchetSet: true,
                                              acceptUnsigned: accept), .keepVerified)
            XCTAssertEqual(LimitsTrust.decide(signedIndex: .invalid(.signature), ratchetSet: true,
                                              acceptUnsigned: accept), .keepVerified)
            XCTAssertEqual(LimitsTrust.decide(signedIndex: .invalid(.schema("x")), ratchetSet: true,
                                              acceptUnsigned: accept), .keepVerified)
        }
    }

    func testSwitchOffClosesLegacyEvenBeforeRatchet() {
        // AppConfig.speedLimitsAcceptUnsigned = false — владелец опубликовал
        // индекс, и старый путь закрыт и для тех, кто его ещё не застал.
        XCTAssertEqual(LimitsTrust.decide(signedIndex: .absent, ratchetSet: false,
                                          acceptUnsigned: false), .keepVerified)
        XCTAssertFalse(LimitsTrust.allowsLegacy(ratchetSet: false, acceptUnsigned: false))
    }

    func testBrokenIndexBeforeRatchetEqualsMissing() {
        // Испортивший индекс мог бы его и удалить — строгость тут защиты не
        // даёт, а свежие установки при ошибке публикации остались бы без лимитов.
        XCTAssertEqual(LimitsTrust.decide(signedIndex: .invalid(.signature), ratchetSet: false,
                                          acceptUnsigned: true), .useLegacy)
    }

    func testLegacyIndexAllowedOnlyBeforeRatchetWithSwitchOn() {
        XCTAssertTrue(LimitsTrust.allowsLegacy(ratchetSet: false, acceptUnsigned: true))
        XCTAssertFalse(LimitsTrust.allowsLegacy(ratchetSet: true, acceptUnsigned: true))
        XCTAssertFalse(LimitsTrust.allowsLegacy(ratchetSet: true, acceptUnsigned: false))
    }

    // MARK: - Индекс: подпись и схема

    func testValidIndexIsAccepted() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.version, 1_759_000_000)
        XCTAssertEqual(manifest.preferredFile()?.sha256, RoadTiles.sha256Hex(of: limitsData))
        XCTAssertEqual(manifest.preferredFile()?.bytes, limitsData.count)
    }

    func testIndexSignedByStrangerIsRejected() throws {
        let forged = try envelope(payload(files: [file(for: limitsData)]),
                                  signedBy: Curve25519.Signing.PrivateKey())
        XCTAssertEqual(LimitsTrust.indexState(forged, publicKeyB64: publicKeyB64),
                       .invalid(.signature))
    }

    func testIndexEditedAfterSigningIsRejected() throws {
        // Подменили sha в payload, подпись оставили — ровно атака «подсунуть
        // свой файл под чужую подпись».
        let honest = try payload(files: [file(for: limitsData)])
        let signature = try key.signature(for: honest)
        let evil = try payload(files: [file(for: Data(#"{"segments":[[20,3,[1,2,3,4]]]}"#.utf8))])
        let tampered = try JSONSerialization.data(withJSONObject: [
            "payload": evil.base64EncodedString(),
            "sig": signature.base64EncodedString(),
        ])
        XCTAssertEqual(LimitsTrust.indexState(tampered, publicKeyB64: publicKeyB64),
                       .invalid(.signature))
    }

    func testUnsignedIndexIsRejected() throws {
        let unsigned = try JSONSerialization.data(withJSONObject: [
            "payload": payload(files: [file(for: limitsData)]).base64EncodedString(),
        ])
        XCTAssertEqual(LimitsTrust.indexState(unsigned, publicKeyB64: publicKeyB64),
                       .invalid(.signature))
    }

    func testNotAnEnvelopeIsRejected() {
        XCTAssertEqual(LimitsTrust.indexState(Data("<html>502</html>".utf8),
                                              publicKeyB64: publicKeyB64),
                       .invalid(.notEnvelope))
        XCTAssertEqual(LimitsTrust.indexState(nil, publicKeyB64: publicKeyB64), .absent)
    }

    func testSignedButOffContractIsRejectedAsSchema() throws {
        let sha = RoadTiles.sha256Hex(of: limitsData)
        let cases: [(String, Data)] = [
            ("чужой формат индекса", try payload(files: [file(for: limitsData)], format: 2)),
            ("нет понятного формата", try payload(files: [file(for: limitsData, format: 3)])),
            ("имя за пределы вебрута", try payload(files: [file(for: limitsData, name: "../etc/x.json")])),
            ("имя с пустым сегментом", try payload(files: [file(for: limitsData, name: "limits//x.json")])),
            ("заглавный hex", try payload(files: [{
                var entry = file(for: limitsData); entry["sha256"] = sha.uppercased(); return entry
            }()])),
            ("нулевой размер", try payload(files: [{
                var entry = file(for: limitsData); entry["bytes"] = 0; return entry
            }()])),
            ("не JSON индекса", Data("[1,2,3]".utf8)),
        ]
        for (title, body) in cases {
            guard case .invalid(.schema) = LimitsTrust.indexState(try envelope(body),
                                                                    publicKeyB64: publicKeyB64)
            else { return XCTFail("принят индекс: \(title)") }
        }
    }

    func testNewestKnownFormatIsPreferred() throws {
        let legacy = Data(#"{"version":1,"segments":[[60,[41.31,69.25,41.312,69.252]]]}"#.utf8)
        let body = try payload(files: [file(for: legacy, format: 1),
                                       file(for: limitsData, format: 2),
                                       file(for: Data("x".utf8), format: 9)])
        let manifest = try LimitsTrust.verifyIndex(envelope(body), publicKeyB64: publicKeyB64).get()
        XCTAssertEqual(manifest.preferredFile()?.format, 2, "формат 9 не понимаем — не берём")
        XCTAssertEqual(manifest.preferredFile(knownFormats: [1])?.format, 1)
    }

    func testSafeNames() {
        XCTAssertTrue(LimitsManifest.isSafeName("limits/speed_limits_v2.0123456789abcdef.json"))
        for bad in ["", "/limits/x.json", "limits/../x.json", "limits/./x.json",
                    "limits/x y.json", "https://evil/x.json", "limits/x.json?y", "limits/"] {
            XCTAssertFalse(LimitsManifest.isSafeName(bad), bad)
        }
    }

    // MARK: - Файл против индекса

    func testExactFileIsAccepted() throws {
        let file = try XCTUnwrap(manifest().preferredFile())
        XCTAssertNil(LimitsTrust.verifyData(limitsData, against: file))
    }

    func testTamperedFileOfSameSizeIsRejectedBySha() throws {
        // «60» → «20»: тот же размер, другие лимиты — именно так выглядела бы
        // подмена на сервере, и именно её должен ловить sha.
        let file = try XCTUnwrap(manifest().preferredFile())
        XCTAssertEqual(tamperedData.count, limitsData.count)
        XCTAssertEqual(LimitsTrust.verifyData(tamperedData, against: file), .sha)
    }

    func testTruncatedFileIsRejectedBySize() throws {
        let file = try XCTUnwrap(manifest().preferredFile())
        XCTAssertEqual(LimitsTrust.verifyData(limitsData.dropLast(3), against: file),
                       .size(expected: limitsData.count, actual: limitsData.count - 3))
    }

    // MARK: - Кэш на диске: проверяется так же, как сеть

    /// Свой каталог на тест: кэш одного теста не должен попадать в другой.
    private func withCache(_ body: (_ dataURL: URL, _ manifestURL: URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitsTrustTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // Временный каталог системы: не удалился — уберёт сама система.
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("speed_limits.json"),
                 directory.appendingPathComponent("speed_limits_index.json"))
    }

    private func load(_ dataURL: URL, _ manifestURL: URL, ratchet: Bool,
                      acceptUnsigned: Bool = true) -> SpeedLimitCache.Loaded {
        SpeedLimitCache.load(dataURL: dataURL, manifestURL: manifestURL, ratchetSet: ratchet,
                             acceptUnsigned: acceptUnsigned, publicKeyB64: publicKeyB64)
    }

    private var tamperedData: Data {
        Data(String(decoding: limitsData, as: UTF8.self)
            .replacingOccurrences(of: "[[60,", with: "[[20,").utf8)
    }

    func testSignedCacheIsReverifiedAndLoaded() throws {
        try withCache { dataURL, manifestURL in
            try limitsData.write(to: dataURL)
            try validIndex().write(to: manifestURL)
            let loaded = load(dataURL, manifestURL, ratchet: true)
            XCTAssertNotNil(loaded.index)
            XCTAssertEqual(loaded.source, .signed(sha256: RoadTiles.sha256Hex(of: limitsData)))
            XCTAssertTrue(loaded.sawSignedIndex)
        }
    }

    func testSignedIndexOnDiskRaisesTheRatchet() throws {
        // Подпись на диске — доказательство, что владелец уже публиковал.
        try withCache { dataURL, manifestURL in
            try limitsData.write(to: dataURL)
            try validIndex().write(to: manifestURL)
            XCTAssertTrue(load(dataURL, manifestURL, ratchet: false).sawSignedIndex)
        }
    }

    func testCacheEditedOnDiskIsNotUsed() throws {
        try withCache { dataURL, manifestURL in
            try tamperedData.write(to: dataURL)
            try validIndex().write(to: manifestURL)
            let loaded = load(dataURL, manifestURL, ratchet: true)
            XCTAssertNil(loaded.index, "файл в Documents не надёжнее сети")
            XCTAssertTrue(loaded.sawSignedIndex)
        }
    }

    func testAfterRatchetUnsignedCacheIsNotRead() throws {
        // Конверта нет (удалили, не записался) или он битый — после храповика
        // файл без подписи не читается: fail closed, сервис спросит сервер.
        try withCache { dataURL, manifestURL in
            try limitsData.write(to: dataURL)
            XCTAssertNil(load(dataURL, manifestURL, ratchet: true).index)
            try Data("мусор".utf8).write(to: manifestURL)
            XCTAssertNil(load(dataURL, manifestURL, ratchet: true).index)
        }
    }

    func testBeforeRatchetLegacyCacheStillWorks() throws {
        // Переход: обновление не отнимает лимиты, скачанные старой сборкой.
        try withCache { dataURL, manifestURL in
            try limitsData.write(to: dataURL)
            let loaded = load(dataURL, manifestURL, ratchet: false)
            XCTAssertNotNil(loaded.index)
            XCTAssertEqual(loaded.source, .legacy)
            XCTAssertFalse(loaded.sawSignedIndex)
            XCTAssertNil(load(dataURL, manifestURL, ratchet: false, acceptUnsigned: false).index,
                         "выключенный переход закрывает и кэш старого пути")
        }
    }

    func testTamperedDownloadIsNeitherAppliedNorCached() throws {
        let file = try XCTUnwrap(manifest().preferredFile())
        let envelope = try validIndex()
        try withCache { dataURL, manifestURL in
            let outcome = SpeedLimitCache.acceptSigned(tamperedData, file: file, envelope: envelope,
                                                       dataURL: dataURL, manifestURL: manifestURL)
            guard case .failure(.sha) = outcome else { return XCTFail("подменённый файл принят") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        }
    }

    func testAcceptedDownloadSurvivesRelaunch() throws {
        let file = try XCTUnwrap(manifest().preferredFile())
        let envelope = try validIndex()
        try withCache { dataURL, manifestURL in
            let outcome = SpeedLimitCache.acceptSigned(limitsData, file: file, envelope: envelope,
                                                       dataURL: dataURL, manifestURL: manifestURL)
            guard case .success = outcome else { return XCTFail("честный набор отвергнут") }
            XCTAssertNotNil(load(dataURL, manifestURL, ratchet: true).index,
                            "после перезапуска набор проходит проверку диска")
        }
    }
}
