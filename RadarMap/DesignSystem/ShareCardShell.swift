//
//  ShareCardShell.swift
//  RadarMap
//
//  Каркас шеринг-карточки (540×675, рендерится в 1080×1350): фирменная шапка
//  RadarMap, центральный контент, футер + метрики. Заполняют TripShareCard
//  (поездка) и StatsShareCard (итоги).
//

import SwiftUI

struct ShareCardShell<Content: View>: View {
    /// Подпись справа в шапке («дата» / «Мои итоги»).
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                Text("RadarMap")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)

            content

            Text("Карта камер и навигатор Узбекистана")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 14)
        }
        .frame(width: 540, height: 675)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accent.opacity(0.14), .clear],
                               center: .center, startRadius: 40, endRadius: 380)
            }
        )
    }
}

extension View {
    /// Полоса метрик шеринг-карточки на полупрозрачной подложке.
    func shareMetricsRow() -> some View {
        self.padding(.vertical, 20).background(.white.opacity(0.06))
    }

    /// Метрики скруглённой плиткой в полях карточки (материалы в ImageRenderer
    /// не рендерятся — только простые заливки).
    func shareMetricsTile() -> some View {
        self.padding(.vertical, 16)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 16)
    }
}
