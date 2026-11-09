//
//  PermissionsSettingsPage.swift
//  RadarMap
//
//  Три разрешения одним списком: что выдано и как включить остальное.
//  Отказ в окне iOS не отменить из приложения, поэтому кнопка ведёт в
//  Настройки iPhone, а по возвращении статусы обновляются сами.
//

import CoreMotion
import SwiftUI
import UIKit
import UserNotifications

struct PermissionsSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                row("location.fill", "Геолокация", locationValue, ok: env.location.accessStep == .done && env.location.hasFullAccuracy) {
                    if env.location.isAuthorized && !env.location.hasFullAccuracy {
                        env.location.requestPreciseLocation()
                    } else {
                        env.location.takeAccessStep()
                    }
                }
                row("bell.badge.fill", "Уведомления", notificationsValue, ok: notificationsOK) {
                    if env.notifications.authorizationStatus == .notDetermined {
                        env.notifications.requestAuthorization()
                    } else {
                        openSystemSettings()
                    }
                }
                if MotionService.isAvailable {
                    row("figure.walk.motion", "Движение", motionValue, ok: env.motion.authorizationStatus == .authorized) {
                        if env.motion.authorizationStatus == .notDetermined {
                            Task { await env.motion.requestAuthorizationResult() }
                        } else {
                            openSystemSettings()
                        }
                    }
                }
            }
        }
        .settingsPage("Разрешения")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        env.motion.refreshAuthorization()
        await env.notifications.refreshStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var notificationsOK: Bool {
        switch env.notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var locationValue: LocalizedStringKey {
        switch env.location.authorizationStatus {
        case .authorizedAlways: return env.location.hasFullAccuracy ? "Всегда" : "Приблизительная"
        case .authorizedWhenInUse: return "При использовании"
        case .notDetermined: return "Не спрашивали"
        default: return "Выключено"
        }
    }

    private var notificationsValue: LocalizedStringKey {
        if notificationsOK { return "Разрешено" }
        return env.notifications.authorizationStatus == .notDetermined ? "Не спрашивали" : "Выключено"
    }

    private var motionValue: LocalizedStringKey {
        switch env.motion.authorizationStatus {
        case .authorized: return "Разрешено"
        case .notDetermined: return "Не спрашивали"
        default: return "Выключено"
        }
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, _ value: LocalizedStringKey, ok: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(symbol: icon, tint: Theme.accent, size: 32)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(ok ? Theme.textSecondary : Theme.warning)
                Image(systemName: ok ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(ok ? Theme.success : Theme.textSecondary)
            }
        }
        .disabled(ok)
    }
}
