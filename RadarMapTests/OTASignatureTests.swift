//
//  OTASignatureTests.swift
//  RadarMapTests
//
//  Подпись OTA-базы: валидная проходит, подделка и мусор — нет.
//  Фикстура подписана боевым приватным ключом (server/sign_db.sh).
//

import XCTest
@testable import RadarMap

final class OTASignatureTests: XCTestCase {
    private let payload = Data(#"{"probe":"radarmap-ota"}"#.utf8)
    private let validSig = "+ZFAU41N+xh9ML2IEFc4QX1NEhqY4SZltfdHTLQMMyl7ji/6W5QDjSkbCNPPz/e2IacIjjgJ0odR2/RCIxwXDQ=="

    func testValidSignaturePasses() {
        XCTAssertTrue(OTASignature.isValid(data: payload, signatureB64: validSig))
    }

    func testTamperedPayloadFails() {
        let tampered = Data(#"{"probe":"radarmap-otA"}"#.utf8)
        XCTAssertFalse(OTASignature.isValid(data: tampered, signatureB64: validSig))
    }

    func testMissingOrGarbageSignatureFails() {
        XCTAssertFalse(OTASignature.isValid(data: payload, signatureB64: nil),
                       "без подписи база не применяется (fail closed)")
        XCTAssertFalse(OTASignature.isValid(data: payload, signatureB64: ""))
        XCTAssertFalse(OTASignature.isValid(data: payload, signatureB64: "не base64 вовсе"))
        XCTAssertFalse(OTASignature.isValid(data: payload,
                                            signatureB64: Data(repeating: 7, count: 64).base64EncodedString()))
    }

    func testWrongKeyFails() {
        let otherKey = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertFalse(OTASignature.isValid(data: payload, signatureB64: validSig,
                                            publicKeyB64: otherKey))
    }
}
