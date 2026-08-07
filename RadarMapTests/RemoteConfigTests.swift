//
//  RemoteConfigTests.swift
//  RadarMapTests
//
//  «Пульт» — единственная вещь в приложении, которой управляют снаружи, поэтому
//  проверяем прежде всего границы: что он НЕ может и когда ему НЕ верят.
//

import CryptoKit
import XCTest
@testable import RadarMap

final class RemoteConfigTests: XCTestCase {

    // MARK: - Значения по умолчанию

    func testEmptyConfigMeansEverythingOn() {
        let config = RemoteConfig.default
        XCTAssertTrue(config.isRoutingEnabled)
        XCTAssertTrue(config.areMobileReportsEnabled)
        XCTAssertTrue(config.areMetricsEnabled)
        XCTAssertEqual(config.pollInterval, AppConfig.mobilePollInterval)
        XCTAssertNil(config.activeMessage())
    }

    func testFeatureFlagsSwitchOffIndividually() {
        var config = RemoteConfig()
        config.features = .init(routing: false, mobileReports: nil, metrics: nil)
        XCTAssertFalse(config.isRoutingEnabled)
        XCTAssertTrue(config.areMobileReportsEnabled, "неуказанный флаг = включено")
        XCTAssertTrue(config.areMetricsEnabled)
    }

    // MARK: - Зажим значений

    func testPollIntervalOutOfRangeFallsBackToBuild() {
        var config = RemoteConfig()
        for bad in [0.0, 5.0, 86400.0, -1.0] {
            config.mobilePollInterval = bad
            XCTAssertEqual(config.pollInterval, AppConfig.mobilePollInterval,
                           "\(bad) — это испорченный файл, а не настройка")
        }
        config.mobilePollInterval = 600
        XCTAssertEqual(config.pollInterval, 600, "значение в границах должно применяться")
    }

    // MARK: - Версии

    func testVersionCompareIsNumericNotAlphabetic() {
        XCTAssertEqual(RemoteConfig.compare("1.10", "1.9"), 1, "строковое сравнение здесь врёт")
        XCTAssertEqual(RemoteConfig.compare("1.0", "1.0.0"), 0, "хвост из нулей ничего не меняет")
        XCTAssertEqual(RemoteConfig.compare("2.0", "10.0"), -1)
        XCTAssertEqual(RemoteConfig.compare("1.0-beta", "1.0"), 0, "нечисловой хвост не делает версию новее")
    }

    func testRequiresUpdateOnlyWhenMinVersionSet() {
        var config = RemoteConfig()
        XCTAssertFalse(config.requiresUpdate(currentVersion: "0.1"),
                       "без minVersion не просим обновляться никогда")
        config.minVersion = "1.2"
        XCTAssertTrue(config.requiresUpdate(currentVersion: "1.1"))
        XCTAssertFalse(config.requiresUpdate(currentVersion: "1.2"))
        XCTAssertFalse(config.requiresUpdate(currentVersion: "1.10"))
    }

    // MARK: - Объявление

    func testExpiredMessageIsNotShown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var config = RemoteConfig()
        config.message = .init(title: "Работы на сервере", body: nil,
                               until: now.timeIntervalSince1970 - 1)
        XCTAssertNil(config.activeMessage(now: now), "забытая плашка хуже, чем никакой")

        config.message = .init(title: "Работы на сервере", body: nil,
                               until: now.timeIntervalSince1970 + 60)
        XCTAssertNotNil(config.activeMessage(now: now))

        config.message = .init(title: "Бессрочное", body: nil, until: nil)
        XCTAssertNotNil(config.activeMessage(now: now), "без until показываем всегда")
    }

    // MARK: - Подпись: fail closed

    /// Собрать конверт так же, как это делает server/publish_config.sh.
    private func envelope(_ config: RemoteConfig,
                          signedBy key: Curve25519.Signing.PrivateKey,
                          tamper: Bool = false) throws -> (RemoteConfigEnvelope, String) {
        var payload = try JSONEncoder().encode(config)
        let signature = try key.signature(for: payload)
        if tamper {
            // Меняем полезную нагрузку ПОСЛЕ подписи — ровно то, что сделает
            // MITM на HTTP: подпись остаётся настоящей, байты уже нет.
            var config = config
            config.features = .init(routing: false, mobileReports: false, metrics: false)
            payload = try JSONEncoder().encode(config)
        }
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        return (RemoteConfigEnvelope(payload: payload.base64EncodedString(),
                                     sig: signature.base64EncodedString()), publicKey)
    }

    func testValidSignatureIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        var config = RemoteConfig()
        config.mobilePollInterval = 600
        config.features = .init(routing: false, mobileReports: nil, metrics: nil)
        let (envelope, publicKey) = try self.envelope(config, signedBy: key)
        let decoded = envelope.verified(publicKeyB64: publicKey)
        XCTAssertEqual(decoded, config)
    }

    func testTamperedPayloadIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (envelope, publicKey) = try self.envelope(RemoteConfig(), signedBy: key, tamper: true)
        XCTAssertNil(envelope.verified(publicKeyB64: publicKey),
                     "подменённые по дороге байты не должны применяться")
    }

    func testForeignKeyIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let (envelope, _) = try self.envelope(RemoteConfig(), signedBy: key)
        let stranger = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        XCTAssertNil(envelope.verified(publicKeyB64: stranger),
                     "конфиг, подписанный чужим ключом, — это чужой конфиг")
    }

    func testMissingSignatureIsRejected() throws {
        let payload = try JSONEncoder().encode(RemoteConfig()).base64EncodedString()
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        XCTAssertNil(RemoteConfigEnvelope(payload: payload, sig: nil).verified(publicKeyB64: key),
                     "неподписанный пульт — не пульт (fail closed)")
    }

    func testGarbagePayloadIsRejected() {
        let key = Curve25519.Signing.PrivateKey().publicKey
            .rawRepresentation.base64EncodedString()
        XCTAssertNil(RemoteConfigEnvelope(payload: "не base64!", sig: "тоже нет")
            .verified(publicKeyB64: key))
    }

    // MARK: - Срок годности кэша

    func testStoredConfigExpiresAndDistrustsRewoundClock() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = StoredRemoteConfig(config: .default, fetchedAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(fresh.isFresh(now: now), "вчерашний стоп-кран обязан пережить перезапуск")

        let stale = StoredRemoteConfig(
            config: .default,
            fetchedAt: now.addingTimeInterval(-AppConfig.remoteConfigMaxAge - 1))
        XCTAssertFalse(stale.isFresh(now: now),
                       "если сервер молчит неделю, вероятнее, что беда кончилась")

        let future = StoredRemoteConfig(config: .default, fetchedAt: now.addingTimeInterval(86400))
        XCTAssertFalse(future.isFresh(now: now),
                       "часы перевели назад — иначе так пульт продлевается навсегда")
    }
}
