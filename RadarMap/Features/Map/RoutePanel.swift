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
                        .accessibilityLabel(Text("Сбросить маршрут"))
                    }

                    // В поездке панель заменяется компактной TripLiveBar — здесь всегда «до старта».
                    camerasButton

                    Button(action: onTripToggle) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                            Text("Поехали")
                        }
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.success,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    }
                }
                .padding(14)
            }
        }
        .motionAnimation(.spring(duration: 0.3), value: route.selectedID)
        .motionAnimation(.spring(duration: 0.3), value: env.location.isTripActive)
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
            .padding(.vertical, 10)
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
                    .foregroundStyle(route.camerasOnRoute.isEmpty ? Theme.success : Theme.Types.camera)
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

}

/// Компактная панель поездки: максимум карты, минимум панели.
/// С маршрутом — время прибытия и остаток; без — таймер и путь. Справа — стоп.
struct TripLiveBar: View {
    @Environment(AppEnvironment.self) private var env
    let onShowCameras: () -> Void
    let onStop: () -> Void

    var body: some View {
        let route = env.route
        HStack(spacing: 12) {
            if route.isActive {
                // Прибытие: как в настоящих навигаторах — время на часах + остаток.
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.arrivalDate, style: .time)
                        .font(.rounded(22, .heavy))
                        .foregroundStyle(Theme.success)
                        .contentTransition(.numericText())
                    Text("\(Formatting.duration(route.remainingTime)) · \(Formatting.distance(route.remainingDistance))")
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
                if env.settings.showNextCamera, let next = route.nextCamera {
                    Button(action: onShowCameras) {
                        HStack(spacing: 6) {
                            Image(systemName: next.camera.kind.symbolName)
                                .font(.rounded(11, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(next.camera.kind.tint.gradient, in: Circle())
                            Text(Formatting.distance(route.nextCameraDistance))
                                .font(.rounded(13, .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Камеры на маршруте"))
                    .accessibilityValue(Text(Formatting.distance(route.nextCameraDistance)))
                }
            } else {
                // Свободная поездка без маршрута: таймер + путь.
                VStack(alignment: .leading, spacing: 1) {
                    if let started = env.trip.startedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.rounded(20, .heavy).monospacedDigit())
                            .foregroundStyle(Theme.success)
                    }
                    // Эмодзи-камера рендерилась чёрно-белым глифом и выбивалась
                    // из всего интерфейса — здесь тот же SF Symbol, что везде.
                    HStack(spacing: 4) {
                        Text(Formatting.distance(env.trip.distanceMeters))
                            .contentTransition(.numericText())
                        Text("·")
                        Image(systemName: "camera.fill")
                            .font(.rounded(10, .semibold))
                        Text("\(env.trip.camerasPassed)")
                            .contentTransition(.numericText())
                    }
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            // Заряд — как на приборке: одна поездка, одни и те же цифры на
            // любом экране, включая живую дельту «−N».
            BatteryChip(sinceStartPercent: env.trip.startBatteryPercent)
            // «Радар!» слева от «стоп» — в поездке это самая частая кнопка
            // после самой остановки, и до неё палец должен доходить не глядя.
            // Она же крупнее соседки: промах между ними стоил поездки, и
            // разница в размере — второй признак, кроме цвета, который читается
            // боковым зрением.
            ReportRadarButton()
                .padding(.trailing, 6)
            StopTripButton(action: onStop)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Баннер ближайшего манёвра (turn-by-turn) — крупно, читается боковым зрением.
struct ManeuverBanner: View {
    let step: RouteStep
    let distance: CLLocationDistance
    private let jade = Color(red: 0.64, green: 0.88, blue: 0.71)

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 46, height: 46)
                .background(jade, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                // Моноширинные цифры — как у приборки и CarPlay: дистанция
                // тает каждый тик, и без них баннер дрожал шириной.
                Text(Formatting.distance(distance))
                    .font(.rounded(26, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                Text(step.text)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        if !step.lanes.isEmpty, step.lanes.count <= 8,
           step.lanes.contains(where: \.isValid), distance <= AppConfig.engineManeuverApproachMeters {
            Divider().overlay(Theme.stroke)
            HStack(spacing: 4) {
                ForEach(Array(step.lanes.enumerated()), id: \.offset) { index, lane in
                    Image(systemName: lane.primaryArrow(for: step.kind).symbolName)
                        .font(.rounded(20, lane.isValid ? .bold : .regular))
                        .foregroundStyle(lane.isValid ? jade : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(lane.isValid ? jade.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(Text("Полоса \(index + 1)"))
                        .accessibilityValue(lane.isValid ? Text("Подходит для манёвра") : Text("Не подходит для манёвра"))
                }
            }
            .padding(8)
        }
        }
        .background(Color(red: 0.075, green: 0.14, blue: 0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
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
