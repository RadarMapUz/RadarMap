//
//  LimitsManifest.swift
//  RadarMap
//
//  Подписанный индекс лимитов скорости и решение «чему верить».
//
//  Лимиты говорят голосом («Превышение скорости») и считают суммы штрафов —
//  класс доверия тот же, что у базы камер и пульта (ARCHITECTURE.md, правило
//  19). Устройство повторяет дорожные тайлы: подписан маленький индекс
//  (SignedPayload) с sha256 и размером каждого файла, а сам файл в 3,4 МБ
//  едет без подписи и сверяется с индексом. Индекс собирает
//  server/build_limits_index.py, подписывает владелец у себя
//  (server/publish_limits.sh) — ключа на сервере нет.
//
//  Переход — храповик. Владелец ещё не опубликовал индекс, а обновление
//  приложения не вправе оставить людей без лимитов, поэтому до первого
//  настоящего индекса работает старый неподписанный путь. Как только телефон
//  увидел индекс с верной подписью, старый путь закрыт НАВСЕГДА: иначе
//  достаточно было бы срезать индекс (404 вместо файла), чтобы вернуть
//  телефон на неподписанные данные.
//
//  Всё здесь чистое и nonisolated: решение о доверии покрыто
//  LimitsTrustTests, а не живёт в ветвлениях сервиса рядом с URLSession.
//

import Foundation

/// Индекс подписанного набора — ровно то, что пишет build_limits_index.py.
nonisolated struct LimitsManifest: Decodable, Sendable, Equatable {
    /// Формат самого индекса. Чужой формат отвергается целиком: угадывать
    /// поля подписанного файла — то же, что не проверять подпись.
    let format: Int
    /// Версия данных — unix-время сборки лимитов на сервере.
    let version: Int
    let files: [File]

    nonisolated struct File: Decodable, Sendable, Equatable {
        /// Формат файла лимитов: 1 — [limit, geometry], 2 — [limit, cls, geometry].
        let format: Int
        /// Путь относительно syncBaseURL: limits/<база>.<sha16>.json. Адрес с
        /// хэшем, а не тот, что переписывает месячный крон, — иначе подпись
        /// разошлась бы с файлом в минуту прогона.
        let name: String
        let sha256: String
        let bytes: Int
    }

    /// Файл, который качаем: самый новый из понятных форматов. Индекс несёт и
    /// старый формат — на случай сборок, которые новый забудут; нам он не нужен.
    func preferredFile(knownFormats: Set<Int> = LimitsTrust.knownDataFormats) -> File? {
        files.filter { knownFormats.contains($0.format) }.max { $0.format < $1.format }
    }

    /// Что в индексе не по контракту (nil — годен). Подпись к этому моменту
    /// уже проверена, так что это защита не от чужого, а от собственной
    /// ошибки публикации: индекс, по которому нечего скачать, обязан быть
    /// отвергнут с причиной в журнале, а не молча оставить телефон без лимитов.
    func schemaProblem() -> String? {
        guard format == LimitsTrust.indexFormat else { return "формат индекса \(format)" }
        guard version > 0 else { return "версия \(version)" }
        guard let file = preferredFile() else { return "нет файла понятного формата" }
        guard Self.isSafeName(file.name) else { return "недопустимое имя «\(file.name)»" }
        // Хэш сравнивается строкой с RoadTiles.sha256Hex (строчные hex), так
        // что заглавный hex не сошёлся бы НИКОГДА — лучше сказать это здесь.
        guard file.sha256.count == 64,
              file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return "sha256 не 64 строчных hex" }
        guard (1...AppConfig.speedLimitsMaxBytes).contains(file.bytes) else {
            return "размер \(file.bytes)"
        }
        return nil
    }

    /// Имя — путь внутри вебрута: сегменты из [A-Za-z0-9._-], без «..» и
    /// пустых. Индекс подписан, и это не защита от чужого, а гарантия, что
    /// адрес, собранный из имени, не выйдет за /radarmap/ даже при ошибке в
    /// скрипте публикации.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { safeNameCharacters.contains($0) }
        }
    }

    private static let safeNameCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}

