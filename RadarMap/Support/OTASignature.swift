//
//  OTASignature.swift
//  RadarMap
//
//  Проверка Ed25519-подписи OTA-базы камер. База ходит по HTTP до переезда
//  на домен+HTTPS, а применяется без участия пользователя — подпись гарантирует,
//  что её собрал владелец приватного ключа, а не Wi-Fi по дороге и не взломанный
//  сервер. Подписывает server/sign_db.sh (ключ хранится вне репозитория).
//

import CryptoKit
import Foundation

nonisolated enum OTASignature {
    /// Проверить подпись сырых байтов базы. Пустая/битая подпись = невалидна:
    /// OTA без подписи не применяется (fail closed).
    static func isValid(data: Data, signatureB64: String?,
                        publicKeyB64: String = AppConfig.otaPublicKeyB64) -> Bool {
        guard let signatureB64,
              let signature = Data(base64Encoded: signatureB64),
              let keyRaw = Data(base64Encoded: publicKeyB64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyRaw)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
