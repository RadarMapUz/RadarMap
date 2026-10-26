//
//  MapScreen+HomeLab.swift
//  RadarMap
//
//  Этап 31: три варианта главного экрана без поездки (`-designHome A|B|C`).
//
//  Было: сверху крупная карточка «469 м до камеры» (на стоянке — столько же
//  места, сколько за рулём), снизу три разные формы друг над другом —
//  карточка «Домой», висящая над картой капсула «Начать поездку» и док из
//  четырёх кнопок. На SE низ занимал половину экрана, а подписи дока стояли
//  на разной высоте (значки разной высоты).
//
//  A «Один док»       — всё нижнее в одной панели: строка «Домой» сверху,
//                        ряд действий снизу, «Поездка» — пятой кнопкой.
//  B «Куда едем?»     — как Apple Maps / Яндекс: поле поиска главным, под
//                        ним чипы «Домой 39 мин» и «Мои места»; «Начать поездку» — в «…».
//  C «Карта главная»  — одна плавающая капсула поиска, «Домой» — чипом над
//                        ней, колонка справа — три кнопки вместо пяти.
//  Во всех трёх: на стоянке камера — компактный чип слева сверху; в
//  движении HUD прежний (скорость, лимит, камера).
//

import SwiftUI
import CoreLocation

extension MapScreen {

    /// Вариант главного экрана включён и сейчас главный экран «в покое».
    var homeLabActive: Bool { DesignLab.home != .base }

    /// «Начать поездку» — запасная (поездка начнётся сама): место в доке, а
    /// не отдельная капсула над картой. Главная (ручной старт) остаётся
    /// жёлтой кнопкой над доком.
    var labTripIsSecondary: Bool {
        TripStartPrompt.prominence(startsByItself: env.settings.tripStartMode.usesMotion) == .secondary
    }

    var labGuess: DestinationGuess? {
        guard env.settings.destinationSuggestions, !env.location.isTripActive,
              !env.route.isActive, env.mobile.passQuestion == nil else { return nil }
        return env.destinationGuess(now: Date())
    }

    // MARK: - Нижняя панель

    @ViewBuilder var homeLabDock: some View {
        switch DesignLab.home {
        case .a: homeDockA
        case .b: homeDockB
        case .c: homeDockC
        case .base: actionBar
        }
    }

    /// Жёлтая «Начать поездку» над доком — только при ручном старте.
    @ViewBuilder var labPrimaryTrip: some View {
        if !labTripIsSecondary { tripButtonPrimary }
    }

    // A — один док