/// Решение о доверии к лимитам и проверки набора — без сети и диска.
nonisolated enum LimitsTrust {

    /// Формат индекса, который понимает эта сборка (INDEX_FORMAT сервера).
    static let indexFormat = 1
    /// Форматы файла лимитов, которые умеет LimitIndex.build.
    static let knownDataFormats: Set<Int> = [1, 2]

    /// Почему подписанный набор отвергнут. Решение у всех одно — не
    /// применять, но в журнал причина идёт обязательно: «подпись» — чужие
    /// руки, «sha»/«размер» — подменённая или битая выкладка файла, «схема» —
    /// наша же ошибка публикации. Чинятся они по-разному.
    nonisolated enum Rejection: Error, Equatable, Sendable {
        case notEnvelope
        case signature
        case schema(String)
        case size(expected: Int, actual: Int)
        case sha

        var logDescription: String {
            switch self {
            case .notEnvelope: "не конверт SignedPayload"
            case .signature: "подпись не сошлась"
            case .schema(let why): "схема: \(why)"
            case .size(let expected, let actual): "размер \(actual) вместо \(expected)"
            case .sha: "sha256 не сошёлся с индексом"
            }
        }
    }

    /// Подписанный индекс на входе решения.
    nonisolated enum IndexState: Equatable, Sendable {
        /// Нет вовсе: 404, сеть, на диске не лежит.
        case absent
        /// Есть, но отвергнут — с причиной.
        case invalid(Rejection)
        /// Есть, подпись и схема в порядке.
        case valid(LimitsManifest)
    }

    nonisolated enum Decision: Equatable, Sendable {
        /// Брать файл по индексу и сверять sha и размер.
        case useSigned(LimitsManifest)
        /// Переход: старый неподписанный путь (speed_limits_v2 → speed_limits).
        case useLegacy
        /// Ничего нового не принимать: держать последнее ПРОВЕРЕННОЕ, а если
        /// его нет — жить без лимитов (fail closed).
        case keepVerified
    }

    /// Чему верить на этот раз.
    ///
    /// Индекс с верной подписью — всегда подписанный путь. Иначе решает
    /// храповик: если подписанный индекс уже видели, старый путь закрыт, и
    /// пропажа индекса значит «держим проверенное», а не «берём что дают».
    ///
    /// Битый индекс до храповика равен отсутствующему. Тот, кто его испортил,
    /// мог с тем же успехом его удалить и получить старый путь — строгость тут
    /// не дала бы защиты, а свежие установки при ошибке публикации остались бы
    /// без лимитов. После храповика оба случая — «держим проверенное».
    /// `lastSignedVersion` — версия последнего применённого подписанного
    /// индекса: подписанный, но СТАРШЕ его — откат (сервер отдаёт прошлую
    /// подписанную выкладку), держим проверенное (S18).
    static func decide(signedIndex: IndexState, ratchetSet: Bool, lastSignedVersion: Int? = nil,
                       acceptUnsigned: Bool = AppConfig.speedLimitsAcceptUnsigned) -> Decision {
        if case .valid(let manifest) = signedIndex {
            if let lastSignedVersion, manifest.version < lastSignedVersion { return .keepVerified }
            return .useSigned(manifest)
        }
        return allowsLegacy(ratchetSet: ratchetSet, acceptUnsigned: acceptUnsigned)
            ? .useLegacy : .keepVerified
    }

    /// Можно ли держать индекс, собранный из НЕподписанных данных (кэш
    /// старого пути на диске или уже в памяти).
    static func allowsLegacy(ratchetSet: Bool,
                             acceptUnsigned: Bool = AppConfig.speedLimitsAcceptUnsigned) -> Bool {
        !ratchetSet && acceptUnsigned
    }

    /// Подписанный индекс из сырых байтов (сеть или диск): конверт → подпись
    /// (SignedPayload — единственный проверяющий, правило 19) → схема.
    static func verifyIndex(_ data: Data,
                            publicKeyB64: String = AppConfig.otaPublicKeyB64)
        -> Result<LimitsManifest, Rejection> {
        let envelope: SignedPayload<LimitsManifest>
        do {
            envelope = try JSONDecoder().decode(SignedPayload<LimitsManifest>.self, from: data)
        } catch {
            return .failure(.notEnvelope)
        }
        switch envelope.verify(publicKeyB64: publicKeyB64) {
        case .failure(.payloadNotBase64): return .failure(.notEnvelope)
        case .failure(.signature): return .failure(.signature)
        case .failure(.json): return .failure(.schema("payload не разбирается"))
        case .success(let manifest):
            if let problem = manifest.schemaProblem() { return .failure(.schema(problem)) }
            return .success(manifest)
        }
    }

    /// Состояние индекса для `decide`: nil-байты — «индекса нет вовсе».
    static func indexState(_ data: Data?,
                           publicKeyB64: String = AppConfig.otaPublicKeyB64) -> IndexState {
        guard let data else { return .absent }
        switch verifyIndex(data, publicKeyB64: publicKeyB64) {
        case .success(let manifest): return .valid(manifest)
        case .failure(let why): return .invalid(why)
        }
    }

    /// Файл против индекса: сначала размер (дёшево и сразу говорит, что
    /// скачалось не то), потом sha256 ровно полученных байтов. nil — сошлось.
    static func verifyData(_ data: Data, against file: LimitsManifest.File) -> Rejection? {
        guard data.count == file.bytes else {
            return .size(expected: file.bytes, actual: data.count)
        }
        guard RoadTiles.sha256Hex(of: data) == file.sha256 else { return .sha }
        return nil
    }
}
