//
//  SignedPayload.swift
//  RadarMap
//
//  Конверт для всего, что приходит с сервера и применяется без участия
//  пользователя: пульт (config.json) и правки базы камер (overrides.json).
//
//  Полезная нагрузка — base64 ТОЧНЫХ байтов, по которым считана подпись.
//  Подписывать сам JSON нельзя: любая перекодировка по дороге (другой порядок
//  ключей, пробелы, экранирование) ломает подпись, и файл, собранный владельцем
//  правильно, отвергался бы у половины пользователей.
//
//  Проверка подписи живёт здесь в единственном экземпляре намеренно: это
//  единственное, что отделяет наши данные от данных того, кто перехватит HTTP
//  или получит доступ к серверу, и второй копии этой логики быть не должно.
//

import Foundation

/// Encodable — чтобы конверт можно было положить в кэш НЕ разбирая: на диске
/// он лежит вместе с подписью и проверяется при каждом чтении. Хранить уже
/// разобранное значение означало бы доверять файлу в Documents, который виден
/// и бэкапу, и файловому менеджеру, — а он ничем не надёжнее сети.
nonisolated struct SignedPayload<Value: Decodable & Sendable>: Codable, Sendable {
    let payload: String
    let sig: String?

    /// Разобрать и проверить. `nil` на любой неисправности: вызывающий обязан
    /// взять значения по умолчанию, а не пытаться спасти часть данных.
    func verified(publicKeyB64: String = AppConfig.otaPublicKeyB64) -> Value? {
        guard let data = Data(base64Encoded: payload),
              OTASignature.isValid(data: data, signatureB64: sig, publicKeyB64: publicKeyB64),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else { return nil }
        return value
    }
}
