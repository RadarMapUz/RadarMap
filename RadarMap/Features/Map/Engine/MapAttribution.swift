//
//  MapAttribution.swift
//  RadarMap
//
//  Подпись данных карты: «© OpenStreetMap» — пять секунд и тает.
//
//  Раньше на телефоне внизу висела кнопка «ⓘ» MapLibre — у края нижней
//  панели, наполовину под ней («убери, висит», владелец, 12.10), а в машине
//  подпись стояла всё время. Правила OSMF (Attribution Guidelines) прямо
//  разрешают иначе: подпись в углу карты при показе, затем свернуть «после
//  пяти секунд» или при касании карты, — если лицензию можно найти, когда
//  ищешь. Её находят в настройках («© участники OpenStreetMap»). Название и
//  логотип MapLibre на карте лицензия движка (BSD) не требует.
//

import SwiftUI

struct MapAttribution: View {
    @State private var shown = true

    var body: some View {
        Text(verbatim: "© OpenStreetMap")
            .font(.rounded(10, .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.background.opacity(0.6), in: Capsule())
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(!shown)
            .task {
                await Task.pause(seconds: AppConfig.mapAttributionSeconds)
                withMotion(.easeOut(duration: 0.6)) { shown = false }
            }
    }
}
