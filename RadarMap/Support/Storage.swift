//
//  Storage.swift
//  RadarMap
//
//  Типизированный доступ к UserDefaults: все ключи — в одном перечислении,
//  сырые строки по коду запрещены (ARCHITECTURE.md, правило 5).
//  Значения ключей менять нельзя — под ними уже лежат данные пользователей.
//

import Foundation

enum Storage {
    enum Key: String {
        case lifetimeStats          // пожизненные счётчики поездок (JSON)
        case passGeoCleanup1        // флаг одноразовой гео-чистки истории
        // Второй прогон: порог сузили со 120 до 70 м вслед за живым гейтом
        // траверза, и на развязках всплыли камеры поперечных улиц, которые
        // первый прогон пропускал. Отдельный флаг, потому что первый у всех
        // уже отработал и сам себя больше не запустит.
        case passGeoCleanup2
        case passAxisCleanup1       // флаг одноразовой чистки «мостовых» проездов (ось дороги)
        case metricsDeviceID        // анонимный ID для MetricKit-отчётов
        case mobileDeviceID         // анонимный ID для голосований по камерам
        case feedbackDeviceID       // анонимный ID для обратной связи
        case lastSyncCheck          // дата последней проверки базы камер
        case remoteConfigCheck      // дата последней проверки «пульта» (config.json)
        case overridesCheck         // дата последней проверки правок модератора (overrides.json)
        case cameraDBVersion        // версия локальной базы камер
        case speedLimitsLastCheck   // дата последней проверки базы лимитов
        case roadsIndexLastCheck    // дата последней проверки индекса дорожных тайлов
        case hasCompletedOnboarding // онбординг пройден (@AppStorage)
        case reviewAskedVersion     // версия, в которой уже просили оценку App Store
        // Тишина, включённая кнопкой в CarPlay. Хранится, а не живёт в делегате:
        // при переподключении делегат создаётся заново и «что было до тишины»
        // терялось — восстановление включало звук тем, кто выключал его намеренно.
        case carPlayMuted           // тишина активна (снимается при выходе из машины)
        case carPlayVoiceBeforeMute // rawValue VoiceMode до тишины
        case carPlaySoundBeforeMute // soundEnabled до тишины
    }

    private static var defaults: UserDefaults { .standard }

    static func bool(_ key: Key) -> Bool { defaults.bool(forKey: key.rawValue) }
    static func int(_ key: Key) -> Int { defaults.integer(forKey: key.rawValue) }
    static func string(_ key: Key) -> String? { defaults.string(forKey: key.rawValue) }
    static func date(_ key: Key) -> Date? { defaults.object(forKey: key.rawValue) as? Date }
    static func data(_ key: Key) -> Data? { defaults.data(forKey: key.rawValue) }
    static func double(_ key: Key) -> Double { defaults.double(forKey: key.rawValue) }
    /// Int с различием «нет значения» и «ноль».
    static func intIfPresent(_ key: Key) -> Int? { defaults.object(forKey: key.rawValue) as? Int }
    static func remove(_ key: Key) { defaults.removeObject(forKey: key.rawValue) }

    static func set(_ value: Bool, for key: Key) { defaults.set(value, forKey: key.rawValue) }
    static func set(_ value: Int, for key: Key) { defaults.set(value, forKey: key.rawValue) }
    static func set(_ value: String, for key: Key) { defaults.set(value, forKey: key.rawValue) }
    static func set(_ value: Date, for key: Key) { defaults.set(value, forKey: key.rawValue) }
    static func set(_ value: Data, for key: Key) { defaults.set(value, forKey: key.rawValue) }
    static func set(_ value: Double, for key: Key) { defaults.set(value, forKey: key.rawValue) }

    /// Анонимный идентификатор устройства: создаётся при первом обращении,
    /// дальше стабилен. Не связан с Apple ID/рекламными идентификаторами.
    /// Анонимный идентификатор с ротацией раз в 30 дней: анти-спам-лимиты
    /// суточные и не страдают, а связать перемещения/репорты одного устройства
    /// дольше месяца становится невозможно (privacy by design).
    static func anonymousID(_ key: Key) -> String {
        let stampRaw = key.rawValue + ".rotatedAt"
        let rotatedAt = defaults.object(forKey: stampRaw) as? Date
        if let existing = string(key), let rotatedAt,
           Date().timeIntervalSince(rotatedAt) < 30 * 86400 {
            return existing
        }
        let fresh = UUID().uuidString
        set(fresh, for: key)
        defaults.set(Date(), forKey: stampRaw)
        return fresh
    }
}
