//
//  FineEntrySheet+Match.swift
//  RadarMap
//
//  Раздел «Поездка» формы штрафа: что нашла сверка (FineMatch) и выбор
//  человека. Нашли один проезд с подтверждением — показываем его и даём
//  сказать «не тот». Несколько похожих — список, сохранить можно только
//  выбрав (или «ни один из них»): молча не угадываем. Ничего — штраф
//  сохранится «без поездки в истории», и это тоже нормальный исход.
//

import SwiftUI

extension FineEntrySheet {

    @ViewBuilder
    func matchSection(_ match: FineMatch.Result?) -> some View {
        Section {
            if form.day == nil {
                Text("Укажите дату — сверим с поездками этого дня.")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                switch choice {
                case .pass(let tripID, let passID)?:
                    if let pass = pass(passID, tripID: tripID) {
                        passRow(pass, selected: true, title: String(localized: "Выбран проезд"))
                    }
                    Button("Сверить заново") { choice = nil }
                case .none?:
                    Label("Без поездки в истории", systemImage: "minus.circle")
                        .foregroundStyle(Theme.textSecondary)
                    Button("Сверить заново") { choice = nil }
                case nil:
                    automatic(match)
                }
                dayPasses
            }
        } header: {
            Text("Поездка")
        } footer: {
            Text("Сверенный проезд получит «штраф пришёл»: сумма уйдёт из «возможных» в «пришло». Рейтинг не меняется.")
        }
    }

    @ViewBuilder
    private func automatic(_ match: FineMatch.Result?) -> some View {
        switch match {
        case .matched(let candidate)?:
            if let pass = pass(candidate.passID, tripID: candidate.tripID) {
                passRow(pass, selected: true, title: String(localized: "Нашли проезд"))
            }
            Button("Не тот проезд — без поездки") { choice = FineEntrySheet.Choice.none }
        case .choose(let candidates)?:
            Label("Похоже на несколько проездов — выберите свой", systemImage: "questionmark.circle")
                .foregroundStyle(Theme.warning)
            ForEach(candidates) { candidate in
                if let pass = pass(candidate.passID, tripID: candidate.tripID) {
                    Button {
                        choice = .pass(tripID: candidate.tripID, passID: candidate.passID)
                    } label: {
                        passRow(pass, selected: false, title: nil)
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
            }
            Button("Ни один из них — без поездки") { choice = FineEntrySheet.Choice.none }
        case .day?:
            Label("В этот день было превышение, но запись поездки уже не хранится — сверим по сводке дня.",
                  systemImage: "calendar")
                .foregroundStyle(Theme.textSecondary)
        case .none?, nil:
            Label("Проезда в истории нет — сохраним штраф без поездки.", systemImage: "minus.circle")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Все проезды дня — ручной выбор, когда сверка не нашла или нашла не то.
    @ViewBuilder
    private var dayPasses: some View {
        if let day = form.day {
            let taken = env.passesTakenByOtherFines(than: request.editing?.id ?? UUID())
            let passes = FineMatch.passes(onDayOf: day, history: env.trip.history)
                .filter { !taken.contains($0.pass.id) }
            if !passes.isEmpty {
                DisclosureGroup(String(format: String(localized: "Проезды этого дня: %lld"), passes.count)) {
                    ForEach(passes, id: \.pass.id) { item in
                        Button {
                            choice = .pass(tripID: item.record.id, passID: item.pass.id)
                        } label: {
                            passRow(item.pass, selected: choice == .pass(tripID: item.record.id, passID: item.pass.id),
                                    title: nil)
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }

    private func pass(_ id: UUID, tripID: Double) -> PassedCamera? {
        env.trip.history.first { $0.id == tripID }?.passed.first { $0.id == id }
    }

    private func passRow(_ pass: PassedCamera, selected: Bool, title: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Theme.success : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.rounded(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                    .font(.rounded(14, .semibold))
                    .lineLimit(2)
                Text(Self.caption(pass))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// «18:47 · 88 км/ч при 60» — наш замер рядом с постановлением.
    static func caption(_ pass: PassedCamera) -> String {
        let time = Formatting.clock(pass.date)
        let speed = Int(pass.speedKmh.rounded())
        if let limit = pass.limitKmh {
            return String(format: String(localized: "%1$@ · %2$lld км/ч при %3$lld"), time, speed, limit)
        }
        return String(format: String(localized: "%1$@ · %2$lld км/ч"), time, speed)
    }
}
