//
//  CarPlayHandoffView.swift
//  RadarMap
//
//  Экран телефона, пока едет CarPlay: чёрный фон вместо живой карты.
//
//  Пока водитель смотрит на экран машины, телефон зря рисовал карту со
//  всеми маркерами — тот же дорогой рендер, только в держателе и без
//  зрителя. Картинка в машину стримится с телефона, так что карта на двух
//  экранах — двойной нагрев ровно там, где солнце. Так делают все большие
//  навигаторы: телефон показывает заставку, машина — карту.
//
//  Чёрный фон — осознанно (OLED не светит чёрным), и поэтому тема здесь
//  ЗАКРЕПЛЕНА тёмной: до 12.10 фон был чёрным, а цвета брались из темы
//  приложения, днём светлой, — тёмно-синий заголовок на чёрном и серая
//  кнопка на сером, которую не прочесть («сделай нормально», владелец).
//  Значок — машина на связи, а не две машины с восклицательным знаком: тот читался
//  как «авария».
//
//  Карточка состояния — для взгляда мельком и для пассажира: прибытие по
//  маршруту, ближайшая камера, время и путь в поездке — каждое число с
//  подписью («33:35 · 0 м» без подписи было загадкой). Пер-тиковые числа —
//  в отдельных листьях и только на экране: в кармане фиксы их не будят.
//
//  Кнопка возврата — для пассажира: настройки, поиск и Итоги живут на
//  телефоне. Выбор действует до отключения CarPlay.
//

import SwiftUI

struct CarPlayHandoffView: View {
    @Environment(AppEnvironment.self) private var env
    /// «Открыть карту на телефоне» — до конца сессии CarPlay (сбрасывает RootView).
    var onShowMap: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.16))
                        .frame(width: 92, height: 92)
                    Image(systemName: "car.front.waves.up.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 22)

                Text("Едем в CarPlay")
                    .font(.rounded(28, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("Карта и предупреждения — на экране машины.\nТелефон отдыхает и не греется.")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                HandoffStatus()
                    .padding(.top, 28)

                Spacer()

                Button(action: onShowMap) {
                    Label("Открыть карту на телефоне", systemImage: "iphone")
                        .font(.rounded(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: 340)
                        .padding(.vertical, 15)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        // Тёмная тема — у самой поверхности: фон чёрный всегда.
        .environment(\.colorScheme, .dark)
        // Экран передачи обязан ДАВАТЬ телефону гаснуть: дисплей — крупнейший
        // потребитель, и прибитый чёрный экран за «телефон отдыхает» — обман.
        // Возврат на карту при живой поездке возвращает прежнее правило.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = false }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled =
                env.location.isTripActive && env.settings.keepScreenOn
        }
    }
}

/// Карточка состояния поездки: прибытие, камера, время и путь.
private struct HandoffStatus: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            if env.location.isTripActive {
                if env.route.isActive {
                    HandoffArrival()
                    divider
                }
                HandoffCamera()
                divider
                if let started = env.trip.startedAt {
                    row(symbol: "clock.fill", tint: Theme.success) {
                        HStack(spacing: 6) {
                            Text("В пути")
                                .foregroundStyle(Theme.textSecondary)
                            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                                .font(.rounded(17, .heavy).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                            HandoffDistance()
                        }
                    }
                }
            } else {
                row(symbol: "car.fill", tint: Theme.accent) {
                    Text(env.settings.tripStartMode.usesMotion
                         ? String(localized: "Поездка начнётся сама, когда тронетесь")
                         : String(localized: "Начните поездку кнопкой на экране машины"))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.rounded(15, .semibold))
        .frame(maxWidth: 340)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 60)
    }
}

/// Строка карточки: значок в плашке и содержимое.
private func row<Content: View>(symbol: String, tint: Color,
                                @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) {
        IconBadge(symbol: symbol, tint: tint, size: 34)
        content()
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
}

/// Прибытие по маршруту — отдельным листом: оценка меняется с каждым фиксом.
private struct HandoffArrival: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        row(symbol: "flag.checkered", tint: Theme.success) {
            if scenePhase != .background {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: String(localized: "Прибытие в %@"),
                                env.route.arrivalDate.formatted(date: .omitted, time: .shortened)))
                        .foregroundStyle(Theme.textPrimary)
                    Text([env.route.destinationName, Formatting.duration(env.route.remainingTime)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Ближайшая камера — то же правило, что у дока в машине
/// (`carPlayNearestCameraMeters`).
private struct HandoffCamera: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let camera = env.location.displayNearestCamera, let distance = env.location.displayDistanceToNearest,
           distance <= AppConfig.carPlayNearestCameraMeters {
            row(symbol: camera.kind.symbolName,
                tint: env.location.isApproachingCamera ? Theme.danger : Theme.Types.camera) {
                if scenePhase != .background {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: String(localized: "%1$@ через %2$@"),
                                    camera.kind.shortName, Formatting.distance(distance)))
                            .foregroundStyle(Theme.textPrimary)
                            .liveNumber()
                        Text("Голос предупредит заранее")
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        } else {
            row(symbol: "checkmark.shield.fill", tint: Theme.success) {
                Text("Камер рядом нет")
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

/// Пробег поездки — отдельным листом. Он читает километраж, который пишется
/// каждым фиксом; в корне экрана это пересобирало весь экран передачи на
/// каждом фиксе всю CarPlay-поездку, в том числе с телефоном в кармане
/// (аудит 11.10). В фоне лист пуст — фиксы его не будят.
private struct HandoffDistance: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if scenePhase != .background {
            Text(Formatting.distance(env.trip.distanceMeters))
                .font(.rounded(15, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .liveNumber()
        }
    }
}
