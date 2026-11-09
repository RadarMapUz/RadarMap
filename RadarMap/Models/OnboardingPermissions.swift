//
//  OnboardingPermissions.swift
//  RadarMap
//
//  Что делает главная кнопка экрана разрешений. Пока есть что спросить,
//  кнопка спрашивает; когда окон iOS больше не будет, а геолокации нет,
//  ведёт в Настройки; всё решено — дальше.
//
//  Чистая логика — покрыто OnboardingPermissionsTests.
//

import Foundation

nonisolated enum OnboardingPermissions {

    enum Primary: Equatable {
        case ask, openSettings, next
    }

    static func primary(location: LocationAccessStep, notificationsAsked: Bool, motionPending: Bool) -> Primary {
        if location == .askWhenInUse || location == .askAlways || !notificationsAsked || motionPending {
            return .ask
        }
        return location == .done ? .next : .openSettings
    }
}
