//
//  FamilyShare.swift
//  RadarMap
//
//  Правила «Близкие видят прибытие» (22.1) — чистые, с тестами
//  (FamilyLinkTests, FamilyScenarioTests). Сервис (FamilyShareService) только
//  хранит, отправляет и держит очередь.
//
//  Главные решения:
//    * поездка «домой» — если цель маршрута Дом, ИЛИ дорога узнана как
//      «домой» (призрак: поездка начата у работы), ИЛИ водитель нажал «Еду
//      домой». В режиме «Работаю водителем» призрака нет — остаются цель и
//      кнопка;
//    * «Я пассажир», пауза на поездку, «пауза до завтра» — никому ничего;
//    * время прибытия — по маршруту (та же минута, что у водителя на панели),
//      если он ведёт домой или поездка «каждая»; без маршрута — по призраку,
//      иначе «обычно» по своим поездкам; не знаем — «в пути» без времени:
//      близкий видит «едет домой», а не выдуманную цифру;
//    * «дома» — поездка кончилась в 200 м от Дома или закрылась у цели
//      маршрута, которая и есть Дом (ArrivalFinish, 20.5); автостоп в другом
//      месте — не «не в пути» сразу, а ожидание склейки (магазин по пути):
//      статус у близкого непрерывный.
//

import CoreLocation
import Foundation

