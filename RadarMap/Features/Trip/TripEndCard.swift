//
//  TripEndCard.swift
//  RadarMap
//
//  «Поездка сохранена» — итог сразу после стопа.
//
//  Цифры поездки интереснее всего в момент, когда заглушён двигатель, — а
//  приложение молчало: итог был виден, только если самому открыть Итоги.
//  Карточка показывает главное (балл, путь, время, проезды камер и деньги)
//  и одним тапом ведёт в деталку. Если новая запись похожа на продолжение
//  предыдущей (заехал в магазин, по привычке нажал «Завершить») — склейка
//  предлагается прямо здесь, в момент, а не потом карточкой в списке.
//
//  Показывается только на переднем плане и только для свежесохранённой
//  записи (см. MapScreen.maybeShowTripEnd): автозавершение в кармане
//  обслуживает уведомление, а не карточка поверх карты, которую никто не видит.
//
//  Облик — «балл-герой» (этап 31, выбор владельца 26.10): одна строка
//  ≈ 100 pt — крупный балл, вердикт и «12,4 км · 18 мин · 1 камера», вся
//  карточка — вход в подробности. Было: кольцо, заголовок в две строки на SE,
//  «1 камер», синяя градиентная «Подробнее» (второй «главный» цвет рядом с
//  жёлтым) и ≈ 300 pt высоты поверх «Домой» и дока.
//
//  Если приложение промолчало о камере, мимо которой проехали, — строка
//  «Промолчала о камере» с кнопкой «Не предупредила» (12.5): та же жалоба,
//  что на экране проезда, только в одно касание и в момент, когда водитель
//  ещё помнит, как это было (MissedAlertPrompt).
//

import SwiftUI

struct TripEndCard: View {
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    var onDetail: (TripRecord) -> Void
    var onMerged: () -> Void
    var onDismiss: () -> Void

