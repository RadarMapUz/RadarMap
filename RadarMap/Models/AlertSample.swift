//
//  AlertSample.swift
//  RadarMap
//
//  «Показать, как выглядит оповещение» (онбординг, настройки): тот же экран,
//  что у камеры в поездке, на выдуманной камере. Чисто картинка и звук — ни
//  LocationService, ни AlertEngine, ни истории, статистики, Live Activity,
//  часов и CarPlay.
//

import Foundation

nonisolated enum AlertSample {
    /// Пример не показывают в поездке и поверх настоящего оповещения: там он
    /// заслонил бы или подменил камеру, о которой предупреждают всерьёз.
    static func canShow(isTripActive: Bool, isApproachingCamera: Bool) -> Bool {
        !isTripActive && !isApproachingCamera
    }

    /// Те же 300 м, что в фразе примера (`AlertPlayer.playSample`).
    static let meters: Double = 300
    static let alertRadius: Double = 500
    static let speedKmh: Double = 52
    static let limitKmh = 60
    /// Камера чуть справа по ходу.
    static let relativeBearing: Double = 12

    /// Выдуманная камера: отрицательный id не совпадёт ни с одной из базы.
    static let camera = Camera(id: -1, region: "", city: "", location: "",
                               lat: 41.3111, lon: 69.2797, type: "Стационар камера",
                               violations: [], needsReview: nil)
}
