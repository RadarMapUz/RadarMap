//
//  ReportButton.swift
//  RadarMap
//
//  Кнопка «Отметить» — то, чем водитель отвечает приложению.
//
//  Вариант B (выбор владельца 02.11, docs/team/specs/tripod-report.md):
//  касание ничего не отправляет, а запоминает точку и открывает над панелью
//  три крупные плитки — Тренога (выбрана, кольцо с отсчётом 3 с), Пост ДПС,
//  ДТП — и «✕». Молчание отправляет треногу, второе касание этой же кнопки —
//  тоже треногу сразу, «✕» — ничего. Тренога вслепую — одно касание и три
//  секунды или два касания; ошибочное касание не уходит в общую базу вовсе.
//
//  Веер удержанием (до 02.11) убран. Он был невидим — ни ручки, ни подсказки,
//  строки появлялись только под пальцем, — и брал координату при отпускании,
//  на секунду-полторы позже касания (картограф, A-4). Плитки показывают те же
//  типы крупно и сразу, и второй способ выбрать тип на одной кнопке был бы
//  вторым правилом для одного действия. Действия VoiceOver по типам остались:
//  ему пальцем по плиткам вести незачем.
//
//  Ответ обязан ЗВУЧАТЬ: за рулём на экран не смотрят. Голос называет тип —
//  «Тренога отмечена» — или причину отказа (ReportFlow).
//

import SwiftUI

struct ReportButton: View {
    @Environment(AppEnvironment.self) private var env
    /// На экране оповещения о камере выбор не встаёт (экран занят камерой):
    /// тренога уходит сразу, «Отменить» — после.
    var source: ReportDraft.Source = .phone

    @State private var refusedFlash = false

    /// Сторона кнопки: крупнее «Стопа» рядом — по ней бьют вслепую.
    static let side: CGFloat = 56

    private var draft: ReportDraft { env.reports.draft }

    var body: some View {
        Button(action: tap) { label }
            .buttonStyle(PressableStyle())
            .disabled(draft.isInFlight)
            .motionAnimation(Motion.quick, value: draft.choosing != nil)
            .motionAnimation(.easeOut(duration: 0.25), value: refusedFlash)
            .accessibilityLabel(Text("Отметить"))
            .accessibilityHint(Text("Открывает выбор: тренога, пост ДПС или ДТП. Без выбора через 3 секунды — тренога"))
            // VoiceOver пальцем по плиткам не ведёт: для него типы — действия.
            .accessibilityActions {
                ForEach(ReportKind.chosenOnTheGo) { kind in
                    Button { Task { await env.reports.report(kind, from: source) } } label: {
                        Text(kind.reportTitleKey)
                    }
                }
            }
    }

    private var label: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                .fill(refusedFlash ? Theme.textTertiary : Theme.action)
            if draft.isInFlight {
                ProgressView().controlSize(.small).tint(Theme.onAction)
            } else {
                VStack(spacing: 2) {
                    content
                }
                .foregroundStyle(refusedFlash ? Color.white : Theme.onAction)
                .padding(.horizontal, 3)
            }
        }
        .frame(width: Self.side, height: Self.side)
    }

    @ViewBuilder private var content: some View {
        if refusedFlash {
            Image(systemName: "xmark").font(.system(size: 18, weight: .bold))
        } else if draft.choosing != nil {
            // Выбор открыт: второе касание — тренога сразу; кнопка это и говорит.
            CameraGlyphView(glyph: CameraType.tripod.glyph, ink: Theme.onAction, side: 20)
            Text(ReportKind.tripod.reportTitleKey)
                .font(.system(size: 10, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Image(systemName: Icon.reportRadar)
                .font(.system(size: 17, weight: .bold))
            // Слово всегда: жёлтый квадрат с волнами без слова не читается
            // кнопкой «отметить» (владелец назвал волны «AirPlay», 21.10).
            Text("Отметить")
                .font(.system(size: 10, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func tap() {
        // Тактильный отклик СРАЗУ, до точки и сети: касание засчитано.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let answer = await env.reports.begin(from: source)
            switch answer {
            case .done(let outcome) where !outcome.isSuccess:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                // Отказ (нет точки, стоим, дубль) — вспышка ✗; ушедшую
                // отметку показывает плашка «Отменить».
                if case .refused = outcome {
                    refusedFlash = true
                    await Task.pause(seconds: AppConfig.reportFlashSeconds)
                    refusedFlash = false
                }
            case .done:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .busy, .choosing, .cancelled:
                break
            }
        }
    }
}

extension ReportKind {
    /// Короткое имя по словарю (ReportWords.title) ключом каталога — чтобы
    /// превью и экран следовали языку окружения.
    var reportTitleKey: LocalizedStringKey {
        switch self {
        case .radar:    return "Радар"
        case .tripod:   return "Тренога"
        case .post:     return "Пост ДПС"
        case .accident: return "ДТП"
        case .closure:  return "Перекрыто"
        case .roadwork: return "Ремонт"
        }
    }

    /// «Тренога отмечена» — род у каждого типа свой (ReportWords.marked).
    var markedKey: LocalizedStringKey {
        switch self {
        case .radar:    return "Радар отмечен"
        case .tripod:   return "Тренога отмечена"
        case .post:     return "Пост ДПС отмечен"
        case .accident: return "ДТП отмечено"
        case .closure, .roadwork: return "Отмечено"
        }
    }

    /// Заливка и знак: у дороги — свои, не красные (красный на этой карте —
    /// камера) и не цвет интерфейса.
    var tint: Color {
        switch self {
        case .closure:  return Theme.Icon.streak
        case .roadwork: return Theme.Icon.work
        default:        return cameraType.tint
        }
    }
    var glyphTint: Color {
        isRoadEvent ? .white : cameraType.glyphTint
    }
    /// Глиф камеры (29.C); nil — событие дороги со своим символом.
    var cameraGlyph: CameraGlyph? {
        isRoadEvent ? nil : cameraType.glyph
    }
}
