//
//  RemoteConfig.swift
//  RadarMap
//
//  «Пульт»: маленький подписанный файл рядом с version.json, которым можно
//  починить без релиза то, что зависит от сервера. Лёг OSRM — выключаем кнопку
//  маршрута вместо вечного спиннера; пошла волна фейковых отметок — гасим
//  краудсорс на сутки; в стор уехала сломанная сборка — показываем «обновитесь».
//  Без пульта любая такая беда живёт до конца ревью Apple, то есть неделями.
//
//  Две границы, которые тут важнее всех значений:
//
//  1. Пульт НЕ УМЕЕТ трогать оповещения о камерах. Ни выключить, ни изменить
//     радиус. База лежит локально, и предупреждение за рулём обязано работать,
//     даже если сервера нет вовсе — а раз так, оно не должно зависеть и от того,
//     что сервер пришлёт. Управлять отсюда можно только тем, что и так живёт на
//     сервере: маршрутами, краудсорсом, отправкой метрик.
//  2. Fail closed. Нет файла, не сошлась подпись, не разобрался JSON, значение
//     вне границ — берём значения из AppConfig, а НЕ присланные. Пульт может
//     только сузить то, что мы делаем, и никогда не расширить.
//

import Foundation

/// Значения пульта. Все поля опциональны: сервер присылает только то, что
/// хочет изменить, остальное остаётся дефолтом сборки.
nonisolated struct RemoteConfig: Codable, Equatable, Sendable {
    /// Минимальная работоспособная версия приложения (`CFBundleShortVersionString`).
    /// Ниже — показываем `message` и просим обновиться.
    var minVersion: String?

    /// Объявление на карте: авария на сервере, плановые работы, важная новость.
    /// `nil` — ничего не показываем.
    var message: Message?

    /// Интервал опроса передвижных радаров (сек). Способ сбросить нагрузку,
    /// не выключая функцию целиком.
    var mobilePollInterval: TimeInterval?

    /// Что временно выключено. Отсутствующий флаг = включено.
    var features: Features?

    nonisolated struct Message: Codable, Equatable, Sendable {
        var title: String
        var body: String?
        /// Показывать до этой даты (Unix-время). Просроченное сообщение не
        /// показываем: забытая плашка хуже, чем никакой.
        var until: TimeInterval?
    }

    nonisolated struct Features: Codable, Equatable, Sendable {
        var routing: Bool?
        var mobileReports: Bool?
        var metrics: Bool?
        /// Пробки: и отправка кусков следа, и показ (рубильник на случай, если
        /// с данными что-то не так). Нет поля — включено, как у остальных.
        var traffic: Bool?
        /// «Поделиться прибытием» — рубильник на случай, если страница на
        /// сервере сломалась. Нет поля — включено.
        var etaShare: Bool?
        /// Погода на перевалах (19.2): загрузка, голос и баннер — рубильник на
        /// случай, если с прогнозом что-то не так. Нет поля — включено.
        var roadWeather: Bool?
    }

    /// Значения сборки: то, к чему мы возвращаемся всегда, когда пульту нельзя верить.
    static let `default` = RemoteConfig()

    // MARK: - Что из этого следует

    var isRoutingEnabled: Bool { features?.routing ?? true }
    var areMobileReportsEnabled: Bool { features?.mobileReports ?? true }
    var areMetricsEnabled: Bool { features?.metrics ?? true }
    var isTrafficEnabled: Bool { features?.traffic ?? true }
    var isEtaShareEnabled: Bool { features?.etaShare ?? true }
    var isRoadWeatherEnabled: Bool { features?.roadWeather ?? true }

    /// Интервал опроса с зажимом в разумные границы: присланные 0 или 86400 —
    /// это не «настройка», а испорченный файл.
    var pollInterval: TimeInterval {
        guard let value = mobilePollInterval,
              AppConfig.remoteConfigPollRange.contains(value) else {
            return AppConfig.mobilePollInterval
        }
        return value
    }

    /// Сообщение, если оно ещё не просрочено.
    func activeMessage(now: Date = Date()) -> Message? {
        guard let message else { return nil }
        if let until = message.until, now.timeIntervalSince1970 > until { return nil }
        return message
    }

    /// Версия приложения устарела настолько, что мы просим обновиться.
    /// Сравнение по компонентам: «1.10» новее «1.9», строковое сравнение здесь врёт.
    func requiresUpdate(currentVersion: String) -> Bool {
        guard let minVersion else { return false }
        return Self.compare(currentVersion, minVersion) < 0
    }

    /// -1 / 0 / +1. Нечисловые компоненты считаем нулями — «1.0-beta» не должен
    /// внезапно оказаться новее «1.0».
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

/// Конверт, в котором пульт лежит на сервере (см. `SignedPayload`).
typealias RemoteConfigEnvelope = SignedPayload<RemoteConfig>

/// Сохранённый пульт: значения плюс отметка, когда их получили. Дата нужна,
/// чтобы стоп-кран пережил перезапуск, но не действовал вечно.
nonisolated struct StoredRemoteConfig: Codable, Sendable {
    let config: RemoteConfig
    let fetchedAt: Date

    func isFresh(now: Date = Date(), maxAge: TimeInterval = AppConfig.remoteConfigMaxAge) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        // Отрицательный возраст — часы телефона перевели назад; такому файлу
        // тоже не верим: иначе подкрученные часы продлевают пульт навсегда.
        return age >= 0 && age < maxAge
    }
}
