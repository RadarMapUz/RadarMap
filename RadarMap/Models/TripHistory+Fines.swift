//
//  TripHistory+Fines.swift
//  RadarMap
//
//  Пришедший штраф в записи и в дневной сводке (этап 17.1) — чистые правки,
//  которые TripStats применяет хирургически, как «штраф не пришёл»: запись
//  меняется копией, день — парой unfolded/folded (TripDayBook.replaced).
//  Рейтинг и превышения не трогаются ничем из этого: пришёл штраф или нет,
//  ехал человек одинаково. Тесты — FineReceiptTests.
//

import Foundation

extension TripHistory {
    /// Сверить проезд с внесённым постановлением: «штраф пришёл» с суммой
    /// постановления. В отличие от кнопки «Пришёл», ступень штрафа по нашему
    /// замеру не нужна: постановление — факт, даже если мы считали проезд
    /// чистым или лимит был предположен. nil — проезда нет или он уже сверен
    /// с ДРУГИМ постановлением (одно постановление на проезд).
    static func linkingReceivedFine(_ record: TripRecord, passID: UUID, fineID: UUID,
                                    amount: Double?) -> TripRecord? {
        guard let index = record.passed.firstIndex(where: { $0.id == passID }),
              record.passed[index].fineReceiptID == nil || record.passed[index].fineReceiptID == fineID
        else { return nil }
        var updated = record
        updated.passed[index].finePaid = true
        updated.passed[index].fineDismissed = nil
        updated.passed[index].fineReceiptID = fineID
        updated.passed[index].fineAmount = amount
        return updated
    }

    /// Снять сверку (штраф удалён или пересверен): проезд снова «ожидается».
    /// nil — проезд сверен не с этим постановлением: чужую сверку не снимаем.
    static func unlinkingReceivedFine(_ record: TripRecord, passID: UUID,
                                      fineID: UUID) -> TripRecord? {
        guard let index = record.passed.firstIndex(where: { $0.id == passID }),
              record.passed[index].fineReceiptID == fineID
        else { return nil }
        var updated = record
        // nil, а не false: как у «не пришёл» — непомеченный проезд без полей.
        updated.passed[index].finePaid = nil
        updated.passed[index].fineReceiptID = nil
        updated.passed[index].fineAmount = nil
        return updated
    }

    /// Проезды, уже сверенные с внесёнными постановлениями, — кроме `except`
    /// (пересверка того же штрафа может выбрать свой же проезд).
    static func passesWithReceipts(_ history: [TripRecord], except fineID: UUID? = nil) -> Set<UUID> {
        var result = Set<UUID>()
        for record in history {
            for pass in record.passed {
                if let receipt = pass.fineReceiptID, receipt != fineID { result.insert(pass.id) }
            }
        }
        return result
    }
}

extension TripDayBook {
    /// Штраф сверен с ДНЁМ (запись поездки вычищена): снять `riskMoved` с
    /// «возможных» дня и положить `paidAdded` в «пришло»; `reverse` — вернуть
    /// ровно это же при отвязке. nil — строки дня нет (нечего править).
    static func shiftingFine(day: Date, riskMoved: Double, paidAdded: Double, reverse: Bool,
                             in days: [TripDay]) -> [TripDay]? {
        guard let index = days.firstIndex(where: { $0.day == day }) else { return nil }
        var result = days
        if reverse {
            result[index].fineRisk += riskMoved
            result[index].finePaid = max(0, (result[index].finePaid ?? 0) - paidAdded)
        } else {
            result[index].fineRisk = max(0, result[index].fineRisk - riskMoved)
            result[index].finePaid = (result[index].finePaid ?? 0) + paidAdded
        }
        return result
    }
}
