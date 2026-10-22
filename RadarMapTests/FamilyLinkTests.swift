//
//  FamilyLinkTests.swift
//  RadarMapTests
//
//  Близкие (12б.6, 22.1): до пяти человек, у каждого своя ссылка (ключ
//  записи — только на телефоне, в ссылке — его хэш), режим «когда еду домой»
//  или «каждая поездка», без принудительной смены раз в 30 дней; ссылка до
//  22.1 переезжает первым близким с тем же адресом. Правила — FamilyShare.
//

import CoreLocation
import XCTest
@testable import RadarMap

final class FamilyLinkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let base = URL(string: "https://example.uz/radarmap")!
    private let home = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)

    private func sent(_ name: String, mode: FamilyRecipient.Mode = .home) -> FamilyRecipient {
        var recipient = FamilyRecipient(name: name, mode: mode, now: now)
        recipient.linkSentAt = now
        return recipient
    }

    // MARK: - Люди и ссылки

    func testEachRecipientHasOwnKeyAndPage() throws {
        let mother = FamilyRecipient(name: "Мама", now: now)
        let wife = FamilyRecipient(name: "Дилноза", now: now)
        let key = try XCTUnwrap(mother.key)
        XCTAssertEqual(key.count, 22, "128 бит, base64url")
        XCTAssertNotEqual(mother.key, wife.key, "у каждого свой ключ записи")
        XCTAssertNotEqual(mother.token, wife.token)
        XCTAssertEqual(mother.url(base: base).absoluteString,
                       "https://example.uz/radarmap/api/eta/f/\(EtaShare.address(forKey: key))")
        XCTAssertFalse(mother.url(base: base).absoluteString.contains(key), "в ссылке — хэш, не ключ")
        XCTAssertEqual(mother.mode, .home, "по умолчанию — «Когда еду домой»")
        XCTAssertNil(mother.linkSentAt, "новая ссылка ещё не отправлена")
        XCTAssertFalse(mother.isReachable, "кому не отправили — тому не шлём")
    }

    func testChangeLinkGivesNewAddressAndAsksToResend() throws {
        let mother = sent("Мама")
        let changed = mother.withNewLink(now: now.addingTimeInterval(60))
        XCTAssertEqual(changed.id, mother.id)
        XCTAssertEqual(changed.name, "Мама")
        XCTAssertNotEqual(changed.key, mother.key)
        let key = try XCTUnwrap(changed.key)
        XCTAssertEqual(changed.token, EtaShare.address(forKey: key))
        XCTAssertNil(changed.linkSentAt, "новую ссылку надо отправить")
    }

    func testNoForcedRotation() {
        // Год без смены — ссылка та же: смена только по просьбе водителя.
        let mother = sent("Мама")
        var circle = FamilyCircle(recipients: [mother])
        let later = now.addingTimeInterval(365 * 86_400)
        XCTAssertEqual(FamilyShare.live(circle, isTripActive: true, isPassenger: false, pausedThisTrip: false,
                                        headingHome: true, now: later).map(\.token), [mother.token])
        circle.recipients[0].enabled = false
        XCTAssertTrue(FamilyShare.live(circle, isTripActive: true, isPassenger: false, pausedThisTrip: false,
                                       headingHome: true, now: later).isEmpty, "выключатель")
    }

    func testBrokenRecipientDoesNotEmptyCircle() throws {
        // Один нечитаемый близкий (поле другого типа, обрезанная запись) —
        // остальные на месте: раньше круг читался целиком или никак, и первая
        // правка затирала сохранённое вместе с ключами выданных ссылок.
        let mother = sent("Мама"), wife = sent("Дилноза")
        let encoded = try JSONEncoder().encode(FamilyCircle(recipients: [mother, wife], driverName: "Зафар"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var list = try XCTUnwrap(json["recipients"] as? [Any])
        list.insert(["name": 42, "mode": "никогда"], at: 1)
        list.append("мусор")
        json["recipients"] = list
        let data = try JSONSerialization.data(withJSONObject: json)
        let circle = try JSONDecoder().decode(FamilyCircle.self, from: data)
        XCTAssertEqual(circle.recipients, [mother, wife], "битые выпали, целые — в прежнем порядке")
        XCTAssertEqual(circle.driverName, "Зафар", "общие настройки не теряются")
    }

    func testCircleRoundTripsAndOldFileWithoutRecipientsReads() throws {
        let circle = FamilyCircle(recipients: [sent("Мама")], driverName: "Я", pausedUntil: now)
        XCTAssertEqual(try JSONDecoder().decode(FamilyCircle.self, from: JSONEncoder().encode(circle)), circle)
        XCTAssertEqual(try JSONDecoder().decode(FamilyCircle.self, from: Data("{}".utf8)), FamilyCircle())
    }

    func testAtMostFiveRecipients() {
        var circle = FamilyCircle()
        for index in 0..<AppConfig.familyMaxRecipients {
            XCTAssertTrue(circle.canAdd)
            circle.recipients.append(FamilyRecipient(name: "Б\(index)", now: now))
        }
        XCTAssertFalse(circle.canAdd)
        XCTAssertEqual(AppConfig.familyMaxRecipients, 5)
    }

    func testTelegramDeepLinkOnlyWithAValidBot() {
        let mother = sent("Мама")
        XCTAssertEqual(mother.telegramURL(bot: "RadarMapUzBot")?.absoluteString,
                       "https://t.me/RadarMapUzBot?start=f_\(mother.write.address)")
        XCTAssertEqual(mother.telegramURL(bot: "@RadarMapUzBot")?.absoluteString,
                       "https://t.me/RadarMapUzBot?start=f_\(mother.write.address)", "«@» снимается, как на сервере")
        for bad in [nil, "", "bot", "bad name", "<b>x</b>", "Бот_кириллица", String(repeating: "a", count: 33)] {
            XCTAssertNil(mother.telegramURL(bot: bad), bad ?? "nil")
        }
        XCTAssertLessThanOrEqual(("f_" + mother.write.address).count, 64, "Telegram пропускает start до 64 знаков")
    }

    func testShareMessageHasLinkAndTelegramLine() {
        let mother = sent("Мама")
        let plain = FamilyShare.shareMessage(for: mother, base: base, bot: nil)
        XCTAssertTrue(plain.contains(mother.url(base: base).absoluteString))
        XCTAssertFalse(plain.contains("t.me"), "бота не назвали — строки нет")
        let withBot = FamilyShare.shareMessage(for: mother, base: base, bot: "RadarMapUzBot")
        XCTAssertTrue(withBot.contains("https://t.me/RadarMapUzBot?start=f_\(mother.write.address)"))
        XCTAssertNotEqual(FamilyShare.shareMessage(for: sent("Папа", mode: .everyTrip), base: base, bot: nil)
                            .components(separatedBy: ":").first, plain.components(separatedBy: ":").first,
                          "«каждая поездка» — свой текст, не «когда буду дома»")
    }

    // MARK: - Миграция

    /// Ссылка, сохранённая до 22.1, становится первым близким: тот же адрес
    /// и ключ — у мамы ссылка не меняется; режим «когда еду домой».
    func testLegacyLinkMigratesWithTheSameAddress() throws {
        let json = #"{"token":"823EP9H7rh1PuBrW-GnHMvJAZH189cTt_vOc6Giih3A","key":"Zq3xV7kP2mN8rT4wY6bH1c","createdAt":800000000,"name":"Мама","enabled":true,"needsResend":false}"#
        let legacy = try JSONDecoder().decode(FamilyLink.self, from: Data(json.utf8))
        let circle = FamilyCircle.migrated(from: legacy)
        let mother = try XCTUnwrap(circle.recipients.first)
        XCTAssertEqual(circle.recipients.count, 1)
        XCTAssertEqual(mother.name, "Мама")
        XCTAssertEqual(mother.key, "Zq3xV7kP2mN8rT4wY6bH1c")
        XCTAssertEqual(mother.write.address, "823EP9H7rh1PuBrW-GnHMvJAZH189cTt_vOc6Giih3A",
                       "адрес = хэш того же ключа — общий вектор с сервером")
        XCTAssertEqual(mother.mode, .home)
        XCTAssertTrue(mother.isReachable, "ссылка уже у мамы — поездки идут без повторной отправки")
    }

    /// Ссылка до 14.12 (без ключа) — пишет своим токеном и дальше: смены раз
    /// в 30 дней больше нет, значит, ей ничего не грозит.
    func testLegacyTokenLinkKeepsWriting() throws {
        let json = #"{"token":"Ab3_xY-9qqqqqqqqqqqqqq","createdAt":800000000,"name":"Мама"}"#
        let mother = try XCTUnwrap(FamilyCircle.migrated(from: JSONDecoder().decode(FamilyLink.self,
                                                                                   from: Data(json.utf8))).recipients.first)
        XCTAssertEqual(mother.write, .legacy("Ab3_xY-9qqqqqqqqqqqqqq"))
        XCTAssertEqual(mother.url(base: base).lastPathComponent, "Ab3_xY-9qqqqqqqqqqqqqq")
        XCTAssertTrue(mother.enabled, "поля нет — включена")
        XCTAssertNil(mother.telegramURL(bot: "RadarMapUzBot"),
                     "ссылка без ключа в Telegram не подписывается — читатель прислал бы ложное «дома»")
    }

    /// Смену просили переслать, а не переслали — значит, ссылки у мамы нет.
    func testLegacyWaitingForResendIsNotReachable() throws {
        let json = #"{"token":"T","key":"Zq3xV7kP2mN8rT4wY6bH1c","createdAt":800000000,"name":"Мама","enabled":true,"needsResend":true}"#
        let mother = try XCTUnwrap(FamilyCircle.migrated(from: JSONDecoder().decode(FamilyLink.self,
                                                                                   from: Data(json.utf8))).recipients.first)
        XCTAssertNil(mother.linkSentAt)
        XCTAssertFalse(mother.isReachable)
    }

    func testCircleSurvivesStorageAndOldRecordsDecode() throws {
        var circle = FamilyCircle(recipients: [sent("Мама"), sent("Папа", mode: .everyTrip)], driverName: "Зафар")
        circle.recipients[0].emoji = "👩‍🦳"
        let decoded = try JSONDecoder().decode(FamilyCircle.self, from: JSONEncoder().encode(circle))
        XCTAssertEqual(decoded, circle)
        // Запись без новых полей (эмодзи, режима, выключателя) — читается.
        let id = UUID().uuidString
        let bare = #"{"recipients":[{"id":"\#(id)","name":"Мама","token":"T","createdAt":800000000}]}"#
        let old = try JSONDecoder().decode(FamilyCircle.self, from: Data(bare.utf8))
        XCTAssertEqual(old.recipients.first?.mode, .home)
        XCTAssertEqual(old.recipients.first?.enabled, true)
        XCTAssertEqual(old.recipients.first?.emoji, "")
        XCTAssertEqual(old.driverName, "")
        let future = #"{"recipients":[{"id":"\#(id)","name":"Мама","token":"T","createdAt":800000000,"mode":"onlyWhenShared"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(FamilyCircle.self, from: Data(future.utf8)).recipients.first?.mode,
                       .home, "незнакомый режим (запись новой сборки) — сдержанный, а не потеря близкого")
    }

    func testDriverNameIsTrimmedAndCapped() {
        XCTAssertNil(FamilyCircle(driverName: "   ").sentName, "пусто — «Водитель» на стороне сервера")
        XCTAssertEqual(FamilyCircle(driverName: " Зафар ").sentName, "Зафар")
        XCTAssertEqual(FamilyCircle(driverName: String(repeating: "я", count: 40)).sentName?.count,
                       AppConfig.familyDriverNameMax)
    }

    func testPauseUntilTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let evening = Date(timeIntervalSince1970: 1_800_000_000)   // 15.01.2027 13:00 Ташкент
        let end = FamilyCircle.pauseEnd(now: evening, calendar: calendar)
        XCTAssertEqual(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: evening)))
        let circle = FamilyCircle(recipients: [sent("Мама")], pausedUntil: end)
        XCTAssertTrue(circle.isPaused(now: evening))
        XCTAssertFalse(circle.isPaused(now: end), "с полуночи — как обычно")
        XCTAssertTrue(FamilyShare.live(circle, isTripActive: true, isPassenger: false, pausedThisTrip: false,
                                       headingHome: true, now: evening).isEmpty)
    }

    // MARK: - Кому видно

    func testModesDecideWhoSeesTheTrip() {
        let mother = sent("Мама")
        let father = sent("Папа", mode: .everyTrip)
        let circle = FamilyCircle(recipients: [mother, father])
        func live(home: Bool, passenger: Bool = false, paused: Bool = false, trip: Bool = true) -> [String] {
            FamilyShare.live(circle, isTripActive: trip, isPassenger: passenger, pausedThisTrip: paused,
                             headingHome: home, now: now).map(\.name)
        }
        XCTAssertEqual(live(home: true), ["Мама", "Папа"])
        XCTAssertEqual(live(home: false), ["Папа"], "в магазин — только «каждая поездка»")
        XCTAssertEqual(live(home: true, passenger: true), [], "«Я пассажир» — никому")
        XCTAssertEqual(live(home: true, paused: true), [], "пауза на поездку")
        XCTAssertEqual(live(home: true, trip: false), [])
    }

    func testHeadingHomeSignals() {
        var context = FamilyShare.Context(isTripActive: true)
        XCTAssertFalse(FamilyShare.headingHome(context, driverSaidHome: false))
        XCTAssertTrue(FamilyShare.headingHome(context, driverSaidHome: true), "«Еду домой»")
        context.routeToHome = true
        XCTAssertTrue(FamilyShare.headingHome(context, driverSaidHome: false), "цель маршрута — Дом")
        context.routeToHome = false
        context.commuteToHome = true
        XCTAssertTrue(FamilyShare.headingHome(context, driverSaidHome: false), "призрак / распорядок")
    }

    func testArrivalNeverInvented() {
        let route = now.addingTimeInterval(1500), ghost = now.addingTimeInterval(1700)
        let typical = now.addingTimeInterval(1900)
        var context = FamilyShare.Context(isTripActive: true, routeToHome: true, routeArrival: route,
                                          ghostArrival: ghost, typicalArrival: typical)
        XCTAssertEqual(FamilyShare.arrival(context, headingHome: true, now: now), route, "маршрут домой — с пробками")
        context.routeToHome = false
        XCTAssertEqual(FamilyShare.arrival(context, headingHome: true, now: now), ghost,
                       "маршрут в магазин — не время прибытия домой")
        context.ghostArrival = nil
        XCTAssertEqual(FamilyShare.arrival(context, headingHome: true, now: now), typical, "«обычно»")
        context.typicalArrival = now.addingTimeInterval(-60)
        XCTAssertNil(FamilyShare.arrival(context, headingHome: true, now: now), "«обычно» уже прошло — без цифры")
        XCTAssertEqual(FamilyShare.arrival(context, headingHome: false, now: now), route,
                       "«каждая поездка» не домой — время к цели маршрута")
        context.routeArrival = nil
        XCTAssertNil(FamilyShare.arrival(context, headingHome: false, now: now))
    }

    func testSendRhythm() {
        let arrival = now.addingTimeInterval(1500)
        XCTAssertTrue(FamilyShare.shouldSend(last: nil, arrival: nil, home: true, now: now))
        let last = FamilyShare.Sent(arrival: arrival, home: true, at: now)
        XCTAssertFalse(FamilyShare.shouldSend(last: last, arrival: arrival.addingTimeInterval(60), home: true,
                                              now: now.addingTimeInterval(30)), "минута — не повод")
        XCTAssertTrue(FamilyShare.shouldSend(last: last, arrival: arrival.addingTimeInterval(180), home: true,
                                             now: now.addingTimeInterval(30)), "сдвиг на 3 мин")
        XCTAssertTrue(FamilyShare.shouldSend(last: last, arrival: arrival, home: true,
                                             now: now.addingTimeInterval(AppConfig.etaShareKeepAliveSeconds)),
                      "живость ссылки")
        XCTAssertTrue(FamilyShare.shouldSend(last: last, arrival: nil, home: true, now: now), "время пропало")
        XCTAssertTrue(FamilyShare.shouldSend(last: last, arrival: arrival, home: false, now: now), "сменилось «домой»")
        let unknown = FamilyShare.Sent(arrival: nil, home: true, at: now)
        XCTAssertFalse(FamilyShare.shouldSend(last: unknown, arrival: nil, home: true, now: now.addingTimeInterval(60)))
        XCTAssertTrue(FamilyShare.shouldSend(last: unknown, arrival: arrival, home: true, now: now), "время появилось")
    }

    // MARK: - Что уходит на сервер

    func testPayloadHasNoPositionAndNoRecipientName() throws {
        let mother = sent("Мама")
        let body = FamilyShare.payload(write: mother.write, status: .driving, arrival: now.addingTimeInterval(900),
                                       home: true, name: "Зафар", now: now)
        XCTAssertEqual(Set(body.keys), ["key", "token", "eta", "left_m", "status", "home", "name"])
        XCTAssertEqual(body["left_m"] as? Int, 0, "близкому — только время, не остаток пути")
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("Мама"), "имя близкого — только на телефоне")
        for field in ["lat", "lon", "dest", "device", "route", "speed"] {
            XCTAssertFalse(raw.contains("\"\(field)\""), field)
        }
    }

    func testPayloadWithoutArrivalOmitsEta() {
        let mother = sent("Мама")
        let driving = FamilyShare.payload(write: mother.write, status: .driving, arrival: nil, home: true,
                                          name: nil, now: now)
        XCTAssertNil(driving["eta"], "не знаем — не выдумываем")
        XCTAssertNil(driving["name"])
        let ended = FamilyShare.payload(write: mother.write, status: .ended, arrival: nil, home: true,
                                        name: nil, now: now)
        XCTAssertEqual(ended["eta"] as? Double, now.timeIntervalSince1970.rounded(),
                       "«не в пути» — со временем: его требует и старый сервер")
        XCTAssertNil(ended["revoke"])
    }

    func testRevokeOnlyWithEnded() {
        let mother = sent("Мама")
        XCTAssertEqual(FamilyShare.payload(write: mother.write, status: .ended, arrival: nil, home: true,
                                           name: nil, now: now, revoke: true)["revoke"] as? Bool, true)
        XCTAssertNil(FamilyShare.payload(write: mother.write, status: .driving, arrival: nil, home: true,
                                         name: nil, now: now, revoke: true)["revoke"])
    }

    // MARK: - Конец поездки

    func testArrivedHome() {
        let near = CLLocationCoordinate2D(latitude: home.latitude + 0.001, longitude: home.longitude)   // ~110 м
        let far = CLLocationCoordinate2D(latitude: home.latitude + 0.004, longitude: home.longitude)    // ~445 м
        XCTAssertTrue(FamilyShare.arrivedHome(endedAt: near, home: home, atDestination: false, destination: nil))
        XCTAssertFalse(FamilyShare.arrivedHome(endedAt: far, home: home, atDestination: false, destination: nil))
        XCTAssertTrue(FamilyShare.arrivedHome(endedAt: far, home: home, atDestination: true, destination: near),
                      "закрыло прибытие к цели-Дому — дома, даже если GPS уплыл")
        XCTAssertFalse(FamilyShare.arrivedHome(endedAt: far, home: home, atDestination: true, destination: far),
                       "у цели, но цель — не Дом")
        XCTAssertFalse(FamilyShare.arrivedHome(endedAt: near, home: nil, atDestination: true, destination: near),
                       "Дом неизвестен — не «дома»")
    }

    func testEndActions() {
        XCTAssertEqual(FamilyShare.endAction(.auto, arrivedHome: true), .close(.arrived))
        XCTAssertEqual(FamilyShare.endAction(.manual, arrivedHome: true), .close(.arrived))
        XCTAssertEqual(FamilyShare.endAction(.manual, arrivedHome: false), .close(.ended), "«Стоп» — намерение")
        XCTAssertEqual(FamilyShare.endAction(.auto, arrivedHome: false), .hold, "может, магазин по пути")
        XCTAssertEqual(FamilyShare.endAction(.passenger, arrivedHome: true), .close(.ended))
    }

    // MARK: - Слова

    func testNoticeOncePerDayAndOnlyHome() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        XCTAssertTrue(FamilyShare.showsNotice(headingHome: true, liveCount: 1, screenVisible: true,
                                              lastShown: nil, now: now, calendar: calendar))
        XCTAssertFalse(FamilyShare.showsNotice(headingHome: true, liveCount: 1, screenVisible: true,
                                               lastShown: now.addingTimeInterval(-3600), now: now, calendar: calendar),
                       "сегодня уже было")
        XCTAssertTrue(FamilyShare.showsNotice(headingHome: true, liveCount: 1, screenVisible: true,
                                              lastShown: now.addingTimeInterval(-86_400), now: now, calendar: calendar))
        XCTAssertFalse(FamilyShare.showsNotice(headingHome: false, liveCount: 1, screenVisible: true,
                                               lastShown: nil, now: now, calendar: calendar), "не домой")
        XCTAssertFalse(FamilyShare.showsNotice(headingHome: true, liveCount: 0, screenVisible: true,
                                               lastShown: nil, now: now, calendar: calendar), "никто не видит")
        XCTAssertFalse(FamilyShare.showsNotice(headingHome: true, liveCount: 1, screenVisible: false,
                                               lastShown: nil, now: now, calendar: calendar),
                       "экран погашен — строку некому читать, день не тратим")
        XCTAssertTrue(FamilyShare.noticeText(names: ["Мама"]).contains("Мама"))
        XCTAssertTrue(FamilyShare.watchersText(names: ["Мама", "Дилноза"]).hasSuffix("Мама, Дилноза"))
    }

    func testGoingHomeOffer() {
        let circle = FamilyCircle(recipients: [sent("Мама")])
        func offers(_ c: FamilyCircle = FamilyCircle(recipients: [FamilyRecipient(name: "Мама", now: Date())]),
                    passenger: Bool = false, paused: Bool = false, home: Bool = false) -> Bool {
            FamilyShare.offersGoingHome(c, isTripActive: true, isPassenger: passenger, pausedThisTrip: paused,
                                        headingHome: home, now: now)
        }
        XCTAssertTrue(offers(circle))
        XCTAssertFalse(offers(), "ссылку не отправили — некому видеть")
        XCTAssertFalse(offers(circle, home: true), "уже домой")
        XCTAssertFalse(offers(circle, passenger: true))
        XCTAssertFalse(offers(circle, paused: true))
        XCTAssertFalse(offers(FamilyCircle(recipients: [sent("Папа", mode: .everyTrip)])),
                       "«каждая поездка» и так видит — кнопка ничего не меняет")
    }
}
