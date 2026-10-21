//
//  AppEnvironment+Fines.swift
//  RadarMap
//
//  Пришедшие штрафы (этап 17): сохранить, сверить с проездом, отвязать,
//  отметить оплату, поставить напоминание. Здесь сходятся три сервиса —
//  FineStore (сами штрафы), TripStats (проезд «штраф пришёл» и деньги дня) и
//  NotificationService (одно напоминание об оплате), — поэтому оркестровка
//  живёт в композиционном корне, а решения — в чистых FineMatch,
//  FineDeadline, FineReminder.
//
//  Ничего из этого не уходит с телефона: ни штрафы, ни номер машины.
//

import Foundation
import UserNotifications
import os

extension AppEnvironment {
    /// С чем сверить штраф — решение формы: FineMatch или выбор человека.
    enum FineTarget: Equatable {
        case pass(tripID: Double, passID: UUID)
        /// Запись вычищена, сводка дня помнит превышение.
        case day(Date)
        /// «Без поездки в истории».
        case none
    }

    /// Сохранить штраф (новый или правку). Прежняя сверка снимается целиком
    /// — проезд снова «ожидается», деньги дня возвращаются, — и ставится
    /// выбранная: так правка суммы или «не тот проезд» не оставляют хвостов.
    func saveReceivedFine(_ draft: ReceivedFine, target: FineTarget) {
        var fine = draft
        let previous = fines.fine(fine.id)
        if let previous, case .pass(let tripID, let passID)? = previous.link?.kind,
           target == .pass(tripID: tripID, passID: passID),
           !trip.history.contains(where: { $0.id == tripID }) {
            // Правка штрафа, чья поездка уже вычищена: сверка остаётся как
            // была — снять её нечем, а поставить заново некуда.
            fine.link = previous.link
        } else {
            if let previous { detachFineLink(previous) }
            fine.link = attachFine(fine, to: target)
        }
        fines.upsert(fine)
        updateFineReminder(fine.id, mayAsk: true)
    }

    func deleteReceivedFine(_ id: UUID) {
        guard let fine = fines.fine(id) else { return }
        detachFineLink(fine)
        notifications.cancelFineReminder(fineID: id)
        fines.remove(id)
    }

    /// «Оплачен» — снимает напоминание; «не оплачен» — может вернуть его,
    /// если оно ещё не приходило.
    func setReceivedFinePaid(_ id: UUID, paid: Bool, now: Date = Date()) {
        guard var fine = fines.fine(id) else { return }
        fine.paidAt = paid ? now : nil
        fines.upsert(fine)
        updateFineReminder(id, mayAsk: false)
    }

    /// Экран штрафов открыт: напоминания, не вставшие раньше (уведомления
    /// разрешили позже), ставятся сейчас — без вопроса о разрешении.
    func refreshFineReminders() {
        fines.reloadIfNeeded()
        #if DEBUG
        if fines.isDemo { return }   // демо для снимков — без настоящих уведомлений
        #endif
        for fine in fines.fines where !fine.isPaid { updateFineReminder(fine.id, mayAsk: false) }
    }

    /// Проезды, уже сверенные с другими постановлениями: FineMatch их не предложит.
    func passesTakenByOtherFines(than id: UUID) -> Set<UUID> {
        TripHistory.passesWithReceipts(trip.history, except: id)
    }

    // MARK: - Сверка

    private func attachFine(_ fine: ReceivedFine, to target: FineTarget) -> FineLink? {
        switch target {
        case .pass(let tripID, let passID):
            guard trip.linkReceivedFine(fine.id, amount: fine.amount, passID: passID, tripID: tripID) else {
                Log.trips.error("штраф не сверен с проездом: записи или проезда нет — сохранён без поездки")
                return nil
            }
            return .pass(tripID: tripID, passID: passID)
        case .day(let day):
            let shift = FineMatch.dayShift(day: day, amount: fine.amount, speedKmh: fine.speedKmh,
                                           limitKmh: fine.limitKmh, history: trip.history, days: trip.days)
            guard shift.riskMoved > 0 || shift.paidAdded > 0 else { return .day(day, riskMoved: 0, paidAdded: 0) }
            guard trip.shiftDayFine(day: day, riskMoved: shift.riskMoved, paidAdded: shift.paidAdded,
                                    reverse: false) else {
                Log.trips.error("штраф по сводке дня: строки дня нет — сохранён без поездки")
                return nil
            }
            return .day(day, riskMoved: shift.riskMoved, paidAdded: shift.paidAdded)
        case .none:
            return nil
        }
    }

