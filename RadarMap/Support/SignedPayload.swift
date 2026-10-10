//
//  SignedPayload.swift
//  RadarMap
//
//  Конверт для всего, что приходит с сервера и применяется без участия
//  пользователя: пульт (config.json), правки базы камер (overrides.json),
//  индексы дорожных тайлов и лимитов скорости (speed_limits_index.json).
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

    /// Почему конверт отвергнут. Только для журнала: решение у всех причин
    /// одно — не применять. Но «подпись не сошлась» (чужие руки) и «JSON не
    /// по контракту» (наша ошибка публикации) чинятся по-разному, и в логе
    /// их надо различать (лимиты скорости пишут причину, LimitsTrust).
    nonisolated enum Failure: Error, Equatable, Sendable {
        /// payload — не base64: конверт битый ещё до подписи.
        case payloadNotBase64
        /// Подписи нет, она не base64 или не сходится с ключом.
        case signature
        /// Подпись верна, но байты не разбираются в `Value`.
        case json
    }

    /// То же, что `verified`, но с причиной отказа. Порядок проверок тот же
    /// и единственный: подпись ДО разбора JSON.
    func verify(publicKeyB64: String = AppConfig.otaPublicKeyB64) -> Result<Value, Failure> {
        guard let data = Data(base64Encoded: payload) else { return .failure(.payloadNotBase64) }
        guard OTASignature.isValid(data: data, signatureB64: sig, publicKeyB64: publicKeyB64)
        else { return .failure(.signature) }
        do {
            return .success(try JSONDecoder().decode(Value.self, from: data))
        } catch {
            return .failure(.json)
        }
    }

    /// Разобрать и проверить. `nil` на любой неисправности: вызывающий обязан
    /// взять значения по умолчанию, а не пытаться спасти часть данных.
    func verified(publicKeyB64: String = AppConfig.otaPublicKeyB64) -> Value? {
        guard case .success(let value) = verify(publicKeyB64: publicKeyB64) else { return nil }
        return value
    }
}
