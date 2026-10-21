//
//  JournalForm.swift
//  RadarMap
//
//  Поля формы «Заправился» / «Зарядился» (21.6) — значение, а не вьюха, как
//  FineForm у штрафов: что подставить в новую запись и в правку, какая
//  JournalEntry из этого выйдет. Пустое остаётся пустым: пробега, который
//  водитель не вписал, у записи нет — подставленный «примерно» испортил
//  бы реальный расход.
//
//  Чистая логика — EnergyJournalTests.
//

import Foundation

nonisolated struct JournalForm: Equatable {
    var kind: JournalKind
    var date: Date
    var quantity = ""
    var amount = ""
    var odometer = ""
    var full = false

    /// Новая запись: сейчас, вид — первый подходящий.
    init(kind: JournalKind, now: Date) {
        self.kind = kind
        date = now
    }

    /// Правка внесённой записи.
    init(entry: JournalEntry) {
        kind = entry.kind
        date = entry.date
        quantity = Self.decimalText(entry.quantity)
        amount = FineForm.grouped(Int(entry.amount.rounded()))
        odometer = entry.odometerKm.map { FineForm.grouped(Int($0.rounded())) } ?? ""
        full = entry.isFull
    }

    var quantityValue: Double? { Self.decimal(quantity).flatMap { $0 > 0 ? $0 : nil } }
    var amountValue: Double? { FineForm.integer(amount).map(Double.init).flatMap { $0 > 0 ? $0 : nil } }
    var odometerValue: Double? { FineForm.integer(odometer).map(Double.init).flatMap { $0 > 0 ? $0 : nil } }

    /// Без количества и суммы записи нет: деньги из журнала — только реальные.
    var canSave: Bool { quantityValue != nil && amountValue != nil }

    /// Цена за единицу по вписанному — видна сразу, пока человек печатает.
    var unitPrice: Double? {
        guard let quantity = quantityValue, let amount = amountValue else { return nil }
        return amount / quantity
    }

    /// Запись из полей поверх `id` (правка сохраняет свой id).
    func entry(id: UUID) -> JournalEntry? {
        guard let quantity = quantityValue, let amount = amountValue else { return nil }
        return JournalEntry(id: id, date: date, kind: kind, quantity: quantity, amount: amount,
                            odometerKm: odometerValue, full: full ? true : nil)
    }

    /// Десятичное из поля: запятая и точка — обе десятичные, пробелы — разряды.
    static func decimal(_ text: String) -> Double? {
        let cleaned = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, cleaned.count <= 12 else { return nil }
        return Double(cleaned)
    }

    /// «30», «30,5» — по языку приложения, без лишних нулей.
    static func decimalText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : Formatting.decimal(value, digits: 2)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
}
