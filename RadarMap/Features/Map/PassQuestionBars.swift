//
//  PassQuestionBars.swift
//  RadarMap
//
//  Вопросы после проезда на карте телефона: «Радар ещё стоял?» о чужой
//  отметке и «Ещё перекрыто?» / «Ремонт ещё идёт?» о событии дороги.
//
//  Одна плашка на оба вопроса (PassQuestionCard) — раскладка, голос и срок
//  у них общие, и расходиться им незачем: до 14.9 у вопроса о радаре не было
//  ни раскладки для крупного шрифта, ни объявления VoiceOver, которые уже
//  получил вопрос дороги. Что спрашивать и куда девать ответ, решают сами
//  бары; молчание — не ответ, по истечении срока не уходит ничего.
//

import SwiftUI
import UIKit

/// Плашка вопроса после проезда: значок, вопрос, «Да»/«Нет».
///
/// Появляется сама, живёт `PassQuestionTimeout` и молча уходит (`onTimeout`).
/// С крупного шрифта вопрос — во всю ширину, ответы — строкой ниже: в одну
/// строку рядом с двумя кнопками вопросу оставалось ~110 pt, и узбекские
/// вопросы обрезались или ломались в столбик по слову (снимки 14.6, 14.9).
struct PassQuestionCard: View {
    struct Answer {
        /// На кнопке — коротко: «Да».
        let title: String
        /// VoiceOver — целиком: голое «Да» пустое слово, когда фокус дошёл до
        /// кнопки отдельно от вопроса, — на что «да», уже не слышно.
        let spoken: String
    }

    let question: String
    let symbol: String
    let fill: Color
    let glyphTint: Color
    let yes: Answer
    let no: Answer
    let onAnswer: (Bool) -> Void
    /// Срок вышел без ответа — снять вопрос, ничего не отправляя.
    let onTimeout: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Когда плашка появилась: срок считается от этого момента и при смене
    /// VoiceOver посреди вопроса не начинается заново.
    @State private var shownAt: Date?

    var body: some View {
        Group {
            if typeSize >= .xLarge {
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 10) {
                        glyph
                        Text(question)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 10) { answers }
                }
            } else {
                HStack(spacing: 10) {
                    glyph
                    Text(question)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    answers
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .onAppear {
            // Плашка появляется сама, без касания: VoiceOver о ней не узнал
            // бы, пока фокус случайно не дойдёт до неё, — а живёт она секунды.
            AccessibilityNotification.Announcement(question).post()
        }
        // Перезапуск на смене VoiceOver: включили посреди вопроса — дождаться
        // длинного срока от появления; уход с экрана задачу отменяет сам.
        .task(id: voiceOver) {
            let start = shownAt ?? Date()
            shownAt = start
            let wait = PassQuestionTimeout.remaining(elapsed: Date().timeIntervalSince(start),
                                                     voiceOver: voiceOver)
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                // Ошибка sleep — только отмена: плашку сняли или сменился
                // VoiceOver (новый отсчёт уже идёт). Вопрос не наш — молчим.
                return
            }
            onTimeout()
        }
    }

