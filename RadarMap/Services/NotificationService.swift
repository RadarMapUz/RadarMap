//
//  NotificationService.swift
//  RadarMap
//
//  Локальные уведомления о приближении к камере (фон). На переднем плане звук
//  проигрывает AlertPlayer, поэтому здесь звук уведомления при активном приложении гасим.
//

import Foundation
import UserNotifications
import Observation

@MainActor
@Observable
final class NotificationService: NSObject {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshStatus() }
    }

    func requestAuthorization() {
        Task {
            // Отказ пользователя — валидный ответ, не ошибка: статус перечитаем ниже.
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshStatus()
        }
    }

    func refreshStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    // MARK: - Недельный дайджест

    private static let digestID = "weekly-digest"

    /// Пуш «Итоги недели» в воскресенье 19:00. Перепланируется после каждой поездки
    /// со свежими цифрами; без поездок на неделе дайджест сам не появится (не спамим).
    func scheduleWeeklyDigest(distance: Double, cameras: Int, rating: Int?, saved: Double) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.digestID])
        guard settings.weeklyDigest else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Итоги недели 🚗")
        var parts = [Formatting.distance(distance),
                     String(format: String(localized: "%lld камер"), cameras)]
        if let rating {
            parts.append(String(format: String(localized: "рейтинг %lld"), rating))
        }
        if saved > 0 {
            parts.append(String(format: String(localized: "сэкономлено ~%@"), Formatting.money(saved)))
        }
        content.body = parts.joined(separator: " · ")
        content.sound = .default

        var when = DateComponents()
        when.weekday = 1   // воскресенье
        when.hour = 19
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.digestID, content: content, trigger: trigger))
    }

    func cancelWeeklyDigest() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.digestID])
    }

    /// Оповещение о приближении к камере (фон): баннер + звук.
    func notifyApproaching(_ camera: Camera) {
        let content = UNMutableNotificationContent()
        content.title = "Камера через \(Int(settings.alertRadius)) м"

        var body = camera.displayTitle
        if !camera.violations.isEmpty {
            body += "\nФиксирует: " + camera.violations.joined(separator: ", ")
        }
        content.body = body
        content.sound = settings.soundEnabled ? .default : nil
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "camera-\(camera.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// На переднем плане показываем только баннер — звук/голос играет AlertPlayer.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
