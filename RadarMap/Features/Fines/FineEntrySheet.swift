//
//  FineEntrySheet.swift
//  RadarMap
//
//  «Штраф пришёл» (этап 17.2): вставить текст СМС или уведомления — разбор
//  заполнит, что нашёл, и отметит сомнительное; дальше — обычная форма.
//  Внизу — сверка с поездкой (FineMatch): нашли — показываем, что именно;
//  несколько похожих — человек выбирает сам; ничего — штраф сохранится
//  «без поездки в истории».
//
//  Вставленный текст разбирается на телефоне и не сохраняется: в нём бывают
//  номер машины и имя, а штрафу они не нужны.
//

import SwiftUI

struct FineEntrySheet: View {
    let request: FineEntryRequest
    @Environment(AppEnvironment.self) var env
    @Environment(\.dismiss) private var dismiss

    @State var form = FineForm()
    @State var pasted = ""
    @State var parseNote: ParseNote?
    /// Выбор человека поверх сверки: nil — как решила сверка.
    @State var choice: Choice?
    @State private var confirmsDelete = false
    @State private var prepared = false

    enum ParseNote: Equatable {
        /// Не похоже на уведомление о штрафе.
        case notFine
        /// Похоже, но ни одного поля.
        case nothing
        case found(fields: [FineDraft.Name], unsure: [FineDraft.Name])
    }

    enum Choice: Equatable {
        case pass(tripID: Double, passID: UUID)
        case none
    }

    private var fineID: UUID { request.editing?.id ?? stableID }
    /// id нового штрафа — один на всю жизнь формы (сверка исключает «чужие» проезды по нему).
    @State private var stableID = UUID()

    var body: some View {
        let match = currentMatch
        NavigationStack {
            Form {
                pasteSection
                whenSection
                matchSection(match)
                detailsSection
                if request.editing != nil {
                    Section {
                        Button("Удалить штраф", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(request.editing == nil ? "Штраф пришёл" : "Штраф")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save(match) }
                        .disabled(!canSave(match))
                }
            }
            .confirmationDialog("Удалить штраф?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let id = request.editing?.id { env.deleteReceivedFine(id) }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Проезд снова станет «ожидается», напоминание снимется.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let fine = request.editing {
            form = FineForm(fine: fine)
            switch fine.link?.kind {
            case .pass(let tripID, let passID)?: choice = .pass(tripID: tripID, passID: passID)
            default: choice = nil
            }
        } else if let pass = request.pass, let tripID = request.tripID {
            form = FineForm(pass: pass)
            choice = .pass(tripID: tripID, passID: pass.id)
        }
        if let text = request.pastedText {
            pasted = text
            parse()
        }
    }

    // MARK: - Сверка

    /// Решение сверки по текущим полям. Пересчёт — на каждое изменение полей:
    /// окно по времени отсекает почти всю историю, это микросекунды.
    var currentMatch: FineMatch.Result? {
        guard let query = form.query() else { return nil }
        return FineMatch.match(query, history: env.trip.history, days: env.trip.days,
                               taken: env.passesTakenByOtherFines(than: fineID))
    }

    /// С чем сохранить: выбор человека главнее сверки; «несколько похожих»
    /// без выбора — сохранить нельзя (молча не угадываем).
    func target(_ match: FineMatch.Result?) -> AppEnvironment.FineTarget? {
        switch choice {
        case .pass(let tripID, let passID)?: return .pass(tripID: tripID, passID: passID)
        case .none?: return AppEnvironment.FineTarget.none
        case nil: break
        }
        switch match {
        case .matched(let candidate)?: return .pass(tripID: candidate.tripID, passID: candidate.passID)
        case .day(let day)?: return .day(day)
        case .choose?: return nil
        case .none?, nil: return AppEnvironment.FineTarget.none
        }
    }

    private func canSave(_ match: FineMatch.Result?) -> Bool {
        form.canSave && target(match) != nil
    }

    private func save(_ match: FineMatch.Result?) {
        guard let target = target(match) else { return }
        let base = request.editing ?? ReceivedFine(id: stableID)
        env.saveReceivedFine(form.fine(updating: base), target: target)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }

    // MARK: - Разбор текста

    func parse() {
        let draft = FineTextParser.parse(pasted)
        if !draft.looksLikeFine {
            parseNote = .notFine
        } else if draft.isEmpty {
            parseNote = .nothing
        } else {
            form.apply(draft)
            parseNote = .found(fields: draft.foundFields, unsure: draft.unsureFields)
            // Новые дата и место — новая сверка: прежний выбор мог быть о другом.
            if request.pass == nil { choice = nil }
        }
    }
}
