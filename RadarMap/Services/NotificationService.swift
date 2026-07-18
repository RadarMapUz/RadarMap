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
    func scheduleWeeklyDigest(distance: Double, cameras: Int, rating: Int?, cleanMonth: Bool) {
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
        if cleanMonth {
            parts.append(String(localized: "0 штрафов за месяц"))
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

    // MARK: - Приближение к камере (фон)

    /// Один переиспользуемый id: новое уведомление ОБНОВЛЯЕТ предыдущее на месте,
    /// а не копит десяток баннеров за поездку. В Центре всегда ≤1 «камерного».
    private static let approachingID = "approaching-camera"

    /// Оповещение о приближении к камере (фон): баннер, обновляется на месте.
    /// `distanceMeters` — фактическая дистанция срабатывания (движок растягивает
    /// радиус по скорости до 1000 м); без неё — базовый радиус из настроек.
    func notifyApproaching(_ camera: Camera, distanceMeters: Double? = nil) {
        let content = UNMutableNotificationContent()
        let distance = Formatting.distance(distanceMeters ?? settings.alertRadius)
        content.title = String(format: String(localized: "Камера через %@"), distance)

        var body = camera.displayTitle
        if !camera.violations.isEmpty {
            body += "\n" + String(format: String(localized: "Фиксирует: %@"),
                                  camera.localizedViolations.joined(separator: ", "))
        }
        content.body = body
        content.sound = settings.soundEnabled ? .default : nil
        content.interruptionLevel = .timeSensitive

        // Тот же identifier → iOS заменяет прошлый баннер, а не добавляет новый.
        let request = UNNotificationRequest(
            identifier: Self.approachingID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Убрать «камерное» уведомление из Центра (выход на передний план / конец поездки) —
    /// чтобы после проезда баннер не висел.
    func clearApproaching() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.approachingID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.approachingID])
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// На переднем плане: «камерное» — только мгновенный баннер (не оседает в списке,
    /// в приложении уже есть полноэкранный алерт); дайджест — баннер + список + звук.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.identifier == Self.approachingID {
            return [.banner]
        }
        return [.banner, .list, .sound]
    }
}
