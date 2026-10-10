//
//  RoutePanel.swift
//  RadarMap
//
//  Панель активного маршрута: варианты, цель, время/расстояние, камеры по пути,
//  «Поехали». Плюс баннер манёвра (turn-by-turn). Панель поездки — TripLiveBar.swift.
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
                if let selected = route.selected, let why = Self.reason(selected, among: route.variants) {
                    Text(why)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .contentTransition(.opacity)
                }
            }

            GlassCard(cornerRadius: Theme.cornerLarge) {
                VStack(spacing: 12) {
                    // Куда едем + время/путь + закрыть
                    HStack(spacing: 12) {
                        Image(systemName: "flag.checkered")
                            .font(.rounded(16, .bold))
                            .foregroundStyle(Theme.onAccentFill)
                            .frame(width: 38, height: 38)
                            .background(Theme.accentFill, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.destinationName)
                                .font(.rounded(16, .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            // Заезд по пути — видно, что цель та же, а линия
                            // идёт через остановку.
                            if let stop = route.stop {
                                Label(String(format: String(localized: "через %@"), stop.name),
                                      systemImage: "mappin.circle.fill")
                                    .font(.rounded(12, .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .lineLimit(1)
                            }
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
                                .tapTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Сбросить маршрут"))
                    }

                    // В поездке панель заменяется компактной TripLiveBar — здесь всегда «до старта».
                    camerasButton

                    // Главное действие — жёлтое, как «Начать поездку» и «Радар!»:
                    // было зелёное (success), то есть цвет «в лимите» на кнопке
                    // старта, и третий облик одной и той же роли.
                    PrimaryButton(title: "Поехали", systemImage: "play.fill", action: onTripToggle)
                }
                .padding(14)
            }
        }
        .motionAnimation(.spring(duration: 0.3), value: route.selectedID)
        .motionAnimation(.spring(duration: 0.3), value: env.location.isTripActive)
    }

    // MARK: - Варианты маршрута

    private var variantChips: some View {
        // Строка ярлыка есть у всех плашек, если она есть хоть у одной, —
        // иначе плашки разной высоты прыгают.
        let labeled = env.route.variants.contains { !$0.assessment.labels.isEmpty }
        return HStack(spacing: 8) {
            ForEach(env.route.variants) { variant in
                variantChip(variant, labeled: labeled)
            }
        }
    }

    private func variantChip(_ variant: RouteService.Variant, labeled: Bool) -> some View {
        let isSelected = variant.id == env.route.selectedID
        return Button {
            env.route.selectVariant(variant.id)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(spacing: 3) {
                if labeled {
                    Text(variant.assessment.labels.first.map { Self.title($0, variant) } ?? " ")
                        .font(.rounded(11, .bold))
                        .foregroundStyle(isSelected ? Theme.background : Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
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

    // MARK: - Ярлыки вариантов (RouteChoice)

    static func title(_ label: RouteChoice.Label, _ variant: RouteService.Variant) -> String {
        switch label {
        case .familiar:        return String(localized: "Знакомый")
        case .fastest:         return String(localized: "Быстрый")
        case .fewerCameras:    return variant.cameras.isEmpty
                                   ? String(localized: "Без камер") : String(localized: "Меньше камер")
        case .avoidsOverspeed: return String(localized: "Спокойнее")
        case .simpler:         return String(localized: "Проще")
        case .shortest:        return String(localized: "Короткий")
        }
    }

    /// Почему вариант такой — одной строкой под плашками. Числа рядом с
    /// ярлыком: «Знакомый» без «поездок этим путём: 12» — просто слово.
    static func reason(_ variant: RouteService.Variant, among all: [RouteService.Variant]) -> String? {
        guard let fastest = all.min(by: { $0.travelTime < $1.travelTime }) else { return nil }
        let a = variant.assessment
        var parts: [String] = []
        for label in a.labels {
            switch label {
            case .familiar:
                parts.append(String(format: String(localized: "поездок этим путём: %lld"), a.familiarTrips))
            case .fewerCameras:
                parts.append(String(format: String(localized: "камер: %1$lld вместо %2$lld"),
                                    variant.cameras.count, fastest.cameras.count))
            case .avoidsOverspeed:
                parts.append(String(format: String(localized: "без камер, где вы превышали (на быстром: %lld)"),
                                    fastest.assessment.overspeedCameras))
            case .simpler:
                if let mine = a.hardManeuvers, let base = fastest.assessment.hardManeuvers {
                    parts.append(String(format: String(localized: "сложных манёвров: %1$lld вместо %2$lld"),
                                        mine, base))
                }
            case .shortest:
                parts.append(String(format: String(localized: "на %@ короче"),
                                    Formatting.distance(fastest.distance - variant.distance)))
            case .fastest:
                break
            }
        }
        let extra = variant.travelTime - fastest.travelTime
        if variant.id != fastest.id, extra >= 60 {
            parts.append(String(format: String(localized: "+%@ к быстрому"), Formatting.duration(extra)))
        }
        guard !parts.isEmpty else { return nil }
        let head = a.labels.first.map { title($0, variant) }
        return ([head].compactMap { $0 } + parts).joined(separator: " · ")
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

/// Баннер ближайшего манёвра (turn-by-turn) — крупно, читается боковым зрением.
struct ManeuverBanner: View {
    let step: RouteStep
    let distance: CLLocationDistance
    /// Скорость — только для того, когда показать ряд полос (на трассе раньше).
    var speedKmh: Double = 0
    /// Манёвр, для которого ряд полос уже показан: дальше он не прячется.
    /// Порог зависит от скорости, и на 68–72 км/ч между 600 и 1000 м ряд
    /// мигал бы — появился, исчез, появился.
    @State private var lanesShownFor: CLLocationDistance?
    /// Карточка манёвра — синяя заливка с белым текстом (вариант А, 10.10):
    /// главный предмет экрана в поездке, и он должен отделяться от белых
    /// панелей и от карты одним взглядом, как у Amap. Раньше это была ещё
    /// одна белая карточка среди белых карточек.
    private let fill = Theme.accentFill
    private let ink = Theme.onAccentFill

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(24, .bold))
                .foregroundStyle(ink)
                .frame(width: 52, height: 52)
                .background(ink.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                // Моноширинные цифры — как у приборки и CarPlay: дистанция
                // тает каждый тик, и без них баннер дрожал шириной.
                Text(Formatting.distance(distance))
                    .font(.rounded(30, .bold).monospacedDigit())
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance))
                Text(step.text)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.onAccentFillSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        if !step.lanes.isEmpty, step.lanes.count <= 8,
           step.lanes.contains(where: \.isValid),
           lanesShownFor == step.distanceAlong || distance <= LaneAdvice.showDistance(speedKmh: speedKmh) {
            Rectangle().fill(ink.opacity(0.22)).frame(height: 1)
            // Как у Amap: ряд полос — сама дорога, полосы разделены
            // разметкой, нужные — залиты белым, и над рядом словами,
            // в какой ряд встать: считать стрелки на ходу — лишний взгляд.
            VStack(spacing: 6) {
                if let advice = LaneAdvice.phrase(step.lanes) {
                    Text(advice)
                        .font(.rounded(15, .bold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    ForEach(Array(step.lanes.enumerated()), id: \.offset) { index, lane in
                        if index > 0 {
                            Rectangle()
                                .fill(ink.opacity(0.3))
                                .frame(width: 1.5)
                                .padding(.vertical, 6)
                        }
                        Image(systemName: lane.primaryArrow(for: step.kind).symbolName)
                            .font(.rounded(24, lane.isValid ? .heavy : .regular))
                            .foregroundStyle(lane.isValid ? fill : ink.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(lane.isValid ? ink : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.horizontal, 3)
                            .accessibilityLabel(Text("Полоса \(index + 1)"))
                            .accessibilityValue(lane.isValid ? Text("Подходит для манёвра") : Text("Не подходит для манёвра"))
                    }
                }
                .padding(4)
                .background(ink.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
        }
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .liftPanel()
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous).stroke(ink.opacity(0.12), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
        .onChange(of: distance <= LaneAdvice.showDistance(speedKmh: speedKmh), initial: true) { _, near in
            if near { lanesShownFor = step.distanceAlong }
        }
    }
}

/// Ограничение полос на перекрёстке, который проезжаем прямо: «через 200 м —
/// из левых рядов» и короткий ряд стрелок. Меньше баннера манёвра: это не
/// команда, а предупреждение не оказаться в ряду «только направо».
struct LaneNoticeBanner: View {
    let lanes: [LaneHint]
    let distance: CLLocationDistance

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .motionAnimation(.easeOut(duration: 0.3), value: Int(distance / 10))
                Text(LaneAdvice.phrase(lanes) ?? String(localized: "Ряд для проезда прямо"))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    Image(systemName: lane.primaryArrow(for: .straight).symbolName)
                        .font(.rounded(16, lane.isValid ? .heavy : .regular))
                        .foregroundStyle(lane.isValid ? Theme.onAccentFill : Theme.textTertiary)
                        .frame(width: 26, height: 28)
                        .background(lane.isValid ? Theme.accentFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel(Text("Полоса \(index + 1)"))
                        .accessibilityValue(lane.isValid ? Text("Подходит для манёвра") : Text("Не подходит для манёвра"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .liftPanel()
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
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
                            .foregroundStyle(item.camera.kind.glyphTint)
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
            .background(Theme.screenBackground)
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
