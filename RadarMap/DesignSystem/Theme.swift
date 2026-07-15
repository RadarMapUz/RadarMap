//
//  Theme.swift
//  RadarMap
//
//  Дизайн-система: тёмная «радар-детектор» палитра, типографика, метрики.
//

import SwiftUI

enum Theme {
    // MARK: - Цвета
    static let accent        = Color(red: 0.235, green: 0.863, blue: 1.0)   // неоновый циан
    static let camera        = Color(red: 1.0,   green: 0.27,  blue: 0.38)  // красный — камера
    static let radar         = Color(red: 1.0,   green: 0.71,  blue: 0.15)  // янтарный — радар
    static let mobile        = Color(red: 0.72,  green: 0.45,  blue: 1.0)   // фиолетовый — передвижной
    static let intelligent   = Color(red: 0.35,  green: 0.52,  blue: 1.0)   // индиго — интеллектуал+радар
    static let danger        = Color(red: 1.0,   green: 0.27,  blue: 0.38)
    static let success       = Color(red: 0.22,  green: 0.9,   blue: 0.55)

    static let background    = Color(red: 0.02,  green: 0.04,  blue: 0.07)  // почти чёрный навигационный
    static let surface       = Color(red: 0.07,  green: 0.09,  blue: 0.14)
    static let stroke        = Color.white.opacity(0.10)

    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.38)

    // MARK: - Метрики
    static let cornerLarge: CGFloat  = 24
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat  = 12
}

// MARK: - Типографика (rounded — «приборный» вид)

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Цвет/иконка для типа камеры (UI-слой, модель остаётся без SwiftUI)

extension CameraType {
    var tint: Color {
        switch self {
        case .stationaryCamera: return Theme.camera
        case .stationaryRadar:  return Theme.radar
        case .intelligentRadar: return Theme.intelligent
        case .mobileRadar:      return Theme.mobile
        case .other:            return Theme.textSecondary
        }
    }
}