    @State private var shareSubject: ShareSubjectBox?
    @State private var confirmsMerge = false
    /// Проезды, о тишине которых уже сказали (12.5). В памяти карточки:
    /// она живёт до закрытия, а отправленное ушло на сервер.
    @State private var reportedMissed: Set<UUID> = []
    @State private var isSendingMissed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { onDetail(record) } label: {
                    HStack(spacing: 14) {
                        heroScore
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Поездка сохранена")
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(moneyLine)
                                .font(.rounded(15, .bold))
                                .foregroundStyle(moneyTint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(verbatim: factsLine)
                                .font(.rounded(12, .medium).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.rounded(12, .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint(Text("Подробнее"))
                VStack(spacing: 6) {
                    roundButton("xmark", tint: Theme.textSecondary, action: onDismiss)
                        .accessibilityLabel(Text("Скрыть итог поездки"))
                    roundButton("square.and.arrow.up", tint: Theme.accent, action: share)
                        .accessibilityLabel(Text("Поделиться поездкой"))
                }
            }
            if let previous = mergeCandidate {
                mergeRow(previous: previous)
            }
            missedAlertRow
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
        .confirmationDialog("Объединить с предыдущей поездкой?",
                            isPresented: $confirmsMerge, titleVisibility: .visible) {
            Button("Объединить") { merge() }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// «12,4 км · 18 мин · 1 камера» — склонение из каталога (`%lld камер`):
    /// метрика «1 / камер» читалась как «1 камер».
    private var factsLine: String {
        [Formatting.distance(record.distanceMeters),
         Formatting.duration(record.movingDuration),
         String(localized: "\(record.camerasPassed) камер")].joined(separator: " · ")
    }

    /// Крестик и «поделиться» — малые круги 30 pt, мишень 44.
    private func roundButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.rounded(12, .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Theme.background, in: Circle())
                .tapTarget()
        }
        .buttonStyle(.plain)
    }

    private func share() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            let map = await TripMapSnapshot.render(track: record.trackPoints,
                                                   passes: record.passed,
                                                   size: CGSize(width: 1032, height: 840))
            shareSubject = ShareSubjectBox(subject: .trip(record, map: map))
        }
    }

    // MARK: - Балл

    /// Кольцо с баллом поездки — тем же цветом, что в списках истории.
    /// Балл крупно, без кольца: число и есть итог, а его цвет уже говорит
    /// «хорошо / плохо». Без балла — печать вердикта на той же плашке.
    @ViewBuilder private var heroScore: some View {
        if let score = record.score.map({ Int($0) }) {
            let tint = TripHistorySection.scoreColor(score)
            VStack(spacing: -2) {
                Text(verbatim: "\(score)")
                    .font(.numeral(38, .heavy).monospacedDigit())
                    .foregroundStyle(tint)
                Text("рейтинг")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 70, height: 70)
            .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: String(localized: "Балл поездки: %lld"), score)))
        } else {
            let clean = record.verdict == .clean
            let tint = clean ? Theme.success : Theme.accent
            Image(systemName: clean ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.rounded(30, .bold))
                .foregroundStyle(tint)
                .frame(width: 70, height: 70)
                .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }

    private var moneyLine: String {
        switch record.verdict {
        case .risk(let risk):
            return String(format: String(localized: "риск ≈ %@"), Formatting.money(risk))
        case .overspeed(let count):
            return String(format: String(localized: "Штрафуемых превышений: %lld"), count)
        case .clean:
            return String(localized: "Штрафуемых превышений нет")
        case .unknownLimits:
            return String(localized: "Лимиты камер неизвестны")
        case .noCameras:
            return String(localized: "Без камер и превышений")
        }
    }

    private var moneyTint: Color {
        switch record.verdict {
        case .risk, .overspeed: return Theme.danger
        case .clean, .noCameras: return Theme.success
        case .unknownLimits: return Theme.textSecondary
        }
    }

    // MARK: - Склейка «это продолжение прошлой»

    /// Предыдущая запись, если свежая выглядит её продолжением. Считается по
    /// тем же правилам, что карточка в Итогах, — здесь просто раньше по времени.
    private var mergeCandidate: TripRecord? {
        let history = env.trip.history
        guard history.count >= 2, history[0].id == record.id else { return nil }
        let previous = history[1]
        guard TripMerge.suggestsMerge(previous: previous, next: record,
                                      savedPlaces: env.settings.savedPlaceCoordinates)
        else { return nil }
        return previous
    }

    /// Склейка — через подтверждение. Строка стоит вплотную над «Подробнее»,
    /// и тап, промахнувшийся на пару пунктов, молча сливал две поездки в одну:
    /// карточка тут же подменялась склеенной записью, а вернуть всё назад
    /// можно было только разделением в деталке.
    private func mergeRow(previous: TripRecord) -> some View {
        Button {
            confirmsMerge = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.quietFill, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Похоже, это продолжение прошлой")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "Объединить с поездкой в %@"),
                                Formatting.clock(previous.startedAt)))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - «Не предупредила» (12.5)

    /// Промолчали о камерах этой поездки — строка с одной кнопкой; после
    /// отправки — «Спасибо — разберёмся», пока карточка на экране.
    @ViewBuilder private var missedAlertRow: some View {
        let missed = MissedAlertPrompt.candidates(passes: record.passed, reported: reportedMissed)
        if !missed.isEmpty || !reportedMissed.isEmpty {
            // Две строки, а не одна: на SE заголовок и кнопка в одну строку
            // обрезались оба («Промолчала о ка…», «Не преду…»).
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: missed.isEmpty ? "checkmark.circle.fill" : "speaker.slash.fill")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(missed.isEmpty ? Theme.success : Theme.warning)
                        .frame(width: 30, height: 30)
                        .background(Theme.background, in: Circle())
                    if missed.isEmpty {
                        Text("Спасибо — разберёмся")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: MissedAlertPrompt.title(count: missed.count))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if missed.count == 1, let first = missed.first {
                                Text(verbatim: first.location.isEmpty ? first.kind.displayName : first.location)
                                    .font(.rounded(11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !missed.isEmpty {
                    Button { sendMissed(missed) } label: {
                        Group {
                            if isSendingMissed {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Не предупредила", systemImage: "exclamationmark.bubble.fill")
                                    .font(.rounded(15, .semibold))
                                    .foregroundStyle(Theme.warning)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                        .background(Theme.background,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(isSendingMissed)
                    .accessibilityHint(Text("Отправит место, скорость и лимит этого проезда"))
                }
            }
            .padding(10)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .transition(.opacity)
        }
    }

    /// Одно касание — жалоба на каждый проезд, о котором промолчали: у
    /// каждого своё место и скорость, разбирать их по одному. Отправка та
    /// же, что на экране проезда; очередь без сети — тоже успех.
    private func sendMissed(_ passes: [PassedCamera]) {
        guard !isSendingMissed else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isSendingMissed = true
        let dbVersion = env.cameras.dbVersion
        Task {
            for pass in passes {
                _ = await env.feedback.reportMissedAlert(pass: pass, dbVersion: dbVersion)
            }
            isSendingMissed = false
            withMotion(Motion.standard) { reportedMissed.formUnion(passes.map(\.id)) }
        }
    }

    private func merge() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(Motion.standard) {
            env.trip.mergeWithPrevious(id: record.id)
            onMerged()
        }
    }
}
