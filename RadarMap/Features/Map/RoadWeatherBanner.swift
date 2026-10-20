//
//  RoadWeatherBanner.swift
//  RadarMap
//
//  «Перевал Камчик — туман, через 32 км» — карточка над картой на телефоне.
//
//  Голос сказал одну фразу (RoadWeatherService → LocationService), карточка
//  повторяет её словами на `roadWeatherBannerSeconds` и гаснет сама; крестик
//  — раньше. То же предупреждение в машине — баннером CarPlay в общей очереди
//  (ниже камеры и объезда). Ничего не просит сделать: ехать ли через перевал,
//  решает водитель.
//

import SwiftUI

struct RoadWeatherBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let banner = env.roadWeather.banner {
            let notice = banner.notice
            SolidPanel {
                HStack(spacing: 12) {
                    IconBadge(symbol: notice.symbol, tint: Theme.warning, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: notice.title)
                            .font(.rounded(17, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(verbatim: notice.subtitle)
                            .font(.rounded(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        env.roadWeather.hideBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.rounded(14, .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .tapTarget()
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text("Закрыть"))
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .padding(.trailing, 4)
            }
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(banner.id)
        }
    }
}
