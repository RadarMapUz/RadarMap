//
//  MapPointBar.swift
//  RadarMap
//
//  Долгий тап по карте: «поеду вот сюда» — базовый жест навигатора.
//  Glass-бар с действиями для выбранной точки + быстрые чипы Дом/Работа.
//

import SwiftUI
import CoreLocation

/// Точка, выбранная долгим тапом (Identifiable — для маркера на карте).
struct MapPoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: MapPoint, rhs: MapPoint) -> Bool { lhs.id == rhs.id }
}

/// Бар действий для точки: маршрут / передвижной радар / своя камера.
struct MapPointBar: View {
    /// nil — геопозиции нет, маршрут строить не из чего.
    let onRoute: (() -> Void)?
    let onRadar: () -> Void
    let onOwnCamera: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Точка на карте", systemImage: "mappin.and.ellipse")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.rounded(20))
                        .foregroundStyle(Theme.textTertiary)
                }
                .accessibilityLabel(Text("Закрыть"))
            }
            HStack(spacing: 8) {
                if let onRoute {
                    action("Маршрут сюда", "arrow.triangle.turn.up.right.circle.fill",
                           tint: Theme.accent, action: onRoute)
                }
                action("Радар здесь", "dot.radiowaves.left.and.right",
                       tint: Theme.radar, action: onRadar)
                action("Своя камера", "plus.viewfinder",
                       tint: Theme.textPrimary, action: onOwnCamera)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func action(_ title: LocalizedStringKey, _ icon: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.rounded(18, .semibold))
                Text(title)
                    .font(.rounded(10, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.surface.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
    }
}

/// Быстрые чипы «Дом»/«Работа» у панели действий: маршрут в один тап.
/// Слоты пусты — один чип-приглашение их задать (иначе про «Мои места»
/// в недрах Настроек никто не узнаёт, и список «Куда» в CarPlay пуст).
struct PlaceChips: View {
    @Environment(AppEnvironment.self) private var env
    let onRoute: (CLLocationCoordinate2D, String) -> Void
    let onAssign: (PlaceSlot) -> Void

    var body: some View {
        let home = env.settings.place(for: .home)
        let work = env.settings.place(for: .work)
        HStack(spacing: 8) {
            if home == nil && work == nil {
                chip(String(localized: "Задать Дом и Работу"), "house.fill") { onAssign(.home) }
            } else {
                if let home { placeChip(.home, home) }
                if let work { placeChip(.work, work) }
            }
        }
    }

    @ViewBuilder private func placeChip(_ slot: PlaceSlot, _ place: SavedPlace) -> some View {
        // Без геопозиции маршрут строить не из чего — чип не показываем
        // (мёртвая кнопка хуже отсутствия кнопки).
        if env.location.currentCoordinate != nil {
            chip(slot.name, slot.symbol) {
                onRoute(place.coordinate, slot.name)
            }
        }
    }

    private func chip(_ title: String, _ icon: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.rounded(12, .semibold))
                Text(title).font(.rounded(12, .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
