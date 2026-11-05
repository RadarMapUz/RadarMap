//
//  RoadPromptCard.swift
//  RadarMap
//
//  Одна вёрстка на все «вопросы на ходу» (этап 45, вариант B): вопрос о
//  проезде, выбор типа и «Отменить» своей отметки, «опаздываю», «карта по
//  пути», объезд, погода на перевале. До 45 их было семь плашек в четырёх
//  вёрстках, отсчёт видели две из семи, а что будет при молчании, не
//  говорила ни одна.
//
//  Правила (лист дизайнера design4): значок, вопрос 18 pt не длиннее двух
//  строк, строка «промолчите — …» всегда; кнопки от 56 pt со словом и
//  значком — синяя — согласие, тихая серая — второе, без красного и зелёного
//  (дейтеранопия; красный в приложении — камера). Отсчёт — заливкой внутри
//  кнопки, которую нажмёт молчание, иначе полосой по низу.
//
//  Чистая вью без окружения: что спросить и куда девать ответ, решает
//  вызывающий (RoadPrompts). В панели поездки справа встаёт «Отметить»
//  (`trailing`), в углу — время прибытия.
//

import SwiftUI

/// Что показать в карточке вопроса.
struct RoadPromptModel {
    enum Glyph {
        /// Монета типа камеры — тот же значок, что на карте.
        case coin(CameraGlyph, fill: Color, ink: Color)
        /// Символ на тихой подложке, цвет — по смыслу.
        case symbol(String, tint: Color)
        /// Символ на своей заливке (событие дороги, свой тип отметки).
        case filled(String, fill: Color, ink: Color)
    }

    struct Action: Identifiable {
        enum Style { case agree, quiet }

        let id: String
        let title: String
        var symbol: String? = nil
        /// Глиф камеры вместо символа (выбор типа отметки).
        var cameraGlyph: CameraGlyph? = nil
        var style: Style = .quiet
        var touch: TouchRole = .regular
        /// VoiceOver — целиком («Да, ещё перекрыто»): голое «Да» пустое слово,
        /// когда фокус дошёл до кнопки отдельно от вопроса.
        var spoken: String? = nil
        /// Эту кнопку «нажмёт» молчание — отсчёт заливкой внутри неё.
        var pressedBySilence = false
        /// Узкая кнопка-значок (44 pt) — «✕» рядом с плитками типов.
        var narrow = false
        let perform: () -> Void
    }

    /// Срок на экране: когда истечёт и сколько всего.
    struct Timer: Equatable {
        let deadline: Date
        let total: TimeInterval
        /// Полоса — жёлтым у ответа на своё «Отметить», синим у остальных.
        var ownTouch = false
    }

    let glyph: Glyph
    let question: String
    /// Строка мельче под вопросом: улица объезда, где перевал, области карты.
    var detail: String? = nil
    /// «промолчите — ничего не отправлю».
    let silence: String
    var actions: [Action] = []
    /// Кнопки столбиком «значок над словом» — три типа отметки в ряд.
    var tiles = false
    /// Значок подпрыгивает раз при появлении — отметка ушла (событие, не украшение).
    var bounces = false
    var timer: Timer? = nil
}

struct RoadPromptCard<Trailing: View>: View {
    let model: RoadPromptModel
    /// Время прибытия в углу (панель поездки на время вопроса); nil — нет.
    var eta: String? = nil
    @ViewBuilder var trailing: Trailing

    @State private var bounced = false

