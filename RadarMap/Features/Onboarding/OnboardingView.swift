//
//  OnboardingView.swift
//  RadarMap
//
//  Приветственный экран: объясняет зачем нужны разрешения, запрашивает их.
//

import SwiftUI
import CoreLocation
import UserNotifications

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                RadarHero()
                    .frame(width: 180, height: 180)
                    .padding(.bottom, 28)

                Text("RadarMap")
                    .font(.rounded(34, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Камеры видеофиксации Узбекистана — предупредим заранее, даже когда телефон в кармане.")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 10)

                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    permissionRow(
                        icon: "location.fill",
                        title: "Геолокация «Всегда»",
                        subtitle: "Чтобы оповещать о камерах во время движения в фоне.",
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

                Spacer(minLength: 24)

                PrimaryButton(title: "Начать", systemImage: "chevron.right", action: onFinish)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                Text("Данные о местоположении остаются на устройстве.")
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 12)
            }
        }
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

    // MARK: - Компоненты

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
                .font(.rounded(13, .semibold)).foregroundStyle(Theme.radar)
        case .pending:
            Button("Разрешить", action: action)
                .font(.rounded(13, .semibold)).foregroundStyle(Theme.accent)
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Theme.background, Color(red: 0.05, green: 0.08, blue: 0.16)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Анимированный радар для героя онбординга.
private struct RadarHero: View {
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
            .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: sweep)

            Image(systemName: "camera.metering.center.weighted")
                .font(.rounded(34, .bold))
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.6), radius: 12)
        }
        .onAppear { sweep = true }
    }
}
