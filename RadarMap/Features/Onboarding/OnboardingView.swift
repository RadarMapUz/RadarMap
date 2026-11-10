//
//  OnboardingView.swift
//  RadarMap
//
//  Первый запуск — три экрана: зачем это нужно, разрешения одной кнопкой,
//  два выбора (OnboardingSetup.swift). Раньше страниц было четыре, главная
//  кнопка называлась «Начать» и вела мимо геолокации, а «Разрешить» была
//  мелкой в строке: человек попадал на карту без оповещений и не понимал,
//  почему.
//

import SwiftUI
import CoreLocation
import CoreMotion
import UIKit
import UserNotifications

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    @State private var page = Self.startPage
    private let permissionsIndex = 1
    private let lastPage = 2

    private enum Row { case location, notifications, motion }
    /// Какое окно iOS сейчас открыто; nil — цепочка не идёт.
    @State private var asking: Row?
    /// Для ожидания окон геолокации: `scenePhase` из захваченной вью устарел бы.
    @State private var isActive = true
    @State private var lastInactive = Date.distantPast
    @State private var rowsShown = false
    @Namespace private var languageCapsule

    /// DEBUG `-onboardingPage N` — открыть страницу на снимок.
    private static var startPage: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-onboardingPage"), i + 1 < args.count, let n = Int(args[i + 1]) {
            return max(0, min(2, n))
        }
        #endif
        return 0
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Размер экрана онбординга: низкий (SE) ужимает картинку.
    @State private var screen: CGSize = .zero
    private var isCompactHeight: Bool { screen.height > 0 && screen.height < 700 }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    permissionsPage.tag(1)
                    scrollingPage { OnboardingSetupPage(playing: page == 2) }.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Прокручиваемая страница не рисуется под точками и кнопкой:
                // на SE с крупным шрифтом нижняя строка ложилась на точки (12в F1).
                .clipped()
                .motionAnimation(Motion.standard, value: page)

                pageDots
                    .padding(.top, 12)
                    .padding(.bottom, 18)

                bottomActions
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                Color.clear.frame(height: 12)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        // Подписи — выбранным языком сразу: остальное приложение перейдёт на
        // него при следующем запуске.
        .environment(\.locale, Locale(identifier: env.settings.appLanguage.mapCode))
        .task {
            await refreshPermissions()
            withMotion(.easeOut(duration: 0.45).delay(0.15)) { rowsShown = true }
        }
        // Вернулись из Настроек iOS: кнопка должна сразу показать новое состояние.
        .onChange(of: scenePhase) { _, phase in
            isActive = phase == .active
            if phase == .active {
                Task { await refreshPermissions() }
            } else {
                lastInactive = Date()
            }
        }
        .overlay(alignment: .topTrailing) {
            if page == 0 {
                languageSwitch
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: grantedCount) { old, new in new > old }
    }

    private func refreshPermissions() async {
        env.motion.refreshAuthorization()
        await env.notifications.refreshStatus()
    }

    // MARK: - Цепочка окон iOS

    /// Одно нажатие — все окна по очереди: геолокация (iOS спросит дважды),
    /// уведомления, движение. Отказ в одном не останавливает остальные.
    private func runPermissions() async {
        guard asking == nil else { return }
        if env.location.accessStep == .askWhenInUse || env.location.accessStep == .askAlways {
            withMotion(Motion.standard) { asking = .location }
            env.location.takeAccessStep()
            await waitForLocationDialogs()
        }
        if env.notifications.authorizationStatus == .notDetermined {
            withMotion(Motion.standard) { asking = .notifications }
            _ = await env.notifications.requestAuthorizationResult()
        }
        if motionPending {
            withMotion(Motion.standard) { asking = .motion }
            await env.motion.requestAuthorizationResult()
        }
        withMotion(Motion.standard) { asking = nil }
        if primary == .next {
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            if page == permissionsIndex { withMotion(Motion.standard) { page += 1 } }
        }
    }

    /// У окон геолокации нет ответа «закрыто», а второе («Всегда») iOS
    /// показывает сама вслед за первым. Закрытыми считаем их, когда приложение
    /// снова активно секунду подряд; 2 минуты — предел на забытое окно.
    private func waitForLocationDialogs() async {
        let start = Date()
        lastInactive = start
        while Date().timeIntervalSince(start) < 120 {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            if isActive, Date().timeIntervalSince(lastInactive) >= 1 { return }
        }
    }

    // MARK: - Кнопки внизу

    private var motionRelevant: Bool { MotionService.isAvailable && env.settings.tripStartMode.usesMotion }
    private var motionPending: Bool { motionRelevant && env.motion.authorizationStatus == .notDetermined }

    private var primary: OnboardingPermissions.Primary {
        OnboardingPermissions.primary(location: env.location.accessStep,
                                      notificationsAsked: env.notifications.authorizationStatus != .notDetermined,
                                      motionPending: motionPending)
    }

    @ViewBuilder private var bottomActions: some View {
        switch page {
        case 0:
            PrimaryButton(title: "Продолжить", systemImage: "chevron.right") { go(to: 1) }
        case permissionsIndex:
            VStack(spacing: 4) {
                switch primary {
                case .ask:
                    PrimaryButton(title: "Разрешить", systemImage: "checkmark.shield.fill") {
                        Task { await runPermissions() }
                    }
                    .disabled(asking != nil)
                case .openSettings:
                    PrimaryButton(title: "Открыть Настройки", systemImage: "gearshape.fill") { openSystemSettings() }
                case .next:
                    PrimaryButton(title: "Далее", systemImage: "chevron.right") { go(to: lastPage) }
                }
                if primary != .next {
                    Button { go(to: lastPage) } label: {
                        Text("Позже")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(asking != nil)
                }
            }
        default:
            PrimaryButton(title: env.location.isAuthorized ? "Открыть карту" : "Продолжить без оповещений",
                          systemImage: "checkmark") { onFinish() }
        }
    }

    private func go(to index: Int) {
        withMotion(Motion.standard) { page = index }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Экран 1

    private var languageSwitch: some View {
        HStack(spacing: 2) {
            languageButton(.ru, "RU")
            languageButton(.uz, "UZ")
        }
        .padding(3)
        .background(Theme.quietFill, in: Capsule())
        .sensoryFeedback(.selection, trigger: env.settings.appLanguage)
    }

    private func languageButton(_ language: AppLanguage, _ title: String) -> some View {
        let isOn = env.settings.appLanguage.mapCode == language.mapCode
        return Button {
            withMotion(Motion.standard) { env.settings.appLanguage = language }
        } label: {
            Text(verbatim: title)
                .font(.dense(13, .bold))
                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 44, height: 36)
                .background {
                    if isOn {
                        Capsule().fill(Theme.surface).matchedGeometryEffect(id: "on", in: languageCapsule)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(verbatim: language.title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var welcomePage: some View {
        scrollingPage {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 52)
                CompactScene(scale: isCompactHeight ? 0.68 : 1) {
                    OnboardingRoadScene(playing: page == 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, isCompactHeight ? 16 : 24)
                Text("Предупредит о камере заранее")
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                VStack(spacing: 10) {
                    row(0, "speaker.wave.2.fill", "Голос за 22 секунды до камеры, с учётом скорости")
                    row(1, "moon.fill", "Работает с погашенным экраном и поверх Яндекса")
                    row(2, "car.fill", "Поездка начинается сама")
                }
                .padding(.horizontal, 24)
                Spacer(minLength: 8)
            }
        }
    }

    /// Строки входят по очереди: взгляд идёт сверху вниз вслед за ними.
    private func row(_ index: Int, _ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: icon, tint: Theme.accent, size: 34)
            Text(text)
                .font(.rounded(14, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .opacity(rowsShown ? 1 : 0)
        .offset(y: rowsShown || reduceMotion ? 0 : 10)
        .motionAnimation(.easeOut(duration: 0.45).delay(0.2 + Double(index) * 0.12), value: rowsShown)
    }

    // MARK: - Экран 2

    private var permissionsPage: some View {
        scrollingPage {
            VStack(alignment: .leading, spacing: 0) {
                Text(motionRelevant ? "Разрешите три вещи" : "Разрешите две вещи")
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                VStack(spacing: 10) {
                    permissionRow(.location, icon: "location.fill", title: "Геолокация «Всегда»",
                                  subtitle: "Иначе с погашенным экраном камеры молчат",
                                  footnote: accessHint, state: locationState)
                        .onboardingEntrance(index: 0, shown: page >= permissionsIndex)
                    permissionRow(.notifications, icon: "bell.badge.fill", title: "Уведомления",
                                  subtitle: "Сигнал о камере, когда поездка не идёт",
                                  state: notificationsState)
                        .onboardingEntrance(index: 1, shown: page >= permissionsIndex)
                    if motionRelevant {
                        permissionRow(.motion, icon: "figure.walk.motion", title: "Движение",
                                      subtitle: "Чтобы поездка начиналась сама", state: motionState)
                            .onboardingEntrance(index: 2, shown: page >= permissionsIndex)
                    }
                }
                .padding(.horizontal, 20)

                if locationWindowsAhead {
                    VStack(alignment: .leading, spacing: 8) {
                        OnboardingDialogGuide(playing: page == permissionsIndex)
                        Text("iOS спросит про геолокацию дважды. Выберите «При использовании», затем «Всегда». Переключатель «Точная» не выключайте.")
                            .font(.rounded(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity)
                }

                Label("История поездок, дом и работа остаются на этом iPhone.", systemImage: "lock.shield.fill")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                Spacer(minLength: 16)
            }
        }
    }

    private var locationWindowsAhead: Bool {
        env.location.accessStep == .askWhenInUse || env.location.accessStep == .askAlways
    }

    private var scrollingBottomFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        }
    }

    /// Страница, которая прокручивается, когда не влезает. Высота не меньше
    /// экрана: пока всё влезает, Spacer'ы по-прежнему центрируют страницу.
    private func scrollingPage(@ViewBuilder _ content: () -> some View) -> some View {
        let page = content()
        return GeometryReader { proxy in
            ScrollView {
                page
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask { scrollingBottomFade }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0...lastPage, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.accent : Theme.stroke)
                    .frame(width: index == page ? 22 : 7, height: 7)
            }
        }
        .motionAnimation(Motion.standard, value: page)
        // Точки — для глаза; VoiceOver слышит одну фразу «страница 2 из 3».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "Страница %lld из %lld"),
                                        page + 1, lastPage + 1)))
    }

    // MARK: - Состояния разрешений

    private enum PermState { case granted, partial, pending, blocked }

    private var grantedCount: Int {
        [locationState, notificationsState, motionRelevant ? motionState : .pending]
            .filter { $0 == .granted }.count
    }

    private var locationState: PermState {
        switch env.location.authorizationStatus {
        case .authorizedAlways: return .granted
        case .authorizedWhenInUse: return .partial
        case .denied, .restricted: return .blocked
        default: return .pending
        }
    }

    /// Что выбрать в Настройках: страница приложения открывается сразу, слова
    /// там системные.
    private var accessHint: LocalizedStringKey? {
        switch env.location.accessStep.hint {
        case .pickAlways: return "Геопозиция → Всегда"
        case .deviceLimited: return "Геолокация ограничена в настройках устройства"
        case nil: return nil
        }
    }

    private var notificationsState: PermState {
        switch env.notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .blocked
        default: return .pending
        }
    }

    private var motionState: PermState {
        switch env.motion.authorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .blocked
        default: return .pending
        }
    }

    private func permissionRow(_ row: Row, icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                               footnote: LocalizedStringKey? = nil, state: PermState) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: icon, tint: Theme.accent, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Label(footnote, systemImage: "gearshape.fill")
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            status(row, state)
        }
        .padding(12)
        .statCard(padding: 0)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(Theme.accent, lineWidth: 2)
                .opacity(asking == row ? 1 : 0)
        }
        .motionAnimation(Motion.standard, value: asking == row)
    }

    @ViewBuilder private func status(_ row: Row, _ state: PermState) -> some View {
        Group {
            if asking == row {
                ProgressView().controlSize(.small)
            } else {
                switch state {
                case .granted:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.success)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                case .partial:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.rounded(24))
                        .foregroundStyle(Theme.warning)
                case .blocked:
                    Button { openSystemSettings() } label: {
                        Text("Настройки")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.warning)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .frame(minHeight: Theme.controlSize)
                            .background(Theme.quietFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                case .pending:
                    Circle()
                        .stroke(Theme.stroke, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .motionAnimation(.spring(response: 0.35, dampingFraction: 0.6), value: state)
    }
}

/// Сцена онбординга в масштабе: место в раскладке — по настоящей высоте
/// сцены × масштаб (`scaleEffect` сам по себе места не освобождает).
private struct CompactScene<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .scaleEffect(scale, anchor: .top)
            .frame(height: height > 0 ? height * scale : nil, alignment: .top)
            .frame(maxWidth: .infinity)
    }
}
