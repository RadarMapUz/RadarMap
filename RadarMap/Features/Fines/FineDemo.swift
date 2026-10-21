//
//  FineDemo.swift
//  RadarMap
//
//  Снимки экрана «Штрафы» без настоящих штрафов (DEBUG): `-demoHistory
//  -demoFines -openScreen fines` — три пришедших штрафа поверх демо-истории
//  (сверенный с проездом, «без поездки», оплаченный); `-finePasteDemo` —
//  форма с уже вставленным текстом, сверяющимся с демо-проездом. В память,
//  не на диск штрафов; напоминания не ставятся.
//

#if DEBUG
import Foundation

enum FineDemo {
    /// Текст «уведомления» о самом свежем демо-проезде с превышением: на
    /// языке приложения, со временем на пару минут позже проезда (часы камер).
    static func pastedText(history: [TripRecord]) -> String {
        let pass = history.flatMap(\.passed).filter { ($0.overLimitKmh ?? 0) > 5 }
            .max { $0.date < $1.date }
        let at = (pass?.date ?? Date()).addingTimeInterval(120)
        let day = at.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "ru")))
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ru")))
        if NumberFormat.locale.language.languageCode?.identifier == "uz" {
            return "Hurmatli haydovchi! 01A777AA davlat raqamli avtomobil \(day) soat \(time) da Toshkent sh., "
                + "Yunusobod tumani, Amir Temur shoh ko‘chasida tezlikni oshirgan: 90 km/soat (ruxsat etilgan "
                + "60 km/soat). Qaror raqami: QR 2610447109. Jarima miqdori: 2 200 000 so‘m."
        }
        return "Уважаемый водитель! Транспортное средство 01 A 777 AA \(day) в \(time) по адресу: г. Ташкент, "
            + "Юнусабадский р-н, ул. Амира Темура зафиксировано превышение скорости: 90 км/ч при разрешённой "
            + "60 км/ч. Постановление № 2610447109. Сумма штрафа: 2 200 000 сум."
    }

    /// Три пришедших штрафа: первый сверен со вторым по свежести демо-проездом
    /// с превышением (через TripStats — «штраф пришёл» виден и в Итогах).
    @MainActor
    static func seed(_ env: AppEnvironment, now: Date = Date()) {
        let calendar = Calendar.current
        let overs = env.trip.history.flatMap { record in
            record.passed.filter { ($0.overLimitKmh ?? 0) > 5 }.map { (record: record, pass: $0) }
        }.sorted { $0.pass.date > $1.pass.date }

        var linked = ReceivedFine(addedAt: now)
        if overs.count > 1 {
            let target = overs[1]
            linked.violationAt = target.pass.date.addingTimeInterval(60)
            linked.timeKnown = true
            linked.place = "г. Ташкент, ул. Амира Темура"
            linked.speedKmh = Int(target.pass.speedKmh.rounded()) + 2
            linked.limitKmh = target.pass.limitKmh
            linked.amount = 5 * FineSchedule.brv
            linked.resolution = "2610447109"
            linked.issuedAt = calendar.date(byAdding: .day, value: 1, to: target.pass.date)
            linked.source = FineSourceKind.pasted.rawValue
            if env.trip.linkReceivedFine(linked.id, amount: linked.amount, passID: target.pass.id,
                                         tripID: target.record.id) {
                linked.link = .pass(tripID: target.record.id, passID: target.pass.id)
            }
        }

        var loose = ReceivedFine(addedAt: now)
        loose.violationAt = calendar.date(byAdding: .day, value: -12, to: calendar.startOfDay(for: now))
            .flatMap { calendar.date(bySettingHour: 8, minute: 12, second: 0, of: $0) }
        loose.timeKnown = true
        loose.place = "Toshkent sh., Chilonzor tumani, Bunyodkor ko‘chasi"
        loose.speedKmh = 92
        loose.limitKmh = 70
        loose.amount = FineSchedule.brv
        loose.resolution = "QR 7741203"
        loose.dueAt = calendar.date(byAdding: .day, value: 9, to: calendar.startOfDay(for: now))
        loose.source = FineSourceKind.pasted.rawValue

        var paid = ReceivedFine(addedAt: now)
        paid.violationAt = calendar.date(byAdding: .day, value: -26, to: calendar.startOfDay(for: now))
        paid.timeKnown = false
        paid.place = "г. Ташкент, ул. Мукими"
        paid.amount = FineSchedule.brv
        paid.paidAt = calendar.date(byAdding: .day, value: -20, to: now)
        paid.source = FineSourceKind.manual.rawValue

        env.fines.seedDemo([linked, loose, paid])
    }
}
#endif
