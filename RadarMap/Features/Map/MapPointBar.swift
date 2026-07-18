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

/// Сплит-капсула «Домой | На работу» над кнопкой поездки: одной ширины с ней —
/// нижний блок читается единой колонкой, а не россыпью кнопок. Слот пуст —
/// половинка приглушена и предлагает задать адрес (иначе про «Мои места»
/// в недрах Настроек никто не узнаёт, и «Куда» в CarPlay остаётся пустым).
struct PlaceSplitBar: View {
    @Environment(AppEnvironment.self) private var env
    let onRoute: (CLLocationCoordinate2D, String) -> Void
    let onAssign: (PlaceSlot) -> Void

    var body: some View {
        HStack(spacing: 0) {
            half(.home)
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1, height: 24)
            half(.work)
        }
        .frame(height: 46)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder private func half(_ slot: PlaceSlot) -> some View {
        let place = env.settings.place(for: slot)
        let noGPS = env.location.currentCoordinate == nil
        Button {
            if let place { onRoute(place.coordinate, slot.name) } else { onAssign(slot) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: slot.symbol)
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(place == nil ? Theme.textTertiary : Theme.accent)
                Text(title(slot, assigned: place != nil))
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(place == nil ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        // Задано, но геопозиции нет — маршрут строить не из чего.
        .opacity(place != nil && noGPS ? 0.4 : 1)
        .disabled(place != nil && noGPS)
        .contextMenu {
            Button { onAssign(slot) } label: {
                Label("Изменить адрес", systemImage: "pencil")
            }
        }
    }

    private func title(_ slot: PlaceSlot, assigned: Bool) -> LocalizedStringKey {
        switch (slot, assigned) {
        case (.home, true):  return "Домой"
        case (.home, false): return "Задать дом"
        case (.work, true):  return "На работу"
        case (.work, false): return "Задать работу"
        }
    }
}
