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
    /// Окна больше не будет — только Настройки приложения.
    case openSettings
    /// «Всегда» уже есть, просить нечего.
    case done

    /// `alwaysAsked` — повышение до «Всегда» уже запрашивалось на этой
    /// установке (неважно, показала ли его система и что ответили).
    static func next(status: CLAuthorizationStatus, alwaysAsked: Bool) -> LocationAccessStep {
        switch status {
        case .notDetermined: return .askWhenInUse
        case .authorizedWhenInUse: return alwaysAsked ? .openSettings : .askAlways
        case .authorizedAlways: return .done
        // Отказ: системное окно не вернётся никогда. Ограничение (родительский
        // контроль) снимается тоже только в Настройках — кнопка хотя бы
        // покажет, почему переключатель серый, а не будет молчать.
        case .denied, .restricted: return .openSettings
        @unknown default: return .openSettings
        }
    }

    /// Под кнопкой — путь в Настройках: открываем их мы, а выбрать там
    /// «Всегда» человек должен сам.
    var needsSettingsHint: Bool { self == .openSettings }
}
