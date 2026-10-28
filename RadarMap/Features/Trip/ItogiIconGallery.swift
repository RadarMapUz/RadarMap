//
//  ItogiIconGallery.swift
//  RadarMap
//
//  DEBUG: сетка всех значков «Итогов» одним листом (`-itogiIcons`) — для
//  проверки одной толщины, одной плашки и цвета днём и ночью. В релиз не
//  попадает.
//

#if DEBUG
import SwiftUI

struct ItogiIconGallery: View {
    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Icon.itogiSymbols, id: \.self) { name in
                    VStack(spacing: 4) {
                        IconBadge(symbol: name, tint: tint(name), size: 30)
                        Text(verbatim: name)
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(height: 22, alignment: .top)
                    }
                }
            }
            .padding(16)
            .statCard(padding: 0)
            .padding(12)
        }
        .background(Theme.background)
    }

    /// Цвет — по тем же правилам, что на экранах: камера красная, остальное нейтральное.
    private func tint(_ name: String) -> Color {
        name == Icon.cameras ? Theme.Icon.camera : Theme.textSecondary
    }
}
#endif
