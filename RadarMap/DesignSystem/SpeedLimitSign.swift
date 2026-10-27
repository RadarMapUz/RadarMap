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
    /// Лимит предположен по классу дороги, а не взят из OSM. Рисуем пунктиром
    /// и со знаком «≈»: цифра без пометки читается как факт, а это догадка,
    /// и водитель имеет право видеть разницу.
    var isAssumed = false
    /// Тень знака (в HUD — красное свечение при превышении). Ложится на
    /// КРУГ, а не на весь знак: `.shadow` снаружи давал свою тень каждой
    /// цифре и пересчитывался над живой картой каждый кадр (4.3).
    var glow: Color? = nil
    var glowRadius: CGFloat = 3

    /// Толщина обводки и кегль подписи масштабируются от диаметра —
    /// знак одинаково читается и в HUD (42), и в карточке проезда (44).
    private var borderWidth: CGFloat { diameter * 0.107 }
    private var fontSize: CGFloat { diameter * (limit >= 100 ? 0.31 : 0.38) }

    var body: some View {
        ZStack {
            Circle().fill(.white)
                .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : glowRadius)
            Circle()
                .strokeBorder(Theme.signRed,
                              style: StrokeStyle(lineWidth: borderWidth,
                                                 dash: isAssumed ? [diameter * 0.14] : []))
            Text(isAssumed ? "≈\(limit)" : "\(limit)")
                .font(.system(size: isAssumed ? fontSize * 0.82 : fontSize,
                              weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .contentTransition(.numericText())
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(isAssumed
            ? Text(String(format: String(localized: "Предположительно %lld"), limit))
            : Text(String(format: String(localized: "Лимит %lld"), limit)))
    }
}
