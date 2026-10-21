//
//  NotificationService.swift
//  RadarMap
//
//  Локальные уведомления о приближении к камере (фон). На переднем плане звук
//  проигрывает AlertPlayer, поэтому здесь звук уведомления при активном приложении гасим.
//

import Foundation
import UserNotifications
import CoreLocation
import os
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
    /// Камера, о которой висит «Камера через …», — чтобы снять баннер, когда
    /// её проехали (`clearApproaching(passed:)`).
    @ObservationIgnored private var approachingCameraID: Int?

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
        // «Как на заправке?» — четыре ответа прямо на экране блокировки:
        // на АГНКС из машины выходят, телефон в кармане. Фоновые действия —
        // ответ уходит, не открывая приложение.
        let cngActions = [
            UNNotificationAction(identifier: CngAnswer.gas.rawValue, title: String(localized: "Газ есть")),
            UNNotificationAction(identifier: CngAnswer.nogas.rawValue, title: String(localized: "Газа нет")),
            // Словами, а не «~15 мин» / «30+ мин»: у кнопок уведомления нет
            // отдельной подписи для VoiceOver, и голос читал «тильда» и
            // «плюс мин» (14.6). Места строке хватает — действия уведомления
            // идут списком во всю ширину.
            UNNotificationAction(identifier: CngAnswer.queue15.rawValue,
                                 title: String(localized: "Очередь около 15 минут")),
            // «Больше 30» — это queue60 сервера: «~30» на карте и в поиске
            // читалось бы как полчаса, а человек сказал «больше» (ревью 12б.4).
            UNNotificationAction(identifier: CngAnswer.queue60.rawValue,
                                 title: String(localized: "Очередь больше 30 минут")),
        ]
        let cng = UNNotificationCategory(identifier: Self.cngAskCategory, actions: cngActions,
                                         intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, cng])
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

    // MARK: - «Как на заправке?» (метан, 12б.4)

    nonisolated static let cngAskID = "cng-ask"
    private static let cngAskCategory = "cng-ask-category"

    /// Ответ из уведомления — вешает AppEnvironment (CngService.answer).
    @ObservationIgnored var onCngAnswer: ((CngAnswer, CLLocationCoordinate2D) async -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onCngAnswer,
                                               "NotificationService.onCngAnswer") }
    }

    /// Поставить вопрос на через `after` секунд: машина встала у АГНКС. Тихо —
    /// без звука: это просьба, а не тревога.
    func scheduleCngAsk(station: String, point: CLLocationCoordinate2D, after: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Как на заправке?")
        content.body = String(format: String(localized: "%@: есть газ, очередь? Ответ увидят водители рядом."),
                              station)
        content.categoryIdentifier = Self.cngAskCategory
        content.userInfo = ["lat": point.latitude, "lon": point.longitude]
        content.sound = nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, after), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.cngAskID, content: content, trigger: trigger))
    }

    /// Делегат зовётся вне main — ответ передаём на главный актор.
    func deliverCngAnswer(_ answer: CngAnswer, point: CLLocationCoordinate2D) async {
        await onCngAnswer?(answer, point)
    }

    /// Тронулись до вопроса или после — снять: за рулём не спрашиваем.
    func cancelCngAsk() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.cngAskID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.cngAskID])
    }

    // MARK: - Итоги поездки (после автозавершения)

    nonisolated private static let tripSummaryID = "trip-summary"

    /// Поездка закончилась сама (вышел из машины, телефон в кармане) — короткие
    /// итоги на локскрин: приложение открывать не обязательно, цифры уже тут.
    /// Тап ведёт в деталку (deep link разбирает RootView).
    func notifyTripSummary(tripID: Double, distance: Double, rating: Int?, fineRisk: Double) {
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
        // id, а не «последняя»: к тапу последней может стать другая поездка.
        content.userInfo = ["deeplink": DeepLink.trip(tripID).absoluteString]
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
                     String(localized: "\(week.cameras) камер")]
        if let rating = week.rating {
            if let previousRating, rating != previousRating {
                let delta = rating - previousRating
                parts.append(String(format: String(localized: "рейтинг %1$lld (%2$@)"),
                                    rating, Formatting.signed(delta)))
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

    // MARK: - Срок оплаты штрафа (этап 17.3)

    /// Префикс id напоминаний: одно на штраф, id — от штрафа.
    nonisolated private static let fineReminderPrefix = "fine-due-"

    /// Одно напоминание об оплате (FineReminder решает когда и пришло ли уже).
    /// Тап открывает экран «Штрафы» (radarmap://fines). Ответ системы — в
    /// замыкание: штраф помечается «напомнили» только если запрос принят.
    func scheduleFineReminder(fineID: UUID, at fire: Date, title: String, body: String,
                              completion: @escaping @MainActor (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["deeplink": DeepLink.finesURL.absoluteString]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let id = Self.fineReminderPrefix + fineID.uuidString
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
            if let error {
                Log.app.error("напоминание об оплате штрафа не поставлено: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in completion(error == nil) }
        }
    }

    func cancelFineReminder(fineID: UUID) {
        let id = Self.fineReminderPrefix + fineID.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - «Выезжайте раньше» (8.8.7)

    /// Заменить запланированные напоминания о выезде новыми. Снимаем по id
    /// (они по датам — известны заранее), без опроса центра: опрос с `await`
    /// давал гонку двух пересчётов, и поставленные первым переживали «пусто»
    /// второго (ревью 20.10). Добавление — по порядку, через обработчик.
    /// `deliveredToday` — снять и уже показанное сегодня (поехали).
    func scheduleDepartureReminders(_ reminders: [DepartureReminder.Reminder], now: Date = Date(),
                                    deliveredToday: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: DepartureReminder.allIDs(around: now))
        if deliveredToday {
            center.removeDeliveredNotifications(withIdentifiers: [DepartureReminder.id(for: now)])
        }
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Пора выезжать на работу")
            content.body = reminder.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)) { error in
                if let error {
                    Log.app.error("напоминание о выезде не поставлено: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Поехали, а план считать ещё не из чего (история не прочитана): снять
    /// только сегодняшнее напоминание — поставленное на остальные дни остаётся.
    func dropTodayDepartureReminder(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        let today = DepartureReminder.id(for: now)
        center.removePendingNotificationRequests(withIdentifiers: [today])
        center.removeDeliveredNotifications(withIdentifiers: [today])
    }

    // MARK: - Обслуживание машины (18.3)

    /// Одно напоминание: id из плана (MaintenanceReminders), текст готов.
    struct MaintenanceNote {
        let id: String
        let fire: Date
        let title: String
        let body: String
    }

    /// Снять отменённые и поставить новые. Тот же id заменяет поставленное —
    /// повтор не плодит копий. Без звука: это не срочно, а человек мог
    /// только что выйти из машины. `outdated` — показанные о прошлом цикле
    /// (масло уже заменили): из Центра уведомлений их убрать.
    func scheduleMaintenance(_ notes: [MaintenanceNote], cancel: [String], outdated: [String] = []) {
        let center = UNUserNotificationCenter.current()
        if !cancel.isEmpty { center.removePendingNotificationRequests(withIdentifiers: cancel) }
        if !outdated.isEmpty { center.removeDeliveredNotifications(withIdentifiers: outdated) }
        for note in notes {
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = nil
            content.threadIdentifier = "maintenance"
            // Тап — в «Итоги»: карточка «Обслуживание» там первой.
            content.userInfo = ["deeplink": "\(DeepLink.scheme)://stats"]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: note.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: trigger)) { error in
                if let error {
                    Log.app.error("напоминание об обслуживании не поставлено: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Снять все поставленные напоминания об обслуживании — без журнала:
    /// поездка началась, а план считать ещё не из чего.
    func cancelPendingMaintenance() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(MaintenanceReminders.idPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    /// Разрешение на уведомления — с ответом: напоминание, которое некуда
    /// показать, не должно стоять включённым.
    func requestAuthorizationResult() async -> Bool {
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.app.error("разрешение на уведомления: \(error.localizedDescription, privacy: .public)")
            granted = false
        }
        await refreshStatus()
        return granted
    }

    /// Уведомлениям можно показываться (разрешены или «тихо»).
    var canNotify: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
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
        approachingCameraID = camera.id
    }

    /// Камера позади — её «Камера через 132 м» уже неправда. На экране
    /// блокировки баннер висел под плашкой поездки, которая говорила уже о
    /// следующей камере: две разные камеры на одном экране (прогон 20.10).
    /// Баннер о другой камере не трогаем — он о той, что впереди.
    func clearApproaching(passed cameraID: Int) {
        guard approachingCameraID == cameraID else { return }
        clearApproaching()
    }

    /// Убрать «камерное» уведомление из Центра (выход на передний план / конец поездки) —
    /// чтобы после проезда баннер не висел.
    func clearApproaching() {
        approachingCameraID = nil
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
        // Итоги поездки и срок оплаты штрафа: тап → диплинк тем же путём, что
        // и виджеты (onOpenURL).
        // open() очередится системой и доедет до сцены даже при холодном старте.
        if id == Self.tripSummaryID || id.hasPrefix(MaintenanceReminders.idPrefix)
            || id.hasPrefix(Self.fineReminderPrefix),
           let link = response.notification.request.content.userInfo["deeplink"] as? String,
           let url = URL(string: link) {
            await MainActor.run { UIApplication.shared.open(url) }
            return
        }
        if id == Self.cngAskID {
            // Тап по самому баннеру — не ответ: без выбора не уходит ничего.
            guard let answer = CngAnswer(rawValue: response.actionIdentifier),
                  let info = response.notification.request.content.userInfo as? [String: Any],
                  let lat = info["lat"] as? Double, let lon = info["lon"] as? Double else { return }
            let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            await deliverCngAnswer(answer, point: point)
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
