//
//  SpeedLimitSign.swift
//  RadarMap
//
//  Дорожный знак ограничения скорости (белый круг, красная обводка).
//  Один источник правды: рисовался в 4 местах — HUD, деталка, карта проезда, CarPlay.
//

import SwiftUI

struct SpeedLimitSign: View {
    let limit: Int
    var diameter: CGFloat = 42

    /// Толщина обводки и кегль подписи масштабируются от диаметра —
    /// знак одинаково читается и в HUD (42), и в карточке проезда (44).
    private var borderWidth: CGFloat { diameter * 0.107 }
    private var fontSize: CGFloat { diameter * (limit >= 100 ? 0.31 : 0.38) }

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(Color(red: 0.85, green: 0.05, blue: 0.1), lineWidth: borderWidth)
            Text("\(limit)")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .contentTransition(.numericText())
        }
        .frame(width: diameter, height: diameter)
    }
}
