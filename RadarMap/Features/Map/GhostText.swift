//
//  GhostText.swift
//  RadarMap
//
//  Слова призрака дороги на работу (8.8.3, 8.8.3б) — одни на панели
//  поездки, в доке и на плитке CarPlay и на плашке Live Activity: «Работа ·
//  +4 мин к обычному», «… · впритык», «… · на 3 мин позже 9:00». Без «быстрее
//  обычного»: призрак не секундомер.
//

import SwiftUI

enum GhostText {
    /// «Работа · как обычно» — место и хвост.
    static func caption(_ ghost: CommuteLiveService.Display) -> String {
        let place = ghost.direction == .toWork ? String(localized: "Работа") : String(localized: "Дом")
        return "\(place) · \(tail(ghost))"
    }

    /// Хвост без места — для тесных мест (плитка CarPlay). Почему дольше —
    /// одним словом через точку (8.8.12): «+6 мин к обычному · пробка».
    /// Ранний прогноз (24.3, до 1,5 км) — с вилкой: «как обычно · ± 3 мин».
    static func tail(_ ghost: CommuteLiveService.Display) -> String {
        var base = core(ghost)
        if let spread = ghost.spreadMinutes {
            base += " · " + String(localized: "± \(spread) мин")
        }
        guard let reason = ghost.reason, ghost.deltaMinutes >= 1 || ghost.slack?.shown == .late else { return base }
        switch reason {
        case .jam:      return "\(base) · " + String(localized: "пробка")
        case .jamAhead: return "\(base) · " + String(localized: "пробка впереди")
        case .stood:    return "\(base) · " + String(localized: "стояли")
        }
    }

    private static func core(_ ghost: CommuteLiveService.Display) -> String {
        if let slack = ghost.slack {
            switch slack.shown {
            case .comfortable where slack.minutes >= 60: return String(localized: "с запасом больше часа")
            case .comfortable: return String(localized: "с запасом \(slack.minutes) мин")
            case .tight: return String(localized: "впритык")
            case .late:
                return String(localized: "на \(slack.lateMinutes) мин позже \(CommuteGhost.clock(slack.deadline))")
            }
        }
        return ghost.deltaMinutes >= 1
            ? String(localized: "+\(ghost.deltaMinutes) мин к обычному")
            : String(localized: "как обычно")
    }

    /// Хвост с заглавной — заголовок плашки: «На 7 мин позже 9:00».
    static func headline(_ ghost: CommuteLiveService.Display) -> String {
        let tail = tail(ghost)
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    /// Подпись тревожная: позже срока, впритык или заметно дольше обычного.
    static func isAlert(_ ghost: CommuteLiveService.Display) -> Bool {
        switch ghost.slack?.shown {
        case .late, .tight: return true
        case .comfortable: return false
        case nil: return ghost.deltaMinutes >= AppConfig.commuteGhostLateMinutes
        }
    }

    /// Цвет — второй признак, смысл в словах: со сроком — по запасу, без него —
    /// жёлтый только на заметной задержке.
    static func tint(_ ghost: CommuteLiveService.Display) -> Color {
        switch ghost.slack?.shown {
        case .late: return Theme.danger
        case .tight: return Theme.warning
        case .comfortable: return Theme.textSecondary
        case nil: return ghost.deltaMinutes >= AppConfig.commuteGhostLateMinutes ? Theme.warning : Theme.textSecondary
        }
    }

    /// Символ места — портфель или дом.
    static func symbol(_ ghost: CommuteLiveService.Display) -> String {
        ghost.direction == .toWork ? "briefcase.fill" : "house.fill"
    }
}
