//
//  SpeedLimitCache.swift
//  RadarMap
//
//  Диск и проверка набора лимитов — тяжёлая половина SpeedLimitService,
//  которая работает вне главного потока: чтение 3,4 МБ, sha256, сборка
//  индекса сегментов, атомарная запись. Сервис держит состояние и сеть, а
//  правила доверия берёт у LimitsTrust; здесь — только их применение к байтам.
//
//  Главное правило: кэш на диске проверяется ТАК ЖЕ, как ответ сервера. Конверт
//  индекса хранится неразобранным и при каждом чтении проходит подпись, файл —
//  sha256 и размер против него (как индекс дорог в RoadNetworkService).
//

import Foundation
import os

nonisolated enum SpeedLimitCache {

    /// Откуда взят индекс в памяти.
    nonisolated enum Source: Equatable, Sendable {
        /// Из подписанного набора — с sha файла, чтобы не качать его повторно.
        case signed(sha256: String)
        /// Из неподписанного файла старого пути (переход до храповика).
        case legacy
    }

    /// Что нашлось на диске.
    nonisolated struct Loaded: Sendable {
        var index: LimitIndex?
        var source: Source?
        /// На диске лежит индекс с верной подписью — храповик обязан стоять.
        var sawSignedIndex = false
    }

    /// Прочитать кэш по правилам храповика. `ratchetSet` — состояние флага
    /// до чтения; подпись на диске может его поднять (`sawSignedIndex`).
    /// `publicKeyB64` подменяют только тесты — ключ владельца им недоступен.
    static func load(dataURL: URL, manifestURL: URL, ratchetSet: Bool,
                     acceptUnsigned: Bool = AppConfig.speedLimitsAcceptUnsigned,
                     publicKeyB64: String = AppConfig.otaPublicKeyB64) -> Loaded {
        let state = LimitsTrust.indexState(read(manifestURL), publicKeyB64: publicKeyB64)
        if case .invalid(let why) = state {
            Log.route.error("индекс лимитов на диске отвергнут: \(why.logDescription, privacy: .public)")
        }
        switch LimitsTrust.decide(signedIndex: state, ratchetSet: ratchetSet,
                                  acceptUnsigned: acceptUnsigned) {
        case .useSigned(let manifest):
            var loaded = Loaded(sawSignedIndex: true)
            guard let file = manifest.preferredFile(), let data = read(dataURL) else {
                Log.route.error("кэш лимитов: подписанный индекс есть, файла нет — ждём сервер")
                return loaded
            }
            switch verifyAndBuild(data, against: file) {
            case .success(let index):
                loaded.index = index
                loaded.source = .signed(sha256: file.sha256)
            case .failure(let why):
                // Файл не тот, что подписан: подменён на диске или запись
                // прервалась между файлом и конвертом. Не «спасаем» — сервис
                // увидит пустой индекс и сразу спросит сервер.
                Log.route.error("кэш лимитов отвергнут: \(why.logDescription, privacy: .public)")
            }
            return loaded
        case .useLegacy:
            guard let data = read(dataURL) else { return Loaded() }
            guard let index = LimitIndex.build(from: data) else {
                Log.route.error("кэш лимитов есть на диске, но не прочитался")
                return Loaded()
            }
            return Loaded(index: index, source: .legacy)
        case .keepVerified:
            // Проверенного на диске нет, а неподписанное после храповика (или
            // с выключенным переходом) не читаем вовсе.
            if FileManager.default.fileExists(atPath: dataURL.path) {
                Log.route.notice("кэш лимитов без подписи не читаю: неподписанный путь закрыт")
            }
            return Loaded()
        }
    }

    /// Файл по подписанному индексу: размер → sha → разбор, и только потом
    /// запись на диск — сначала файл, затем конверт, чтобы конверт на диске
    /// никогда не описывал файл, которого там ещё нет.
    static func acceptSigned(_ data: Data, file: LimitsManifest.File, envelope: Data,
                             dataURL: URL, manifestURL: URL)
        -> Result<LimitIndex, LimitsTrust.Rejection> {
        let outcome = verifyAndBuild(data, against: file)
        guard case .success = outcome else { return outcome }
        do {
            try data.write(to: dataURL, options: .atomic)
            try envelope.write(to: manifestURL, options: .atomic)
        } catch {
            // Индекс уже в памяти. Без кэша следующий запуск не пройдёт
            // проверку диска и просто скачает набор заново.
            Log.route.error("кэш лимитов не записался: \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// Старый неподписанный путь (только до храповика): разбор и запись.
    static func acceptLegacy(_ data: Data, dataURL: URL) -> LimitIndex? {
        guard let index = LimitIndex.build(from: data) else { return nil }
        do { try data.write(to: dataURL, options: .atomic) } catch {
            // Индекс уже в памяти — без кэша просто перекачаем через неделю.
            Log.route.error("кэш лимитов не записался: \(error.localizedDescription, privacy: .public)")
        }
        return index
    }

    private static func verifyAndBuild(_ data: Data, against file: LimitsManifest.File)
        -> Result<LimitIndex, LimitsTrust.Rejection> {
        if let why = LimitsTrust.verifyData(data, against: file) { return .failure(why) }
        guard let index = LimitIndex.build(from: data) else {
            return .failure(.schema("файл лимитов не разобрался"))
        }
        return .success(index)
    }

    /// nil — файла нет (обычное состояние до первой загрузки) или он не
    /// читается; второе — в журнал.
    private static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            Log.route.error("\(url.lastPathComponent, privacy: .public) не читается: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
