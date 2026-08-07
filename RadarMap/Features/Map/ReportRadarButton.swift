//
//  ReportRadarButton.swift
//  RadarMap
//
//  Кнопка «Радар!» — то, чем водитель отвечает приложению.
//
//  До неё обмен был односторонним: приложение предупреждает, водитель молчит.
//  А человек за рулём видит то, чего не знает никакая база, — треногу за
//  поворотом, патруль на обочине. Раньше отметить это можно было только через
//  меню добавления точки с выбором места на карте, то есть остановившись.
//
//  Отсюда весь дизайн: **один тап, вслепую, большим пальцем**. Никаких форм,
//  подтверждений и выбора типа — «радар» покрывает почти все случаи, а
//  уточнить тип можно из меню на стоянке. Координата берётся текущая.
//
//  Ответ обязателен и обязан ЗВУЧАТЬ: за рулём на экран не смотрят, и
//  беззвучная кнопка читается как сломанная — человек жмёт ещё раз, плодя
//  дубли. Поэтому голос произносит итог всегда, даже отказ.
//

import SwiftUI

struct ReportRadarButton: View {
    @Environment(AppEnvironment.self) private var env
    /// Компактный — в строке поездки рядом с другими кнопками; крупный — на
    /// приборке, где палец ищет кнопку не глядя.
    var isLarge = false

    @State private var isSending = false
    @State private var flash: Flash?

    private enum Flash: Equatable { case ok, no }

    var body: some View {
        Button(action: send) {
            ZStack {
                RoundedRectangle(cornerRadius: isLarge ? 20 : 14, style: .continuous)
                    .fill(background.gradient)
                if isSending {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: isLarge ? 30 : 17, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: isLarge ? 96 : 44, height: isLarge ? 76 : 44)
            .overlay(alignment: .bottom) {
                if isLarge, !isSending {
                    Text("Радар")
                        .font(.rounded(11, .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.bottom, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .animation(.easeOut(duration: 0.25), value: flash)
        .animation(.easeOut(duration: 0.2), value: isSending)
        .accessibilityLabel(Text("Отметить радар"))
        .accessibilityHint(Text("Отправляет отметку другим водителям"))
    }

    private var symbol: String {
        switch flash {
        case .ok: return "checkmark"
        case .no: return "xmark"
        case nil: return "exclamationmark.triangle.fill"
        }
    }

    private var background: Color {
        switch flash {
        case .ok: return Theme.success
        case .no: return Theme.textTertiary
        case nil: return Theme.warning
        }
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        // Тактильный отклик СРАЗУ по нажатию, до сети: подтверждает, что тап
        // засчитан, пока летит запрос. Без него на плохой связи кажется, что
        // кнопка не сработала.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let outcome = await env.mobile.quickReport(
                coordinate: env.location.currentCoordinate,
                speedKmh: env.location.speedKmh,
                isTripActive: env.location.isTripActive)
            isSending = false
            flash = outcome.isSuccess ? .ok : .no
            env.alerts.speak(outcome.spoken)
            UINotificationFeedbackGenerator()
                .notificationOccurred(outcome.isSuccess ? .success : .warning)
            try? await Task.sleep(for: .seconds(2))
            flash = nil
        }
    }
}

/// «Радар ещё стоит?» — вопрос после проезда чужой отметки.
///
/// Появляется сам, живёт двадцать секунд и молча уходит. Молчание — это не
/// «нет»: если водитель не ответил, мы не отправляем ничего. Ответ же
/// продлевает жизнь честной точке или убирает ту, под которой уже пусто, —
/// без этого карта передвижных радаров живёт только по таймеру.
struct MobileConfirmBar: View {
    @Environment(AppEnvironment.self) private var env
    /// Экран занят полноэкранным предупреждением о камере. Вопрос обязан
    /// подождать: проверено на симуляции — оповещение накрывало плашку
    /// целиком, её двадцать секунд сгорали под ним, и вопрос пропадал, ни
    /// разу не показавшись. Отсчёт стартует с `.onAppear`, поэтому достаточно
    /// не показывать её — ожидание получается бесплатно и само собой.
    var isCovered = false

    @State private var task: Task<Void, Never>?

    var body: some View {
        if let camera = env.mobile.pendingConfirm, !isCovered {
            HStack(spacing: 10) {
                Image(systemName: camera.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(camera.kind.tint.gradient, in: Circle())
                Text("Радар ещё стоял?")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                answer(title: String(localized: "Да"), tint: Theme.success, value: true)
                answer(title: String(localized: "Нет"), tint: Theme.danger, value: false)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                task?.cancel()
                task = Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    // Время вышло — снимаем вопрос, ничего не отправляя.
                    withAnimation { env.mobile.answerConfirm(stillThere: nil) }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func answer(title: String, tint: Color, value: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { env.mobile.answerConfirm(stillThere: value) }
        } label: {
            Text(title)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 38)
                .background(tint.gradient,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
