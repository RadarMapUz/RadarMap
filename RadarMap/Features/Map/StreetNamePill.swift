//
//  StreetNamePill.swift
//  RadarMap
//
//  Плашка «по какой улице едем» внизу по центру (29.F, как у Amap): имя
//  ленты под значком «я» (EngineStreetProbe → StreetPill). На карте само
//  имя улицы под машиной закрыто значком и линией маршрута, а плашка
//  читается одним взглядом.
//
//  Сплошная заливка, а не стекло: стекло над движущейся картой размывается
//  заново каждый кадр (аудит 11.10). Имя меняется раз в сотни метров —
//  своя маленькая вью, тело экрана с картой его не читает.
//

import SwiftUI

struct StreetNamePill: View {
    let name: String?
    /// Экран машины: крупнее (смотрят с 70–80 см).
    var large = false

    var body: some View {
        ZStack {
            if let name {
                Text(verbatim: name)
                    .font(.rounded(large ? 17 : 15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, large ? 16 : 14)
                    .padding(.vertical, large ? 8 : 7)
                    .liftedBackground(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.edgeControl, lineWidth: 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .id(name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Улица: \(name)"))
            }
        }
        .motionAnimation(Motion.standard, value: name)
        .allowsHitTesting(false)
    }
}

/// Телефон: имя из MapState — читается только здесь.
struct PhoneStreetNamePill: View {
    let map: MapState
    var body: some View { StreetNamePill(name: map.streetName) }
}
