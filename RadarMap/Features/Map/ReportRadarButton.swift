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
            if isLarge { largeLabel } else { compactLabel }
        }
        .buttonStyle(PressableStyle())
        .disabled(isSending)
        .animation(.easeOut(duration: 0.25), value: flash)
        .animation(.easeOut(duration: 0.2), value: isSending)
        .accessibilityLabel(Text("Отметить радар"))
        .accessibilityHint(Text("Отправляет отметку другим водителям"))
    }

    /// Приборка: капсула во всю ширину. Тап делается вслепую, и промахнуться
    /// мимо полосы на весь экран сложнее, чем мимо квадрата по центру.
    /// Стиль — тот же «премиальный» язык, что у «Начать поездку» на карте:
    /// градиент со световой кромкой сверху и двойная тень, один вид на всё.
    private var largeLabel: some View {
        HStack(spacing: 10) {
            if isSending {
                ProgressView().controlSize(.regular).tint(.white)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text("Радар")
                .font(.rounded(21, .heavy))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(
            LinearGradient(colors: [background.opacity(0.98), background.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom), in: Capsule())
        .overlay(Capsule().strokeBorder(
            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.03)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        // Свечение вместо рамки: кнопка должна находиться боковым зрением
        // на чёрном экране, не крича громче предупреждения о камере.
        .shadow(color: background.opacity(0.35), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    /// Строка маршрута: компактный квадрат в ряду других кнопок.
    private var compactLabel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(background.gradient)
            if isSending {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
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
                isTripActive: env.location.isTripActive,
                // Курс нужен снапу: на разделённой трассе без него отметка с
                // равной вероятностью садится на встречное полотно.
                course: env.location.currentCourse)
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

/// «Что это было?» — необязательное уточнение типа сразу после «Радар!».
///
/// Отметка уже ушла (радар покрывает почти все случаи) — это второй тап для
/// точности: тренога, пост или ДТП живут на сервере разными сроками и рисуются
/// разными значками. Один тап — тип переписан у ТОЙ ЖЕ точки (amend), молчание
/// честно оставляет «радар». Плашка живёт несколько секунд и уходит сама —
/// уточнение не должно требовать взгляда на экран, оно лишь пользуется тем,
/// что взгляд и так упал на подтверждение отправки.
///
/// Здесь же живёт «Отменить»: тип поменять было можно, а отозвать случайный
/// тап — нет, и единственным выходом оставалось найти свой маркер на карте и
/// голосовать против себя (что в одиночку и не работает — на скрытие нужен
/// кворум трёх адресов). Пока отметка своя, свежая и никем не подтверждённая,
/// автор вправе снять её целиком.
struct ReportRefineBar: View {
    @Environment(AppEnvironment.self) private var env
    /// Экран занят предупреждением о камере — плашка ждёт (см. MobileConfirmBar:
    /// отсчёт стартует с onAppear, ожидание бесплатно).
    var isCovered = false

    @State private var task: Task<Void, Never>?

    var body: some View {
        if let offer = env.mobile.refineOffer, !isCovered {
            HStack(spacing: 8) {
                Text("Что это было?")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                option(.tripod, offer: offer)
                option(.accident, offer: offer)
                if env.mobile.cancellableReportID() != nil { cancelOption }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                task?.cancel()
                task = Task {
                    try? await Task.sleep(for: .seconds(AppConfig.reportRefineSeconds))
                    guard !Task.isCancelled else { return }
                    // Время вышло — молчание оставляет «радар».
                    withAnimation { env.mobile.dismissRefine() }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    /// «Не то» — отзыв собственной отметки. Отдельным цветом и последней в
    /// ряду: это выход из ошибки, а не пятый тип засады.
    private var cancelOption: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let id = env.mobile.cancellableReportID() else { return }
            withAnimation { env.mobile.dismissRefine() }
            Task {
                if await env.mobile.cancelReport(id: id) {
                    env.alerts.speak(String(localized: "Отметка убрана"))
                } else {
                    env.alerts.speak(String(localized: "Не отправилось, нет связи"))
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.rounded(15, .bold))
                Text("Отменить")
                    .font(.rounded(9, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 56, height: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Отменить мою отметку"))
    }

    private func option(_ kind: ReportKind, offer: ReportGuard.Sent) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { env.mobile.dismissRefine() }
            Task {
                // Итог звучит: молчаливый тап за рулём читается как несработавший.
                if await env.mobile.refine(to: kind, offer: offer) {
                    env.alerts.speak(kind.title)
                } else {
                    env.alerts.speak(String(localized: "Не отправилось, нет связи"))
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: kind.symbol)
                    .font(.rounded(15, .bold))
                Text(kind.title)
                    .font(.rounded(9, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(width: 62, height: 44)
            .background(kind.cameraType.tint.gradient,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
            // Ответ должен ощущаться работой, а не тапом в пустоту: короткое
            // спасибо голосом — за рулём на экран не смотрят.
            env.alerts.speak(String(localized: "Спасибо!"))
        } label: {
            Text(title)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
                // 44 pt — минимум Apple для пальца; за рулём это не педантизм.
                .frame(width: 62, height: 44)
                .background(tint.gradient,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
