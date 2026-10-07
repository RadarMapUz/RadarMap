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
//  Тип — ВТОРЫМ движением того же пальца. Просьба из поездки была прямой:
//  «отметка например 3 ножка или радар или дпс должно комфортно нажиматься».
//  Через окно уточнения после отправки это не работает: плашка живёт
//  несколько секунд, и попасть в неё надо ещё раз, уже вслепую и уже проехав.
//  Поэтому здесь — веер: задержал палец (или дёрнул вверх) — над кнопкой
//  встали строки типов, ведёшь палец вверх, каждая новая строка отзывается
//  щелчком, отпустил — ушла она. Целиться некуда: строки во всю ширину, важна
//  только высота. Увёл палец вниз — «Отмена» тем же движением, ничего не
//  отправлено.
//
//  Быстрый тап при этом остался ровно тем, чем был: радар, одно касание.
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
    @State private var fan: FanState?
    @State private var holdTask: Task<Void, Never>?

    private enum Flash: Equatable { case ok, no }

    /// Открытый веер: какая строка под пальцем и не увели ли палец на отмену.
    private struct FanState: Equatable {
        var index: Int
        var isCancelling: Bool
    }

    /// Шаг строки веера в точках — он же шаг выбора по вертикали. Одно число
    /// на картинку и на жест: если развести их, палец будет выбирать не ту
    /// строку, которую подсвечивает экран.
    private static let rowPitch: CGFloat = 62
    private static let rowHeight: CGFloat = 56
    /// Рывок вверх на столько — веер открылся, не дожидаясь удержания.
    private static let flickToOpen: CGFloat = 28
    /// Палец ушёл ниже старта на столько — это «передумал».
    private static let dragToCancel: CGFloat = 44
    private static let holdToOpen: Duration = .milliseconds(280)

    private var kinds: [ReportKind] { ReportKind.offered }

    var body: some View {
        Group {
            if isLarge { largeLabel } else { compactLabel }
        }
        .scaleEffect(fan == nil ? 1 : 0.96)
        .contentShape(Rectangle())
        .gesture(fanGesture)
        .overlay(alignment: .bottom) { fanOverlay }
        .allowsHitTesting(!isSending)
        .motionAnimation(.easeOut(duration: 0.25), value: flash)
        .motionAnimation(.easeOut(duration: 0.2), value: isSending)
        .motionAnimation(.spring(response: 0.28, dampingFraction: 0.82), value: fan)
        .accessibilityLabel(Text("Отметить радар"))
        .accessibilityHint(Text("Отправляет отметку другим водителям. Удержание — выбор типа"))
        // VoiceOver пальцем по экрану не ведёт: для него типы — обычные действия.
        .accessibilityActions {
            ForEach(kinds) { kind in
                Button(kind.title) { send(kind: kind) }
            }
        }
    }

    // MARK: - Веер типов

    private var fanGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isSending else { return }
                if fan == nil {
                    // Первое событие приходит уже на касании (minimumDistance: 0):
                    // здесь заводим удержание, а рывок вверх открывает веер сразу.
                    if holdTask == nil { armHold() }
                    guard value.translation.height <= -Self.flickToOpen else { return }
                    openFan()
                }
                update(for: value.translation)
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                guard let state = fan else {
                    // Веер не открывался — это обычный тап, всё как было.
                    if !isSending { send(kind: .radar) }
                    return
                }
                fan = nil
                guard !state.isCancelling else {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    return
                }
                send(kind: kinds[min(state.index, kinds.count - 1)])
            }
    }

    private func armHold() {
        holdTask = Task {
            try? await Task.sleep(for: Self.holdToOpen)
            guard !Task.isCancelled, fan == nil, !isSending else { return }
            openFan()
        }
    }

    private func openFan() {
        fan = FanState(index: 0, isCancelling: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func update(for translation: CGSize) {
        guard let current = fan else { return }
        let cancelling = translation.height > Self.dragToCancel
        let up = max(0, -translation.height)
        let index = min(kinds.count - 1, Int(up / Self.rowPitch))
        let next = FanState(index: index, isCancelling: cancelling)
        guard next != current else { return }
        // Щелчок на каждой смене строки: выбор слышен пальцем, на экран
        // смотреть не нужно.
        UISelectionFeedbackGenerator().selectionChanged()
        fan = next
    }

    @ViewBuilder private var fanOverlay: some View {
        if let fan {
            VStack(spacing: Self.rowPitch - Self.rowHeight) {
                ForEach(Array(kinds.enumerated()).reversed(), id: \.offset) { index, kind in
                    fanRow(kind, isActive: index == fan.index && !fan.isCancelling)
                }
            }
            .fixedSize()
            .offset(y: -((isLarge ? 62 : 56) + 12))
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
        }
    }

    private func fanRow(_ kind: ReportKind, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.rounded(18, .bold))
                .frame(width: 24)
            Text(kind.title)
                .font(.rounded(17, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isActive ? .white : Theme.textSecondary)
        .padding(.horizontal, 18)
        .frame(minWidth: 210, alignment: .leading)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(isActive ? AnyShapeStyle(Theme.warning.gradient)
                               : AnyShapeStyle(.ultraThinMaterial))
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
            .stroke(isActive ? Color.white.opacity(0.5) : Theme.stroke, lineWidth: 1))
        .scaleEffect(isActive ? 1.04 : 1)
        .shadow(color: .black.opacity(isActive ? 0.3 : 0.15), radius: isActive ? 10 : 4, y: 3)
    }

    /// Приборка: капсула во всю ширину. Тап делается вслепую, и промахнуться
    /// мимо полосы на весь экран сложнее, чем мимо квадрата по центру.
    /// Стиль — тот же «премиальный» язык, что у «Начать поездку» на карте:
    /// градиент со световой кромкой сверху и двойная тень, один вид на всё.
    private var largeLabel: some View {
        HStack(spacing: 10) {
            if isSending {
                ProgressView().controlSize(.regular).tint(foreground)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(fan?.isCancelling == true ? "Отмена" : "Радар")
                .font(.rounded(21, .heavy))
                .contentTransition(.numericText())
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(
            LinearGradient(colors: [background.opacity(0.98), background.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom), in: Capsule())
        .overlay(Capsule().strokeBorder(
            Theme.edgeAccent, lineWidth: 1))
        // Свечение вместо рамки: кнопка должна находиться боковым зрением
        // на чёрном экране, не крича громче предупреждения о камере.
        .shadow(color: background.opacity(0.35), radius: 14, y: 5)
        .liftAccent()
    }

    /// Строка маршрута: компактный квадрат в ряду других кнопок.
    private var compactLabel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                .fill(background.gradient)
            if isSending {
                ProgressView().controlSize(.small).tint(foreground)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(foreground)
            }
        }
        // Крупнее «стопа» рядом: по ней бьют вслепую и чаще всего.
        .frame(width: 56, height: 56)
    }

    private var symbol: String {
        if fan?.isCancelling == true { return "arrow.uturn.backward" }
        switch flash {
        case .ok: return "checkmark"
        case .no: return "xmark"
        case nil: return "exclamationmark.triangle.fill"
        }
    }

    private var background: Color {
        // Палец увели вниз — кнопка на глазах становится «Отменой»: решение
        // видно ДО отпускания, а не после отправки.
        if fan?.isCancelling == true { return Theme.textTertiary }
        switch flash {
        case .ok: return Theme.success
        case .no: return Theme.textTertiary
        // Покой — жёлтое главное действие (макет 07.10): «Радар!» — то, ради
        // чего водитель тянется к телефону, и цвет у неё один на всё приложение.
        case nil: return Theme.action
        }
    }

    /// Текст и значок поверх `background`: тёмные на жёлтом, белые на остальных.
    private var foreground: Color {
        fan?.isCancelling != true && flash == nil ? Theme.onAction : .white
    }

    private func send(kind: ReportKind) {
        guard !isSending else { return }
        isSending = true
        // Тактильный отклик СРАЗУ по нажатию, до сети: подтверждает, что тап
        // засчитан, пока летит запрос. Без него на плохой связи кажется, что
        // кнопка не сработала.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let outcome = await env.mobile.quickReport(
                kind: kind,
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
                    withMotion { env.mobile.dismissRefine() }
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
            withMotion { env.mobile.dismissRefine() }
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Отменить мою отметку"))
    }

    private func option(_ kind: ReportKind, offer: ReportGuard.Sent) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withMotion { env.mobile.dismissRefine() }
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
            .foregroundStyle(kind.cameraType.glyphTint)
            .frame(width: 62, height: 44)
            .background(kind.cameraType.tint.gradient,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
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
                    .foregroundStyle(camera.kind.glyphTint)
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
                    withMotion { env.mobile.answerConfirm(stillThere: nil) }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func answer(title: String, tint: Color, value: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withMotion { env.mobile.answerConfirm(stillThere: value) }
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
                            in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
