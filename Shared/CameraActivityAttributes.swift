//
//  CameraActivityAttributes.swift
//  RadarMap
//
//  Контракт Live Activity — компилируется и в приложение, и в widget-extension.
//

import Foundation
import ActivityKit

struct CameraActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Адрес/название ближайшей камеры (nil — рядом камер нет).
        var nearestTitle: String?
        /// SF Symbol типа камеры ("camera.fill" / "speedometer").
        var nearestSymbol: String
        /// Расстояние до ближайшей камеры, метры.
        var distanceMeters: Double?
        /// Сколько камер под мониторингом вокруг.
        var camerasNearby: Int
    }
}
