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
                       tint: Theme.Types.radar, action: onRadar)
                action("Своя камера", "plus.viewfinder",
                       tint: Theme.textPrimary, action: onOwnCamera)
            }
        }
        .padding(12)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
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

/// Пикер типа отметки: что впереди — радар, тренога, пост ДПС или ДТП.
/// Больше типов → живее карта: этим живут Waze и водительские чаты.
struct ReportPickerBar: View {
    let onPick: (ReportKind) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Что впереди?", systemImage: "eye.fill")
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
                ForEach(ReportKind.allCases) { kind in
                    Button {
                        onPick(kind)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbol).font(.rounded(18, .semibold))
                            Text(kind.title)
                                .font(.rounded(10, .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(kind.cameraType.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.surface.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(12)
        .backport.glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerLarge))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