    private func detachFineLink(_ fine: ReceivedFine) {
        guard let link = fine.link else { return }
        switch link.kind {
        case .pass(let tripID, let passID):
            if !trip.unlinkReceivedFine(fine.id, passID: passID, tripID: tripID) {
                // Запись поездки уже вычищена: проезда нет — и снимать нечего.
                // Деньги дня остаются «пришло»: постановление и правда было.
                Log.trips.notice("отвязка штрафа: записи поездки уже нет")
            }
        case .day(let day):
            let risk = link.riskMoved ?? 0, paid = link.paidAdded ?? 0
            if risk > 0 || paid > 0,
               !trip.shiftDayFine(day: day, riskMoved: risk, paidAdded: paid, reverse: true) {
                Log.trips.notice("отвязка штрафа от дня: строки дня уже нет")
            }
        case .unknown:
            break
        }
    }

    // MARK: - Напоминание

    private func updateFineReminder(_ id: UUID, mayAsk: Bool, now: Date = Date()) {
        guard let fine = fines.fine(id) else { return }
        switch FineReminder.action(for: fine, now: now) {
        case .none:
            return
        case .cancel:
            notifications.cancelFineReminder(fineID: id)
            var updated = fine
            updated.reminderAt = nil
            fines.upsert(updated)
        case .schedule(let plan):
            Task { @MainActor in
                guard await self.mayNotify(ask: mayAsk) else { return }
                let (title, body) = Self.fineReminderText(plan, amount: fine.amount)
                // Переставить: прежнее, ещё не пришедшее, снимается.
                self.notifications.cancelFineReminder(fineID: id)
                self.notifications.scheduleFineReminder(fineID: id, at: plan.fire,
                                                        title: title, body: body) { accepted in
                    guard accepted, var current = self.fines.fine(id) else { return }
                    current.reminderAt = plan.fire
                    self.fines.upsert(current)
                }
            }
        }
    }

    /// Можно ли показать напоминание. Спросить разрешение — только из
    /// действия человека (сохранил штраф со сроком), не при открытии экрана.
    private func mayNotify(ask: Bool) async -> Bool {
        if notifications.canNotify { return true }
        guard ask, notifications.authorizationStatus == .notDetermined else { return false }
        return await notifications.requestAuthorizationResult()
    }

    /// Текст напоминания — нейтральный: сроки — ориентир (👤 правила не
    /// подтверждены), условия — в постановлении.
    static func fineReminderText(_ plan: FineReminder.Plan, amount: Double?)
        -> (title: String, body: String) {
        let date = plan.deadline.formatted(.dateTime.day().month(.abbreviated).locale(NumberFormat.locale))
        if plan.isDiscount {
            let sum = amount.map { FineFormat.money(($0 * (1 - AppConfig.fineDiscountShare)).rounded()) }
            return (String(localized: "Льготный срок оплаты штрафа"),
                    sum.map { String(format: String(localized: "До %1$@ — ≈ %2$@. Условия — в постановлении."), date, $0) }
                    ?? String(format: String(localized: "До %@. Условия — в постановлении."), date))
        }
        return (String(localized: "Срок оплаты штрафа"),
                amount.map { String(format: String(localized: "До %1$@ — %2$@."), date, FineFormat.money($0)) }
                ?? String(format: String(localized: "До %@. Условия — в постановлении."), date))
    }
}

/// Суммы постановлений — точно до сума («1 650 000 сум»), а не «1,7 млн»:
/// это не оценка, а цифра, которую человек будет сверять с квитанцией.
enum FineFormat {
    static func money(_ sum: Double) -> String {
        let grouped = grouping.string(from: NSNumber(value: Int(sum.rounded()))) ?? "\(Int(sum.rounded()))"
        return Formatting.unbreakable(String(format: String(localized: "%@ сум"), grouped))
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// «12 окт., 18:45» / «12 окт.» — по языку приложения.
    static func moment(_ date: Date, withTime: Bool) -> String {
        withTime
            ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(NumberFormat.locale))
            : date.formatted(.dateTime.day().month(.abbreviated).locale(NumberFormat.locale))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(NumberFormat.locale))
    }
}