    /// Высота кнопки: за рулём по ней бьют вслепую.
    static var buttonHeight: CGFloat { 56 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            silenceLine
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(model.actions) { action in
                    button(action)
                }
                trailing
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, model.timer != nil && !hasSilentButton ? 14 : 12)
        .overlay(alignment: .bottom) {
            if let timer = model.timer, !hasSilentButton { bar(timer) }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            // Вопрос встаёт сам, без касания: VoiceOver о нём не узнал бы, пока
            // фокус случайно не дойдёт до него, — а живёт он секунды.
            AccessibilityNotification.Announcement(model.question).post()
        }
    }

    private var hasSilentButton: Bool { model.actions.contains { $0.pressedBySilence } }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.question)
                    .font(.rounded(19, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = model.detail {
                    Text(verbatim: detail)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let eta {
                Text(verbatim: eta)
                    .font(.numeral(15, .bold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .accessibilityLabel(Text("Прибытие \(eta)"))
            }
        }
    }

    private var glyph: some View {
        glyphFace
            .symbolEffect(.bounce, options: .nonRepeating, value: bounced)
            .onAppear { if model.bounces, !Motion.isReduced { bounced = true } }
    }

    @ViewBuilder private var glyphFace: some View {
        let side: CGFloat = 40
        switch model.glyph {
        case .coin(let camera, let fill, let ink):
            CameraCoinView(glyph: camera, fill: fill, ink: ink, side: side)
        case .symbol(let name, let tint):
            IconBadge(symbol: name, tint: tint, size: side)
        case .filled(let name, let fill, let ink):
            Image(systemName: name)
                .font(.rounded(17, .bold))
                .foregroundStyle(ink)
                .frame(width: side, height: side)
                .background(fill, in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// «14 с · промолчите — ничего не отправлю»: секунды — пока есть срок.
    private var silenceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "clock")
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Group {
                if let timer = model.timer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = Int(max(0, timer.deadline.timeIntervalSince(context.date)).rounded(.up))
                        Text(verbatim: String(format: String(localized: "%@ сек"), "\(left)") + " · " + model.silence)
                    }
                } else {
                    Text(verbatim: model.silence)
                }
            }
            .font(.rounded(12, .medium).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Кнопки

    private func button(_ action: RoadPromptModel.Action) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
        let agree = action.style == .agree
        let ink = agree ? Theme.onAccentFill : Theme.textPrimary
        return Button(action: action.perform) {
            label(action, ink: ink)
                .frame(maxWidth: action.narrow ? nil : .infinity)
                .frame(width: action.narrow ? Theme.controlSize : nil)
                .frame(minHeight: model.tiles ? 72 : Self.buttonHeight)
                .padding(.horizontal, action.narrow ? 0 : 6)
                .background {
                    ZStack(alignment: .leading) {
                        shape.fill(agree ? Theme.accentFill : Theme.quietFill)
                        if action.pressedBySilence, let timer = model.timer {
                            SilenceFill(timer: timer, tint: agree ? Theme.onAccentFill.opacity(0.24)
                                                                  : Theme.accent.opacity(0.18))
                                .clipShape(shape)
                        }
                    }
                }
                .overlay(shape.strokeBorder(agree ? Color.clear : Theme.stroke, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle(action.touch))
        .accessibilityLabel(Text(verbatim: action.spoken ?? action.title))
    }

    @ViewBuilder
    private func label(_ action: RoadPromptModel.Action, ink: Color) -> some View {
        if action.narrow {
            icon(action, ink: Theme.textSecondary, side: 20)
        } else if model.tiles {
            VStack(spacing: 6) {
                icon(action, ink: ink, side: 26)
                title(action, ink: ink, lines: 1)
            }
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 6) {
                icon(action, ink: ink, side: 20)
                title(action, ink: ink, lines: 2)
            }
        }
    }

    @ViewBuilder
    private func icon(_ action: RoadPromptModel.Action, ink: Color, side: CGFloat) -> some View {
        if let glyph = action.cameraGlyph {
            CameraGlyphView(glyph: glyph, ink: ink, side: side)
        } else if let symbol = action.symbol {
            Image(systemName: symbol)
                .font(.system(size: side * 0.8, weight: .bold))
                .foregroundStyle(ink)
                .accessibilityHidden(true)
        }
    }

    private func title(_ action: RoadPromptModel.Action, ink: Color, lines: Int) -> some View {
        Text(verbatim: action.title)
            .font(.rounded(16, .bold))
            .foregroundStyle(ink)
            .multilineTextAlignment(.center)
            .lineLimit(lines)
            .minimumScaleFactor(0.75)
    }

    /// Полоса по низу — сколько срока осталось. Раз в 0,25 с: секунды
    /// вопроса, одна полоса, не тик GPS.
    private func bar(_ timer: RoadPromptModel.Timer) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let share = timer.total > 0
                ? max(0, min(1, timer.deadline.timeIntervalSince(context.date) / timer.total)) : 0
            GeometryReader { proxy in
                Capsule()
                    .fill(timer.ownTouch ? Theme.action : Theme.accent)
                    .frame(width: proxy.size.width * share, height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension RoadPromptCard where Trailing == EmptyView {
    init(model: RoadPromptModel, eta: String? = nil) {
        self.init(model: model, eta: eta) { EmptyView() }
    }
}

/// Заливка кнопки, которую нажмёт молчание: растёт к полной, когда срок
/// кончится — «нажата».
private struct SilenceFill: View {
    let timer: RoadPromptModel.Timer
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let left = max(0, timer.deadline.timeIntervalSince(context.date))
            let share = timer.total > 0 ? 1 - min(1, left / timer.total) : 1
            GeometryReader { proxy in
                Rectangle()
                    .fill(tint)
                    .frame(width: proxy.size.width * share)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Оболочка вопроса вне панели поездки (покой, выбор маршрута): та же
/// сплошная панель, что у строки поездки, — без стекла над живой картой.
struct RoadPromptPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        content
            .liftedBackground(Theme.surface, in: shape)
            .overlay(shape.stroke(Theme.stroke, lineWidth: 1))
    }
}

// MARK: - Превью: SE (375 pt), ru/uz, день/ночь

private struct RoadPromptPreview: View {
    let locale: String
    let scheme: ColorScheme

    private var uz: Bool { locale == "uz" }

    var body: some View {
        let deadline = Date().addingTimeInterval(14)
        ScrollView {
            VStack(spacing: 12) {
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .coin(CameraType.tripod.glyph, fill: CameraType.tripod.tint,
                                     ink: CameraType.tripod.glyphTint),
                        question: uz ? "Uch oyoq hali turibdimi?" : "Тренога ещё стоит?",
                        silence: uz ? "javob bermasangiz — hech narsa yubormayman" : "промолчите — ничего не отправлю",
                        actions: [
                            .init(id: "y", title: uz ? "Turibdi" : "Стоит", symbol: "checkmark", style: .agree,
                                  perform: {}),
                            .init(id: "n", title: uz ? "Ketgan" : "Убрали", symbol: "xmark", perform: {}),
                        ],
                        timer: .init(deadline: deadline, total: 20)), eta: "19:35") {
                            PreviewReportButton()
                        }
                }
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .symbol("arrow.triangle.branch", tint: Theme.success),
                        question: uz ? "8 daq tezroq — aylanib oʻtamizmi?" : "Быстрее на 8 мин — объехать?",
                        detail: uz ? "Tirbandlikni aylanib oʻtish · Shota Rustaveli orqali"
                                   : "Объезд пробки · через Шота Руставели",
                        silence: uz ? "javob bermasangiz — oʻz yoʻlimizda qolamiz" : "промолчите — останемся на своём пути",
                        actions: [
                            .init(id: "go", title: uz ? "Aylanib oʻtish" : "Объехать",
                                  symbol: "arrow.triangle.branch", style: .agree, perform: {}),
                            .init(id: "stay", title: uz ? "Qolish" : "Остаться", touch: .cancel,
                                  pressedBySilence: true, perform: {}),
                        ],
                        timer: .init(deadline: Date().addingTimeInterval(16), total: 20)), eta: "19:35") {
                            PreviewReportButton()
                        }
                }
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .filled(Icon.reportRadar, fill: Theme.action, ink: Theme.onAction),
                        question: uz ? "Nimani belgilaymiz?" : "Что отметить?",
                        silence: uz ? "javob bermasangiz — «Uch oyoq» yuboriladi" : "промолчите — уйдёт «Тренога»",
                        actions: typeTiles,
                        tiles: true,
                        timer: .init(deadline: Date().addingTimeInterval(2), total: 3, ownTouch: true))) {
                            PreviewReportButton()
                        }
                }
                RoadPromptPanel {
                    RoadPromptCard(model: RoadPromptModel(
                        glyph: .symbol("arrow.down.circle.fill", tint: Theme.accent),
                        question: uz ? "Yoʻl boʻyi xaritasi internetsiz" : "Карта по пути без интернета",
                        detail: uz ? "Samarqand · Navoiy" : "Самарканд · Навои",
                        silence: uz ? "yursangiz — soʻramayman" : "тронетесь — не спрошу",
                        actions: [
                            .init(id: "d", title: uz ? "Yuklab olish · 96 MB" : "Скачать · 96 МБ",
                                  symbol: "arrow.down", style: .agree, perform: {}),
                            .init(id: "x", title: uz ? "Hozir emas" : "Не сейчас", touch: .cancel, perform: {}),
                        ]))
                }
            }
            .padding(16)
        }
        .frame(width: 375, height: 900)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

