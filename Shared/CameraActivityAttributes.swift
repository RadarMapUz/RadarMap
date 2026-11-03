//
//  CameraActivityAttributes.swift
//  RadarMap
//
//  Контракт Live Activity — компилируется и в приложение, и в widget-extension.
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit

// nonisolated: приложение собрано с MainActor по умолчанию, а ActivityKit
// кодирует состояние вне главного потока (`@concurrent` в LiveActivityService) —
// изолированное соответствие в Swift 6 стало бы ошибкой.
nonisolated struct CameraActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// Адрес/название ближайшей камеры (nil — рядом камер нет).
        var nearestTitle: String?
        /// SF Symbol типа камеры ("camera.fill" / "speedometer").
        var nearestSymbol: String
        /// Расстояние до ближайшей камеры, метры.
        var distanceMeters: Double?
        /// Когда машина будет у камеры на текущей скорости; nil — стоим или
        /// камеры нет. Полосу приближения между обновлениями двигает сама
        /// система (ProgressView(timerInterval:)) — плашку не нужно будить на
        /// каждые 25 м, чтобы картинка жила (аудит энергии 19.10).
        var arrivesAt: Date?
        /// Начало полосы — момент отправки состояния.
        var since: Date?
        /// Призрак дороги на работу (8.8.3б): прибытие по своим поездкам и
        /// готовая подпись на языке ПРИЛОЖЕНИЯ («Работа · +4 мин к обычному»)
        /// — плашка не знает ни языка приложения, ни правил запаса. `etaAlert`
        /// — подпись тревожная (позже срока, впритык, заметно дольше). nil —
        /// призрака нет; у старых состояний полей нет вовсе.
        var etaClock: Date? = nil
        var etaCaption: String? = nil
        var etaAlert: Bool? = nil
        /// Ограничение дороги, км/ч (9.1) — знак рядом с дистанцией; nil — не знаем.
        var limitKmh: Int? = nil
        /// Уровень тревоги 0–3 (9.1): цвет дистанции и полосы приближения —
        /// чем ближе, тем горячее; nil у старых состояний — как 0.
        var alertLevel: Int? = nil
        /// Звук выключен (9.1б) — значок кнопки «Звук» на плашке; nil у
        /// старых состояний — как «включён».
        var muted: Bool? = nil
        /// Ответ на «Радар!» с плашки (9.1б): true — отмечено, false —
        /// отказ (причину произносит голос); nil — кнопка в покое. Держится
        /// `AppConfig.liveActivityReportFlashSeconds` и снимается приложением.
        var reportFlash: Bool? = nil
        /// Отметку ещё можно отменить: на месте «Отметить» — «Отменить»
        /// (окно `AppConfig.reportUndoSeconds`); nil у старых состояний — нет.
        var reportUndo: Bool? = nil
        // «Камер вокруг» убрано 19.10: строка «следит за N камерами» была шумом,
        // а неквантованный счётчик слал обновления плашки и в пробке на месте.
    }
}
#endif
