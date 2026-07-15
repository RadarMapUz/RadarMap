//
//  RoutePanel.swift
//  RadarMap
//
//  Панель активного маршрута: варианты, цель, время/расстояние, камеры по пути,
//  следующая камера в движении, «Поехали». Плюс баннер манёвра (turn-by-turn).
//

import SwiftUI
import CoreLocation

struct RoutePanel: View {
    @Environment(AppEnvironment.self) private var env
    let onShowCameras: () -> Void
    let onTripToggle: () -> Void

    var body: some View {
        let route = env.route
        VStack(spacing: 10) {
            // Выбор варианта — только пока стоим и есть из чего выбирать.
            if route.variants.count > 1, !env.location.isTripActive {
                variantChips
            }

            GlassCard(cornerRadius: Theme.cornerLarge) {
                VStack(spacing: 12) {
                    // Куда едем + время/путь + закрыть
                    HStack(spacing: 12) {
                        Image(systemName: "flag.checkered")
                            .font(.rounded(16, .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 38, height: 38)
                            .background(Theme.accent.gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.destinationName)
                                .font(.rounded(16, .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(route.etaText) · \(route.distanceText)")
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .contentTransition(.numericText())
                        }
                        Spacer(minLength: 8)
                        Button {
                            route.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.rounded(22))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    if env.location.isTripActive, env.settings.showNextCamera {
                        nextCameraRow
                    } else {
                        camerasButton
                    }

                    // Поехали / Завершить
                    Button(action: onTripToggle) {
                        HStack(spacing: 10) {
                            Image(systemName: env.location.isTripActive ? "stop.fill" : "play.fill")
                            Text(env.location.isTripActive ? "Завершить поездку" : "Поехали")
                        }
                        .font(.rounded(17, .bold))
                        .foregroundStyle(env.location.isTripActive ? .white : Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(env.location.isTripActive ? Theme.danger : Theme.success,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    }
                }
                .padding(14)
            }
        }
        .animation(.spring(duration: 0.3), value: route.selectedID)
        .animation(.spring(duration: 0.3), value: env.location.isTripActive)
    }

    // MARK: - Варианты маршрута

    private var variantChips: some View {
        HStack(spacing: 8) {
            ForEach(env.route.variants) { variant in
                variantChip(variant)
            }
        }
    }

    private func variantChip(_ variant: RouteService.Variant) -> some View {
        let isSelected = variant.id == env.route.selectedID
        return Button {
            env.route.selectVariant(variant.id)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 3) {
                Text(variant.etaText)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(isSelected ? Theme.background : Theme.textPrimary)
                HStack(spacing: 4) {
                    Text(variant.distanceText)
                    Image(systemName: "camera.fill").font(.rounded(9))
                    Text("\(variant.cameras.count)")
                }
                .font(.rounded(11, .medium))
                .foregroundStyle(isSelected ? Theme.background.opacity(0.75) : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isSelected ? AnyShapeStyle(Theme.accent.gradient)
                                   : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(isSelected ? .clear : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Камеры

    private var camerasButton: some View {
        let route = env.route
        return Button(action: onShowCameras) {
            HStack(spacing: 10) {
                Image(systemName: "camera.metering.center.weighted")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(route.camerasOnRoute.isEmpty ? Theme.success : Theme.camera)
                Text("\(route.camerasOnRoute.count) камер на маршруте")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !route.camerasOnRoute.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
        .disabled(route.camerasOnRoute.isEmpty)
    }

    /// В движении: живая строка «следующая камера через X».
    @ViewBuilder private var nextCameraRow: some View {
        let route = env.route
        if let next = route.nextCamera {
            Button(action: onShowCameras) {
                HStack(spacing: 10) {
                    Image(systemName: next.camera.kind.symbolName)
                        .font(.rounded(13, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(next.camera.kind.tint.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: String(localized: "Камера через %@"),
                                    Formatting.distance(route.nextCameraDistance)))
                            .font(.rounded(14, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText())
                        Text(next.camera.kind.displayName)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text("\(route.camerasOnRoute.filter { $0.distanceAlong > route.progressAlong }.count)")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.stroke, in: Capsule())
                }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.success)
                Text("Камер впереди нет")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
    }
}

/// Баннер ближайшего манёвра (turn-by-turn) — крупно, читается боковым зрением.
struct ManeuverBanner: View {
    let step: RouteStep
    let distance: CLLocationDistance

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 46, height: 46)
                .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(20, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(step.text)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Список камер вдоль маршрута — по порядку следования.
struct RouteCamerasSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Camera) -> Void

    var body: some View {
        NavigationStack {
            List(Array(env.route.camerasOnRoute.enumerated()), id: \.element.id) { index, item in
                Button {
                    onSelect(item.camera)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.rounded(13, .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24)
                        Image(systemName: item.camera.kind.symbolName)
                            .font(.rounded(13, .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(item.camera.kind.tint.gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.camera.displayTitle)
                                .font(.rounded(14, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(Formatting.distance(item.distanceAlong)) от старта")
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.stroke)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Камеры на маршруте")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
