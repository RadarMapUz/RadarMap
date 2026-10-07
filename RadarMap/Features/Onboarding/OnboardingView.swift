//
//  OnboardingView.swift
//  RadarMap
//
//  Первое впечатление: четыре страницы — камеры, оповещения, навигатор, разрешения.
//

import SwiftUI
import CoreLocation
import UserNotifications

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    let onFinish: () -> Void

    @State private var page = 0
    private let lastPage = 6

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    heroPage.tag(0)
                    alertsPage.tag(1)
                    voicePage.tag(2)
                    navigatorPage.tag(3)
                    communityPage.tag(4)
                    companionPage.tag(5)
                    permissionsPage.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .motionAnimation(.easeInOut(duration: 0.3), value: page)

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

                Text("Данные о местоположении остаются на устройстве.")
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Страница 1: герой

    private var heroPage: some View {
        VStack(spacing: 0) {
            Spacer()
            RadarHero(active: page == 0)
                .frame(width: 170, height: 170)
                .padding(.bottom, 28)
            Text("RadarMap")
                .font(.rounded(34, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Все камеры и радары Узбекистана из официальных данных. База обновляется сама.")
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 10)
            Spacer()
        }
    }

    // MARK: - Страница 2: оповещения

    private var alertsPage: some View {
        featurePage(
            icon: "bell.and.waves.left.and.right.fill",
            title: "Предупредит заранее",
            rows: [
                ("waveform", "Голос за 22 секунды до камеры — с учётом вашей скорости"),
                ("iphone.gen3", "Работает со свёрнутым приложением и погасшим экраном"),
                ("car.fill", "Автостарт за рулём: сели — оповещения включились сами"),
                ("location.north.line.fill", "Только камеры впереди по курсу — ничего лишнего"),
            ]
        )
    }

    // MARK: - Страница 3: когда я говорю (иначе «почему молчит в городе?» = удаление)

    private var voicePage: some View {
        featurePage(
            icon: "waveform.and.mic",
            title: "Говорю только по делу",
            rows: [
                ("building.2.fill", "В городе — коротко: «камера, 300 метров». Камеры на перекрёстке назову одной фразой"),
                ("road.lanes", "На трассе полностью: «по маршруту камера через 800 метров»"),
                ("exclamationmark.triangle.fill", "Громко — только когда реально превышаете или впереди внезапный радар"),
                ("car.side.and.exclamationmark", "В пробке молчу: скажу, когда поедете"),
            ]
        )
    }

    // MARK: - Страница 5: сообщество

    /// Про кнопку «Радар!» не знал никто. Она живёт в панели поездки и на
    /// приборке, то есть её видит только тот, кто уже едет и уже нашёл панель,
    /// а единственным объяснением была разовая подсказка в одну строку.
    /// Краудсорс без этой страницы не стартует: треноги приезжают в приложение
    /// только через людей, а люди должны сперва узнать, что их об этом просят.
    private var communityPage: some View {
        featurePage(
            icon: "person.2.wave.2.fill",
            title: "Треноги находим вместе",
            rows: [
                ("exclamationmark.triangle.fill", "Треноги нет ни в одной официальной базе — расписание закрыто с 2022 года"),
                ("hand.tap.fill", "Увидели засаду — одна жёлтая кнопка, не глядя на экран. Всё остальное я сделаю сам"),
                ("checkmark.seal.fill", "Отметку проверяет другой водитель. Пока не проверил — рисую пунктиром и честно говорю «отметка водителей»"),
                ("clock.arrow.circlepath", "Нажали случайно — «Отменить» рядом. Нет связи — отправлю, когда появится"),
            ]
        )
    }

    // MARK: - Страница 4: навигатор

    private var navigatorPage: some View {
        featurePage(
            icon: "map.fill",
            title: "Навигатор и лимиты",
            rows: [
                ("arrow.triangle.branch", "Варианты маршрута с числом камер — езжайте, где их меньше"),
                ("arrow.turn.up.right", "Голосовые подсказки: «через 300 метров — направо»"),
                ("gauge.with.needle.fill", "Знак лимита дороги и голос при превышении"),
                ("chart.bar.fill", "Итоги: трек поездки и скорость у каждой камеры"),
            ]
        )
    }

    // MARK: - Страница 4: работаем поверх любого навигатора

    private var companionPage: some View {
        featurePage(
            icon: "square.2.layers.3d.top.filled",
            title: "Едете с Яндексом?",
            rows: [
                ("arrow.down.right.circle", "Просто сверните RadarMap — голос и баннеры о камерах продолжат работать"),
                ("map", "Пробки смотрите где угодно, о камерах предупредим мы"),
                ("bolt.fill", "Фон почти не тратит заряд: точный GPS включается только у камер"),
            ]
        )
    }

    // MARK: - Страница 5: разрешения

    private var permissionsPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "checkmark.shield.fill")
                .font(.rounded(44, .bold))
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.5), radius: 14)
                .padding(.bottom, 18)
            Text("Два разрешения — и в путь")
                .font(.rounded(24, .bold))
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
            Label("Маршруты и местоположение обрабатываются только на этом iPhone — на сервер не уходят.",
                  systemImage: "lock.shield.fill")
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 28)
                .padding(.top, 14)
            Spacer(minLength: 24)
        }
    }

    // MARK: - Компоненты

    private func featurePage(icon: String, title: LocalizedStringKey,
                             rows: [(String, LocalizedStringKey)]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            ZStack {
                Circle().fill(Theme.accent.opacity(0.10)).frame(width: 116, height: 116)
                Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 1.5).frame(width: 116, height: 116)
                Image(systemName: icon)
                    .font(.rounded(42, .bold))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.55), radius: 12)
            }
            .padding(.bottom, 22)

            Text(title)
                .font(.rounded(24, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 22)

            VStack(spacing: 14) {
                ForEach(rows, id: \.0) { icon, text in
                    HStack(spacing: 14) {
                        Image(systemName: icon)
                            .font(.rounded(16, .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Theme.accent.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        Text(text)
                            .font(.rounded(14, .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 20)
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
        .motionAnimation(.spring(duration: 0.3), value: page)
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
        GlassCard(cornerRadius: Theme.cornerMedium) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.rounded(18, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(15, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing(for: state, action: action)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func trailing(for state: PermState, action: @escaping () -> Void) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(22)).foregroundStyle(Theme.success)
        case .partial:
            Button("Всегда", action: action)
                .font(.rounded(13, .semibold)).foregroundStyle(Theme.warning)
        case .pending:
            Button("Разрешить", action: action)
                .font(.rounded(13, .semibold)).foregroundStyle(Theme.accent)
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Theme.background, Theme.adaptive(0xE6E8EE, 0x1F2023)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Анимированный радар для героя онбординга. `active` — крутиться только пока
/// страница на виду: в TabView(.page) соседние страницы остаются в иерархии,
/// и вечная анимация гоняла бы GPU, пока пользователь читает про разрешения.
private struct RadarHero: View {
    let active: Bool
    @State private var sweep = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Theme.accent.opacity(0.35 - Double(i) * 0.09), lineWidth: 1.5)
                    .padding(CGFloat(i) * 28)
            }
            Circle().fill(Theme.accent.opacity(0.06))

            // вращающийся сектор
            AngularGradient(
                colors: [Theme.accent.opacity(0.0), Theme.accent.opacity(0.55)],
                center: .center, angle: .degrees(0)
            )
            .mask(Circle())
            .rotationEffect(.degrees(sweep ? 360 : 0))
            .motionAnimation(sweep ? .linear(duration: 3).repeatForever(autoreverses: false)
                             : .default, value: sweep)

            Image(systemName: "camera.metering.center.weighted")
                .font(.rounded(34, .bold))
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.6), radius: 12)
        }
        .onAppear { sweep = active }
        .onChange(of: active) { _, nowActive in sweep = nowActive }
    }
}