nonisolated enum FamilyShare {

    // MARK: - Куда едем

    /// Что приложение знает о поездке — собирает AppEnvironment.
    struct Context: Equatable, Sendable {
        var isTripActive = false
        var isPassenger = false
        /// Цель маршрута — Дом (в `familyHomeRadiusMeters`).
        var routeToHome = false
        /// Дорога узнана как «домой»: призрак или старт у работы.
        var commuteToHome = false
        /// Прибытие по маршруту (с пробками); nil — маршрута нет.
        var routeArrival: Date?
        /// Прибытие по призраку дороги домой.
        var ghostArrival: Date?
        /// «Обычно»: старт поездки + медиана дороги домой.
        var typicalArrival: Date?
        /// Поездка — продолжение прошлой (TripMerge: заезд по пути).
        var isContinuation = false
        /// Экран телефона на виду — для строки «Мама увидит…».
        var screenVisible = false
    }

    static func headingHome(_ context: Context, driverSaidHome: Bool) -> Bool {
        context.routeToHome || context.commuteToHome || driverSaidHome
    }

    /// Кому поездка видна сейчас.
    static func live(_ circle: FamilyCircle, isTripActive: Bool, isPassenger: Bool,
                     pausedThisTrip: Bool, headingHome: Bool, now: Date) -> [FamilyRecipient] {
        guard isTripActive, !isPassenger, !pausedThisTrip, !circle.isPaused(now: now) else { return [] }
        return circle.recipients.filter {
            $0.isReachable && ($0.mode == .everyTrip || headingHome)
        }
    }

    /// Пункт «Еду домой» в меню поездки: едем, не пассажир, без пауз, ещё не
    /// «домой», и есть кому видеть в режиме «Когда еду домой».
    static func offersGoingHome(_ circle: FamilyCircle, isTripActive: Bool, isPassenger: Bool,
                                pausedThisTrip: Bool, headingHome: Bool, now: Date) -> Bool {
        guard isTripActive, !isPassenger, !pausedThisTrip, !headingHome,
              !circle.isPaused(now: now) else { return false }
        return circle.recipients.contains { $0.isReachable && $0.mode == .home }
    }

    /// Время прибытия для близких. Маршрут есть — ЕГО минута (та же, что на
    /// панели водителя и в машине, ArrivalClock), если он ведёт домой или
    /// поездка не домой («каждая поездка»). Маршрут есть, но не домой, а едем
    /// домой (заезд в магазин) — nil: время до магазина — не время прибытия
    /// домой, а призрак о заезде не знает. Призрак и «обычно» (пока оно
    /// впереди) — только без маршрута. Не знаем — nil, без выдумки.
    ///
    /// До 28.10 призрак брался и при живом маршруте не домой — и близкий в
    /// Telegram видел одно время, водитель на панели другое (37).
    static func arrival(_ context: Context, headingHome: Bool, now: Date) -> Date? {
        if let route = context.routeArrival {
            return context.routeToHome || !headingHome ? route : nil
        }
        guard headingHome else { return nil }
        if let ghost = context.ghostArrival { return ghost }
        if let typical = context.typicalArrival, typical > now { return typical }
        return nil
    }

    // MARK: - Когда слать

    /// Что ушло близкому в последний раз.
    struct Sent: Equatable, Sendable {
        var arrival: Date?
        var home: Bool
        var at: Date
    }

    /// Слать ли «в пути» этому близкому — тем же правилом, что «Поделиться
    /// прибытием» (EtaShare.shouldSend): смена минуты, иначе раз в 10 мин
    /// для живости ссылки. Появилось или пропало время, сменилось «домой —
    /// не домой» — сразу.
    static func shouldSend(last: Sent?, arrival: Date?, home: Bool, now: Date) -> Bool {
        guard let last else { return true }
        if last.home != home { return true }
        switch (last.arrival, arrival) {
        case let (before?, after?):
            return EtaShare.shouldSend(lastArrival: before, lastRemaining: 0, lastSentAt: last.at,
                                       arrival: after, remaining: 0, now: now)
        case (nil, nil):
            return now.timeIntervalSince(last.at) >= AppConfig.etaShareKeepAliveSeconds
        default:
            return true
        }
    }

    // MARK: - Тело запроса

    /// Те же поля, что «Поделиться прибытием», плюс «домой» и имя водителя.
    /// Ни точки, ни цели, ни устройства, ни имени близкого. Без времени — без
    /// `eta` (сервер с 22.1 это понимает; старый ответит 400 — как раньше,
    /// когда призрак молчал); «дома» и «не в пути» шлют eta = сейчас — его
    /// требует и старый сервер. `revoke` — последнее «не в пути» по ссылке,
    /// которую водитель убрал или сменил: сервер снимает её подписки в
    /// Telegram сразу (family_notify.revoke_link).
    static func payload(write: EtaShare.WriteKey, status: EtaShare.Status, arrival: Date?,
                        home: Bool, name: String?, now: Date, revoke: Bool = false) -> [String: Any] {
        let when = status == .driving ? arrival : now
        var body = EtaShare.payload(write: write, arrival: when ?? now, remainingMeters: 0, status: status)
        if when == nil { body.removeValue(forKey: "eta") }
        body["home"] = home
        if let name { body["name"] = name }
        if revoke, status == .ended { body["revoke"] = true }
        return body
    }

    // MARK: - Конец поездки

    enum EndAction: Equatable, Sendable {
        /// Закрыть: «дома» или «сейчас не в пути».
        case close(EtaShare.Status)
        /// Ждать склейки: автостоп не у дома — может, это магазин по пути.
        case hold
    }

    static func endAction(_ end: NavigationFlow.TripEnd, arrivedHome: Bool) -> EndAction {
        switch end {
        case .passenger: return .close(.ended)
        case _ where arrivedHome: return .close(.arrived)
        case .manual: return .close(.ended)     // «Стоп» рукой — намерение, склейки не будет
        case .auto: return .hold
        }
    }

    /// «Дома»: кончили в 200 м от Дома, или поездку закрыло прибытие к цели
    /// маршрута, и цель — Дом (GPS у подъезда мог уплыть дальше 200 м).
    static func arrivedHome(endedAt point: CLLocationCoordinate2D?, home: CLLocationCoordinate2D?,
                            atDestination: Bool, destination: CLLocationCoordinate2D?) -> Bool {
        if isNearHome(point, home: home) { return true }
        return atDestination && isNearHome(destination, home: home)
    }

    static func isNearHome(_ point: CLLocationCoordinate2D?, home: CLLocationCoordinate2D?) -> Bool {
        guard let point, let home else { return false }
        return GeoMath.fastDistance(point.latitude, point.longitude, home.latitude, home.longitude)
            <= AppConfig.familyHomeRadiusMeters
    }

    /// Новая поездка после ожидания склейки — та же? Только если её склеил
    /// TripMerge и ожидание не вышло; иначе прошлую закрываем «не в пути».
    static func resumesHeld(holdUntil: Date?, isContinuation: Bool, now: Date) -> Bool {
        guard let holdUntil, now <= holdUntil else { return false }
        return isContinuation
    }

    // MARK: - Слова

    /// Тихая строка «Мама увидит, что вы едете домой»: в поездке домой, когда
    /// кому-то видно, экран на виду и сегодня её ещё не было.
    static func showsNotice(headingHome: Bool, liveCount: Int, screenVisible: Bool,
                            lastShown: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard headingHome, liveCount > 0, screenVisible else { return false }
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }

    static func noticeText(names: [String]) -> String {
        let joined = names.joined(separator: ", ")
        return names.count > 1
            ? String(format: String(localized: "%@ увидят, что вы едете домой"), joined)
            : String(format: String(localized: "%@ увидит, что вы едете домой"), joined)
    }

    /// Капсула в поездке: «Видят: Мама, Дилноза».
    static func watchersText(names: [String]) -> String {
        String(format: String(localized: "Видят: %@"), names.joined(separator: ", "))
    }

    /// Текст ссылки для листа «Поделиться»: коротко, ссылка, строка Telegram
    /// (если сервер назвал бота).
    static func shareMessage(for recipient: FamilyRecipient, base: URL, bot: String?) -> String {
        let link = recipient.url(base: base).absoluteString
        var text = recipient.mode == .everyTrip
            ? String(format: String(localized: "Здесь видно, когда я в пути и когда приеду: %@"), link)
            : String(format: String(localized: "Здесь видно, когда я буду дома: %@"), link)
        if let telegram = recipient.telegramURL(bot: bot) {
            text += "\n" + String(format: String(localized: "Сообщения в Telegram: %@"), telegram.absoluteString)
        }
        return text
    }

    /// Имя бота — то же правило, что на сервере (family_notify._USERNAME:
    /// 5–32 знака латиницы, цифр и «_», «@» впереди снимается).
    static func validBot(_ name: String?) -> String? {
        guard let name else { return nil }
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") { trimmed.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard (5...32).contains(trimmed.count), trimmed.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }
}
