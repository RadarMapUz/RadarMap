//
//  ReportChoiceBar.swift
//  RadarMap
//
//  Над панелью поездки после «Отметить» — выбор типа, а после отправки —
//  «Отменить» (вариант B, 02.11). Обе плашки только показывают черновик
//  (`env.reports.draft`): сроки, отправку и голос ведёт ReportFlow.
//
//  Плитки ≈ 100×94 pt во всю ширину (на SE ≈ 90): Тренога — выбрана, кольцо
//  с отсчётом и цифрой, — Пост ДПС, ДТП и узкий «✕». У любой временной
//  плашки над панелью — видимый отсчёт (спецификация): без него трёхсекундный
//  выбор читается как случайное окно.
//

import SwiftUI

/// Гейт над панелью поездки: выбор или «Отменить» — по фазе черновика.
struct ReportDraftGate: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let flow = env.reports
        Group {
            switch flow.draft.phase {
            case .choosing(_, let deadline, let silence):
                ReportChoiceTiles(deadline: deadline, total: AppConfig.reportChooseSeconds,
                                  countsDown: silence == .tripod,
                                  onPick: { kind in
                                      UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                      flow.choose(kind)
                                  },
                                  onCancel: {
                                      UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                      flow.cancelChoice()
                                  })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .sent(let sent):
                ReportUndoCard(kind: sent.kind, queued: sent.queued, until: sent.undoUntil,
                               canUndo: flow.canUndo(),
                               onUndo: {
                                   UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                   Task { await flow.undo() }
                               })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .idle, .sending:
                EmptyView()
            }
        }
        .motionAnimation(Motion.standard, value: flow.draft.serial)
        .motionAnimation(Motion.standard, value: flow.draft.phase == .idle)
    }
}

/// Три плитки и «✕». Чистая вью: без окружения — для превью на 375 pt.
struct ReportChoiceTiles: View {
    let deadline: Date
    let total: TimeInterval
    /// Молчание отправит треногу — кольцо и цифра идут. Выбор, который ничего
    /// не отправит сам (сетка машины), отсчёта треноги не показывает.
    var countsDown = true
    let onPick: (ReportKind) -> Void
    let onCancel: () -> Void

    /// Высота плитки: макет B (≈ 94 pt) — крупная цель для второго касания.
    static let tileHeight: CGFloat = 94
    static let cancelWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.rounded(18, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Self.cancelWidth, height: Self.tileHeight)
                    .background(Theme.quietFill,
                                in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("Не отмечать"))
            ForEach(ReportKind.chosenOnTheGo) { kind in
                tile(kind)
            }
        }
        .padding(8)
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
    }

    private func tile(_ kind: ReportKind) -> some View {
        let isDefault = kind == ReportDraft.defaultKind && countsDown
        return Button { onPick(kind) } label: {
            VStack(spacing: 6) {
                if let glyph = kind.cameraGlyph {
                    CameraGlyphView(glyph: glyph, ink: kind.glyphTint, side: 30)
                }
                Text(kind.reportTitleKey)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(kind.glyphTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.tileHeight)
            .background(kind.tint, in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
            .overlay {
                if isDefault { countdown }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(kind.reportTitleKey))
        .accessibilityHint(isDefault ? Text("Выбрано: уйдёт само через 3 секунды") : Text(verbatim: ""))
    }

    /// Кольцо выбранной плитки тает к нулю; цифра — сколько секунд осталось.
    /// Анимация только эти три секунды и только на одной плитке.
    private var countdown: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let left = max(0, deadline.timeIntervalSince(context.date))
            let share = total > 0 ? left / total : 0
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: Theme.cornerControl + 3, style: .continuous)
                    .stroke(Theme.action.opacity(0.3), lineWidth: 3)
                RoundedRectangle(cornerRadius: Theme.cornerControl + 3, style: .continuous)
                    .trim(from: 0, to: share)
                    .stroke(Theme.action, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Text(verbatim: "\(Int(left.rounded(.up)))")
                    .font(.rounded(12, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.onAction)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Theme.action, in: Capsule())
                    .padding(5)
            }
            .padding(-3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// «Тренога отмечена · Отменить» — 8 с, с полосой отсчёта.
struct ReportUndoCard: View {
    let kind: ReportKind
    let queued: Bool
    let until: Date
    let canUndo: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.rounded(26, .bold))
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.markedKey)
                    .font(.rounded(16, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Group {
                    if queued { Text("Уйдёт, когда появится связь") } else { Text("Увидят другие водители") }
                }
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if canUndo {
                Button(action: onUndo) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.rounded(15, .bold))
                        Text("Отменить")
                            .font(.rounded(15, .bold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 120, minHeight: 52)
                    .background(Theme.quietFill,
                                in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text("Отменить мою отметку"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { timer }
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
    }

    /// Полоса по низу — сколько окна осталось. Обновляется раз в 0,2 с:
    /// восемь секунд, одна полоса.
    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let share = max(0, min(1, until.timeIntervalSince(context.date) / AppConfig.reportUndoSeconds))
            GeometryReader { proxy in
                Rectangle()
                    .fill(Theme.successFill.opacity(0.8))
                    .frame(width: proxy.size.width * share, height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Превью: SE (375 pt), ru/uz, день/ночь

private struct ReportBarsPreview: View {
    let locale: String
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 12) {
            ReportChoiceTiles(deadline: Date().addingTimeInterval(2.4), total: 3,
                              onPick: { _ in }, onCancel: {})
            ReportUndoCard(kind: .tripod, queued: false, until: Date().addingTimeInterval(6),
                           canUndo: true, onUndo: {})
            ReportUndoCard(kind: .post, queued: true, until: Date().addingTimeInterval(3),
                           canUndo: true, onUndo: {})
        }
        .padding(12)
        .frame(width: 375)
        .background(Theme.background)
        .environment(\.locale, Locale(identifier: locale))
        .environment(\.colorScheme, scheme)
    }
}

#Preview("SE · ru · день") { ReportBarsPreview(locale: "ru", scheme: .light) }
#Preview("SE · ru · ночь") { ReportBarsPreview(locale: "ru", scheme: .dark) }
#Preview("SE · uz · день") { ReportBarsPreview(locale: "uz", scheme: .light) }
#Preview("SE · uz · ночь") { ReportBarsPreview(locale: "uz", scheme: .dark) }
