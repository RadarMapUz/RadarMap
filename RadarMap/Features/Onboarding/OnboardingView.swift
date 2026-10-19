//
//  OnboardingView.swift
//  RadarMap
//
//  Первое впечатление: четыре страницы — дорога с камерой, голос, сообщество,
//  разрешения.
//
//  Переделано 13.10. Было семь страниц с одинаковыми синими кругами-иконками
//  и по четыре строки текста на каждой — это читали как инструкцию, а не как
//  обещание. Теперь каждая страница — одна картинка из самого приложения
//  (OnboardingScenes) и две-три строки под ней; про навигатор и Яндекс
//  сказано одной строкой, подробности — в «Помощи». Последняя страница —
//  два разрешения: без «Всегда» приложение не работает, и это единственное
//  место, где онбординг чего-то просит.
//

import SwiftUI
import CoreLocation
import UserNotifications

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    let onFinish: () -> Void

    @State private var page = Self.startPage
    private let lastPage = 3

    /// DEBUG `-onboardingPage N` — открыть страницу на снимок.
    private static var startPage: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-onboardingPage"), i + 1 < args.count, let n = Int(args[i + 1]) {
            return max(0, min(3, n))
        }
        #endif
        return 0
    }

    var body: some View {
        ZStack {
            Theme.screenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    roadPage.tag(0)
                    voicePage.tag(1)
                    communityPage.tag(2)
                    permissionsPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .motionAnimation(Motion.standard, value: page)

                pageDots
                    .padding(.bottom, 18)

                if page < lastPage {
                    PrimaryButton(title: "Далее", systemImage: "chevron.right") {
                        withMotion { page += 1 }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                } else {
                    PrimaryButton(title: "Начать", systemImage: "checkmark") { onFinish() }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Color.clear.frame(height: 12)
            }
        }
    }

    // MARK: - Страницы

    private var roadPage: some View {
        scenePage(title: "Предупредит о камере заранее",
                  subtitle: "3 400+ камер и радаров Узбекистана из официальных данных. Голос — за 22 секунды до камеры, с учётом скорости; работает со свёрнутым приложением и погасшим экраном.") {
            OnboardingRoadScene()
        } rows: {
            row("car.fill", "Сели за руль — поездка началась сама")
            row("map.fill", "Маршруты, лимиты и Итоги поездок — тоже здесь")
        }
    }

    private var voicePage: some View {
        scenePage(title: "Говорит только по делу",
                  subtitle: "В городе — коротко, на трассе — полностью. О камерах, которые вы проезжаете спокойно каждый день, молчит.") {
            OnboardingVoiceScene()
        } rows: {
            row("exclamationmark.triangle.fill", "Громко — только при превышении или внезапном радаре")
            row("square.2.layers.3d.top.filled", "Едете с Яндексом? Сверните RadarMap — голос останется")
        }
    }

    private var communityPage: some View {
        scenePage(title: "Треноги находим вместе",
                  subtitle: "Расписание передвижных радаров закрыто с 2022 года. Увидели засаду — одна жёлтая кнопка, не глядя на экран.") {
            OnboardingCommunityScene()
        } rows: {
            row("checkmark.seal.fill", "Отметку проверяет другой водитель; до проверки она с «?»")
            row("clock.arrow.circlepath", "Нажали случайно — «Отменить» рядом")
        }
    }

    private var permissionsPage: some View {
        scrollingPage {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Image(systemName: "checkmark.shield.fill")
                    .font(.rounded(44, .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 18)
                Text("Два разрешения — и в путь")
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 20)

                VStack(spacing: 12) {
                    permissionRow(
                        icon: "location.fill",
                        title: "Геолокация «Всегда»",
                        subtitle: "Предупреждаем о камерах, даже когда телефон в кармане, а приложение свёрнуто.",
                        state: locationState,
                        action: { env.location.bootstrap() }
                    )
                    permissionRow(
                        icon: "bell.badge.fill",
                        title: "Уведомления",
                        subtitle: "Звук и баннер при приближении к камере.",
                        state: notificationsState,
                        action: { env.notifications.requestAuthorization() }
                    )
                }
                .padding(.horizontal, 20)

                // Прайминг приватности: объясняем ДО системного диалога — больше доверия
                // и согласий, App Review видит обоснование фоновой геолокации.
                Label("История поездок, дом и работа хранятся только на этом iPhone. На сервер уходят запрос маршрута, ваши отметки и обезличенные отрезки для пробок — их можно выключить в Настройках.",
                      systemImage: "lock.shield.fill")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                Spacer(minLength: 24)
            }
        }
    }

    // MARK: - Компоненты

    /// Страница, которая прокручивается, когда не влезает. На SE с крупным
    /// шрифтом строки и карточки разрешений обрезались снизу, а прокрутить
    /// было нечем. Высота не меньше экрана: пока всё влезает, Spacer'ы
    /// по-прежнему центрируют страницу. «Далее» снаружи — закреплена.
    private func scrollingPage(@ViewBuilder _ content: () -> some View) -> some View {
        let page = content()
        return GeometryReader { proxy in
            ScrollView {
                page
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Картинка, заголовок, две-три строки.
    private func scenePage<Scene: View, Rows: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                                    @ViewBuilder scene: () -> Scene,
                                                    @ViewBuilder rows: () -> Rows) -> some View {
        scrollingPage {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 8)
                scene()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                Text(title)
                    .font(.rounded(26, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                Text(subtitle)
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                VStack(spacing: 10) { rows() }
                    .padding(.horizontal, 24)
                Spacer(minLength: 8)
            }
        }
    }

    private func row(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: icon, tint: Theme.accent, size: 34)
            Text(text)
                .font(.rounded(14, .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
    }

    // MARK: - Состояния разрешений

    private enum PermState { case granted, partial, pending }

    private var locationState: PermState {
        switch env.location.authorizationStatus {
        case .authorizedAlways: return .granted
        case .authorizedWhenInUse: return .partial
        default: return .pending
        }
    }
    private var notificationsState: PermState {
        env.notifications.authorizationStatus == .authorized ? .granted : .pending
    }

    private func permissionRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                               state: PermState, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: icon, tint: Theme.accent, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing(for: state, action: action)
        }
        .padding(14)
        .statCard(padding: 0)
    }

    @ViewBuilder
    private func trailing(for state: PermState, action: @escaping () -> Void) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(22)).foregroundStyle(Theme.success)
        case .partial:
            permissionButton("Всегда", tint: Theme.warning, action: action)
        case .pending:
            permissionButton("Разрешить", tint: Theme.accent, action: action)
        }
    }

    /// Кнопка разрешения — капсула 44 pt: самое важное касание онбординга
    /// («Всегда» — без него нет фоновых предупреждений) не бывает мелким.
    private func permissionButton(_ title: LocalizedStringKey, tint: Color,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.controlSize)
                .background(tint.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
