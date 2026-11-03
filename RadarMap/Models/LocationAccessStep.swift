//
//  LocationAccessStep.swift
//  RadarMap
//
//  Что делает кнопка «Разрешить» / «Всегда» / «Включить» при каждом статусе
//  доступа к геопозиции. Окно повышения до «Всегда» iOS показывает приложению
//  один раз; дальше requestAlwaysAuthorization молчит, и кнопка, которая его
//  зовёт, — мёртвая (так было в онбординге до 40D). Тогда путь один —
//  Настройки приложения, с подсказкой, что там выбрать.
//
//  Чистое решение; запрос и переход — в LocationService и на экранах.
//  Покрыто LocationAccessStepTests.
//

import CoreLocation

nonisolated enum LocationAccessStep: Equatable {
    /// Первое окно iOS — «При использовании».
    case askWhenInUse
    /// Окно повышения до «Всегда»: его ещё не просили.
    case askAlways
    /// Окна больше не будет — только Настройки приложения, там «Всегда».
    case openSettings
    /// Ограничено устройством: родительский контроль или выключенные Службы
    /// геолокации. На странице приложения «Всегда» не выбрать — подсказка
    /// другая; открываем её всё равно: другого пути у нас нет.
    case deviceLimited
    /// «Всегда» уже есть, просить нечего.
    case done

    /// `alwaysAsked` — повышение до «Всегда» уже запрашивалось на этой
    /// установке (неважно, показала ли его система и что ответили).
    /// `servicesEnabled` — Службы геолокации устройства включены: выключенные
    /// iOS отдаёт приложению как `.denied`.
    static func next(status: CLAuthorizationStatus, alwaysAsked: Bool,
                     servicesEnabled: Bool = true) -> LocationAccessStep {
        switch status {
        case .notDetermined: return .askWhenInUse
        case .authorizedWhenInUse: return alwaysAsked ? .openSettings : .askAlways
        case .authorizedAlways: return .done
        // Отказ: системное окно не вернётся никогда — только Настройки.
        case .denied: return servicesEnabled ? .openSettings : .deviceLimited
        case .restricted: return .deviceLimited
        @unknown default: return .openSettings
        }
    }

    /// Подсказка под кнопкой: открываем Настройки мы, выбирает человек.
    enum Hint: Equatable {
        /// «Геопозиция → Всегда» на странице приложения.
        case pickAlways
        /// Ограничение устройства — на странице приложения его не снять.
        case deviceLimited
    }

    var hint: Hint? {
        switch self {
        case .openSettings: return .pickAlways
        case .deviceLimited: return .deviceLimited
        case .askWhenInUse, .askAlways, .done: return nil
        }
    }
}