    private var homeDockA: some View {
        VStack(spacing: 0) {
            if let guess = labGuess {
                Button { routeTo(guess) } label: { labSuggestionRow(guess) }
                    .buttonStyle(PressableStyle())
                Rectangle().fill(Theme.stroke).frame(height: 1)
                    .padding(.horizontal, 16)
            }
            HStack(alignment: .top, spacing: 0) {
                labDockButton("Поиск", "magnifyingglass") { map.showSearch = true }
                labDockButton("Мои места", Icon.myPlaces) { showMyPlaces = true }
                labDockButton("Итоги", "chart.bar.fill") { map.showStats = true }
                if labTripIsSecondary {
                    labDockButton("Поездка", "play.fill") { toggleTrip() }
                }
                Menu { moreActionItems } label: { LabDockLabel(title: "Ещё", icon: "ellipsis") }
                    .accessibilityLabel(Text("Ещё"))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    private func labSuggestionRow(_ guess: DestinationGuess) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: guess.kind.symbol,
                      tint: guess.kind == .work ? Theme.Icon.work : Theme.Icon.home, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(guess.kind.suggestionTitle)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(guess.subtitle)
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func labDockButton(_ title: LocalizedStringKey, _ icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) { LabDockLabel(title: title, icon: icon) }
            .buttonStyle(PressableStyle())
    }

    // B — «Куда едем?»

    private var homeDockB: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { map.showSearch = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.rounded(17, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Куда едем?")
                            .font(.rounded(17, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                labSquareButton("chart.bar.fill", label: "Итоги") { map.showStats = true }
                // Запасная «Начать поездку» — в «…»: третьим чипом она уходила
                // за край SE, а поездка и так начнётся сама.
                Menu {
                    if labTripIsSecondary {
                        Button { toggleTrip() } label: { Label("Начать поездку", systemImage: "play.fill") }
                    }
                    Section { moreActionItems }
                } label: { labSquareFace("ellipsis") }
                    .accessibilityLabel(Text("Ещё"))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let guess = labGuess {
                        labChip(guess.kind.symbol, guess.kind.suggestionTitle,
                                detail: guess.usual.map { Formatting.duration($0) },
                                prominent: true) { routeTo(guess) }
                    }
                    labChip(Icon.myPlaces, String(localized: "Мои места")) { showMyPlaces = true }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    private func labSquareFace(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.rounded(17, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 48, height: 48)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    private func labSquareButton(_ icon: String, label: LocalizedStringKey,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) { labSquareFace(icon) }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text(label))
    }

    private func labChip(_ icon: String, _ title: String, detail: String? = nil, prominent: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.rounded(12, .bold))
                Text(verbatim: title).font(.rounded(15, .semibold))
                if let detail {
                    Text(verbatim: detail)
                        .font(.rounded(15, .medium))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(prominent ? Theme.onAccentFill : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(prominent ? Theme.accentFill : Theme.background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    // C — «Карта главная»

    private var homeDockC: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let guess = labGuess {
                Button { routeTo(guess) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: guess.kind.symbol)
                            .font(.rounded(13, .bold))
                            .foregroundStyle(Theme.onAccentFill)
                            .frame(width: 28, height: 28)
                            .background(Theme.accentFill, in: Circle())
                        Text(guess.kind.suggestionTitle)
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        if let usual = guess.usual {
                            Text(verbatim: Formatting.duration(usual))
                                .font(.rounded(15, .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.rounded(12, .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.leading, 8).padding(.trailing, 14)
                    .frame(height: 44)
                    .liftedBackground(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            HStack(spacing: 6) {
                Button { map.showSearch = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.rounded(17, .semibold))
                        Text("Куда едем?")
                            .font(.rounded(17, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 18)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                Button { map.showStats = true } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.background, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text("Итоги"))
                Menu {
                    Button { showMyPlaces = true } label: { Label("Мои места", systemImage: Icon.myPlaces) }
                    if labTripIsSecondary {
                        Button { toggleTrip() } label: { Label("Начать поездку", systemImage: "play.fill") }
                    }
                    Section { moreActionItems }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.rounded(17, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.background, in: Circle())
                }
                .accessibilityLabel(Text("Ещё"))
                .padding(.trailing, 6)
            }
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
        }
    }

    private func routeTo(_ guess: DestinationGuess) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        buildRoute(to: guess.coordinate, name: guess.kind.title)
    }
}

/// Подпись кнопки дока варианта: значок в рамке ОДНОЙ высоты (у звезды и
/// лупы разные поля — подписи стояли на разной высоте) и подпись 12.
struct LabDockLabel: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.rounded(19, .semibold))
                .frame(height: 26)
            Text(title)
                .font(.rounded(12, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Камера на стоянке — компактный чип слева сверху (варианты главного
/// экрана). Та же монета и то же расстояние, что в HUD, но в 44 pt вместо
/// 76: стоя смотрят на карту, а не на прибор. В движении — прежний HUD.
struct LabIdleCameraChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let location = env.location
        if let camera = location.displayNearestCamera, let distance = location.displayDistanceToNearest {
            let radius = location.effectiveAlertRadius
            HStack(spacing: 8) {
                CameraCoinView(glyph: camera.kind.glyph,
                               fill: SpeedHUDView.proximityTint(distance, camera, radius: radius),
                               ink: SpeedHUDView.proximityGlyph(distance, camera, radius: radius),
                               side: 30, shadow: false)
                Text(verbatim: Formatting.distance(distance))
                    .font(.rounded(17, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                SpeedHUDView.caption(for: camera, location: location)
                    .font(.rounded(12, .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 7).padding(.trailing, 14)
            .frame(height: 44)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.success)
                Text("Камер рядом нет")
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.rounded(12, .semibold))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .liftedBackground(Theme.surface, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
