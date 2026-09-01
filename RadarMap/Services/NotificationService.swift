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
import UIKit

@MainActor
@Observable
final class NotificationService: NSObject {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let settings: AppSettings

    /// Решение «за рулём / пассажир» — вешает AppEnvironment.
    @ObservationIgnored var onPassengerConfirmed: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onPassengerConfirmed,
                                               "NotificationService.onPassengerConfirmed") }
    }
    @ObservationIgnored var onDriverConfirmed: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onDriverConfirmed,
                                               "NotificationService.onDriverConfirmed") }
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
        Task { await refreshStatus() }
    }

    // MARK: - «Вы за рулём?» (пассажир-детектор при автостарте)

    // `nonisolated` — идентификаторы сверяет делегат `UNUserNotificationCenter`,
    // который вызывается вне main.
    nonisolated static let driverCheckID = "driver-check"
    private static let driverCheckCategory = "driver-check-category"
    nonisolated private static let actionPassenger = "passenger"
    private static let actionDriver = "driver"

    private func registerCategories() {
        let driver = UNNotificationAction(identifier: Self.actionDriver,
                                          title: String(localized: "Я за рулём"))
        let passenger = UNNotificationAction(identifier: Self.actionPassenger,
                                             title: String(localized: "Я пассажир"))
        let category = UNNotificationCategory(identifier: Self.driverCheckCategory,
                                              actions: [driver, passenger],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Автостарт в незнакомой машине: спрашиваем ненавязчиво. Молчание = за рулём
    /// (безопасный дефолт), «Я пассажир» — гасим поездку и не тратим заряд.
    func askDriverCheck() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Похоже, вы в пути")
        content.body = String(localized: "Поездка включилась сама. Пассажир? Нажмите — сбережём заряд.")
        content.categoryIdentifier = Self.driverCheckCategory
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.driverCheckID, content: content, trigger: nil))
    }

    func clearDriverCheck() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.driverCheckID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.driverCheckID])
    }

    // MARK: - Итоги поездки (после автозавершения)

    nonisolated private static let tripSummaryID = "trip-summary"

    /// Поездка закончилась сама (вышел из машины, телефон в кармане) — короткие
    /// итоги на локскрин: приложение открывать не обязательно, цифры уже тут.
    /// Тап ведёт в деталку (deep link разбирает RootView).
    func notifyTripSummary(distance: Double, rating: Int?, fineRisk: Double) {
        let content = UNMutableNotificationContent()
        content.title = String(format: String(localized: "Поездка: %@"),
                               Formatting.distance(distance))
        var parts: [String] = []
        if let rating {
            parts.append(String(format: String(localized: "рейтинг %lld"), rating))
        }
        parts.append(fineRisk > 0
            ? String(format: String(localized: "риск штрафов %@"), Formatting.money(fineRisk))
            : String(localized: "без риска штрафов"))
        content.body = parts.joined(separator: " · ")
        content.sound = nil   // человек только что вышел из машины — не трезвоним
        content.userInfo = ["deeplink": "radarmap://trip/last"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.tripSummaryID, content: content, trigger: nil))
    }

    private static let reportConfirmedID = "report-confirmed"

    /// «Вашу отметку подтвердил другой водитель».
    ///
    /// Единственная новость, ради которой стоит трогать человека по поводу
    /// краудсорса: она отвечает на вопрос «работает ли вообще мой тап», без
    /// которого отмечать перестают на второй неделе. Один идентификатор на
    /// все подтверждения — вторая новость заменяет первую, а не копится
    /// стопкой; звука нет, потому что человек, скорее всего, за рулём.
    func notifyReportConfirmed(kind: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Вашу отметку подтвердили")
        content.body = String(format: String(localized: "Другой водитель проехал и подтвердил: %@"),
                              kind)
        content.sound = nil
        content.userInfo = ["deeplink": "radarmap://map"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.reportConfirmedID, content: content,
                                  trigger: nil))
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
    /// Дельта — к прошлой календарной неделе, зависшие штрафы — отдельной строкой:
    /// это единственное напоминание отметить «пришёл/не пришёл», и оно едет в уже
    /// существующем пуше, а не новым спамом.
    func scheduleWeeklyDigest(week: PeriodSummary, previousRating: Int?,
                              pendingChecks: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.digestID])
        guard settings.weeklyDigest else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Итоги недели 🚗")
        var parts = [Formatting.distance(week.distance),
                     String(format: String(localized: "%lld камер"), week.cameras)]
        if let rating = week.rating {
            if let previousRating, rating != previousRating {
                let delta = rating - previousRating
                parts.append(String(format: String(localized: "рейтинг %1$lld (%2$@)"),
                                    rating, delta > 0 ? "+\(delta)" : "\(delta)"))
            } else {
                parts.append(String(format: String(localized: "рейтинг %lld"), rating))
            }
        }
        parts.append(week.fineRisk > 0
                     ? String(format: String(localized: "риск ≈ %@"),
                              Formatting.money(week.fineRisk))
                     : String(localized: "без штрафов"))
        var body = parts.joined(separator: " · ")
        if pendingChecks > 0 {
            body += "\n" + String(format: String(
                localized: "Ждут ответа: %lld — отметьте, пришёл ли штраф"), pendingChecks)
        }
        content.body = body
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
    nonisolated private static let approachingID = "approaching-camera"

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

    /// Ответ на «Вы за рулём?»: кнопки — явное решение, тап по баннеру
    /// (открытие приложения) считаем «за рулём» — открыл, значит смотрит.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        // Итоги поездки: тап → диплинк тем же путём, что и виджеты (onOpenURL).
        // open() очередится системой и доедет до сцены даже при холодном старте.
        if id == Self.tripSummaryID,
           let link = response.notification.request.content.userInfo["deeplink"] as? String,
           let url = URL(string: link) {
            await MainActor.run { UIApplication.shared.open(url) }
            return
        }
        guard id == Self.driverCheckID else { return }
        let isPassenger = response.actionIdentifier == Self.actionPassenger
        await MainActor.run {
            if isPassenger { self.onPassengerConfirmed?() }
            else { self.onDriverConfirmed?() }
        }
    }
}