    /// Знак отметки — украшение: смысл несёт вопрос рядом.
    @ViewBuilder private var glyph: some View {
        // Камера — значок «Монета» (29.C); событие дороги — свой символ.
        if let camera = CameraGlyph(symbol: symbol) {
            CameraCoinView(glyph: camera, fill: fill, ink: glyphTint, side: 34)
        } else {
            Image(systemName: symbol)
                .font(.rounded(15, .bold))
                .foregroundStyle(glyphTint)
                .frame(width: 34, height: 34)
                .background(fill.gradient, in: Circle())
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var answers: some View {
        button(yes, tint: Theme.successFill, value: true)
        button(no, tint: Theme.dangerFill, value: false)
    }

    private func button(_ answer: Answer, tint: Color, value: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAnswer(value)
        } label: {
            Text(answer.title)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
                // 44 pt — минимум Apple для пальца; за рулём это не педантизм.
                .padding(.horizontal, 10)
                .frame(minWidth: 62, minHeight: 44)
                .background(tint,
                            in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(answer.spoken))
    }
}

/// «Радар ещё стоял?» — вопрос после проезда чужой отметки.
///
/// Появляется сам и молча уходит. Молчание — это не «нет»: если водитель не
/// ответил, мы не отправляем ничего. Ответ же продлевает жизнь честной точке
/// («да» — голос «на месте») или убирает ту, под которой уже пусто («нет» —
/// голос против), — без этого карта передвижных радаров живёт только по
/// таймеру.
struct MobileConfirmBar: View {
    @Environment(AppEnvironment.self) private var env
    /// Экран занят полноэкранным предупреждением о камере. Вопрос обязан
    /// подождать: проверено на симуляции — оповещение накрывало плашку
    /// целиком, её двадцать секунд сгорали под ним, и вопрос пропадал, ни
    /// разу не показавшись. Отсчёт стартует с появления плашки, поэтому
    /// достаточно не показывать её — ожидание получается бесплатно и само собой.
    var isCovered = false

    var body: some View {
        if let shown, !isCovered {
            let kind = shown.kind
            PassQuestionCard(
                question: String(localized: "Радар ещё стоял?"),
                symbol: kind.symbolName, fill: kind.tint, glyphTint: kind.glyphTint,
                yes: .init(title: String(localized: "Да"),
                           spoken: String(localized: "Да, радар ещё стоял")),
                no: .init(title: String(localized: "Нет"),
                          spoken: String(localized: "Нет, радара уже не было")),
                onAnswer: { value in
                    withMotion { env.mobile.answerConfirm(stillThere: value, for: shown.id) }
                    // Ответ должен ощущаться работой, а не тапом в пустоту:
                    // короткое спасибо голосом — за рулём на экран не смотрят.
                    env.alerts.speak(String(localized: "Спасибо!"))
                },
                // Время вышло — снимаем вопрос, ничего не отправляя.
                onTimeout: { withMotion { env.mobile.answerConfirm(stillThere: nil, for: shown.id) } })
            // Другая отметка — другая плашка: свой срок и своё объявление.
            .id(shown.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Отметка, о которой спрашиваем; nil — плашки нет.
    private var shown: (id: Int, kind: CameraType)? {
        if let camera = env.mobile.pendingConfirm { return (camera.id, camera.kind) }
        return Self.showsDemo ? (-1, .tripod) : nil
    }

    /// Скриншот-хук `-demoRadarConfirm` (DEBUG): вопрос без настоящего
    /// проезда. Ответ уходит в пустоту — ждущей отметки нет, answerConfirm
    /// ничего не отправит.
    static var showsDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoRadarConfirm")
        #else
        false
        #endif
    }
}

/// «Ещё перекрыто?» / «Ремонт ещё идёт?» — вопрос после проезда события
/// дороги (RoadEventPassWatch). Та же дисциплина, что у MobileConfirmBar:
/// молча уйти по сроку, молчание ничего не шлёт, под предупреждением о камере
/// ждёт. Показывается, только когда нет вопроса о радаре (MobileConfirmGate).
struct RoadEventConfirmBar: View {
    @Environment(AppEnvironment.self) private var env
    var isCovered = false

    var body: some View {
        if let event = shownEvent, !isCovered {
            let kind = ReportKind(rawValue: event.kind.rawValue) ?? .closure
            PassQuestionCard(
                question: RoadEventPassWatch.question(for: event.kind),
                symbol: kind.symbol, fill: kind.tint, glyphTint: kind.glyphTint,
                yes: .init(title: String(localized: "Да"), spoken: event.kind.spokenAnswer(true)),
                no: .init(title: String(localized: "Нет"), spoken: event.kind.spokenAnswer(false)),
                onAnswer: { value in
                    withMotion { env.mobile.answerRoadConfirm(stillThere: value, for: event.id) }
                    env.alerts.speak(String(localized: "Спасибо!"))
                },
                // Время вышло — снимаем вопрос, ничего не отправляя.
                onTimeout: { withMotion { env.mobile.answerRoadConfirm(stillThere: nil, for: event.id) } })
            .id(event.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Событие, о котором спрашиваем.
    private var shownEvent: (id: Int, kind: RoadEvent.Kind)? {
        if let event = env.mobile.pendingRoadConfirm { return (event.id, event.kind) }
        #if DEBUG
        // Скриншот-хук: `-demoRoadConfirm closure|roadwork` — вопрос без
        // настоящего проезда (ответ уходит в пустоту: ждущего события нет).
        let args = ProcessInfo.processInfo.arguments
        if let at = args.firstIndex(of: "-demoRoadConfirm") {
            let kind = args.indices.contains(at + 1) ? RoadEvent.Kind(rawValue: args[at + 1]) : nil
            return (-1, kind ?? .closure)
        }
        #endif
        return nil
    }
}

private extension RoadEvent.Kind {
    /// Ответ для VoiceOver целиком (PassQuestionCard.Answer.spoken).
    func spokenAnswer(_ yes: Bool) -> String {
        switch (self, yes) {
        case (.closure, true):   return String(localized: "Да, ещё перекрыто")
        case (.closure, false):  return String(localized: "Нет, уже открыто")
        case (.roadwork, true):  return String(localized: "Да, ремонт ещё идёт")
        case (.roadwork, false): return String(localized: "Нет, ремонт закончился")
        }
    }
}