extension RoadPromptPreview {
    /// Три типа отметки плитками; молчание — тренога.
    fileprivate var typeTiles: [RoadPromptModel.Action] {
        let names: [ReportKind: String] = uz
            ? [.tripod: "Uch oyoq", .post: "YPX posti", .accident: "YTH"]
            : [.tripod: "Тренога", .post: "Пост ДПС", .accident: "ДТП"]
        return [ReportKind.tripod, .post, .accident].map { kind in
            let isDefault = kind == .tripod
            return RoadPromptModel.Action(id: kind.rawValue, title: names[kind] ?? "",
                                          cameraGlyph: kind.cameraGlyph, style: isDefault ? .agree : .quiet,
                                          touch: .primary, pressedBySilence: isDefault, perform: {})
        }
    }
}

/// Место «Отметить» в превью — без окружения приложения.
private struct PreviewReportButton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
            .fill(Theme.action)
            .frame(width: 56, height: 56)
    }
}

#Preview("SE · ru · день") { RoadPromptPreview(locale: "ru", scheme: .light) }
#Preview("SE · ru · ночь") { RoadPromptPreview(locale: "ru", scheme: .dark) }
#Preview("SE · uz · день") { RoadPromptPreview(locale: "uz", scheme: .light) }
#Preview("SE · uz · ночь") { RoadPromptPreview(locale: "uz", scheme: .dark) }
