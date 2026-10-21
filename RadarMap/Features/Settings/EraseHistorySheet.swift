//
//  EraseHistorySheet.swift
//  RadarMap
//
//  Подтверждение «Удалить всю историю» (15.6) — лист, а не системный
//  confirmationDialog: в iOS 26 подтверждение с длинным сообщением — узкое
//  высокое облачко у кнопки, сплошной абзац, в котором не найти, что
//  сотрётся, а что останется. Здесь два коротких списка со значками и одна
//  строка о том, что вернуть нельзя. Один лист на оба места: Настройки →
//  «История поездок» и «Очистить историю» в меню «Итогов».
//

import SwiftUI

struct EraseHistorySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Месту, откуда открыли: удаление прошло (подпись «История удалена»).
    var onErased: () -> Void = {}

    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                group("Удалится", AppEnvironment.erasedLines, tint: Theme.danger)
                group("Останется", AppEnvironment.keptLines, tint: Theme.success)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(Self.opensAtEnd ? .bottom : nil)
        // Кнопки — внизу всегда, как у «Стереть iPhone»: четырнадцать строк
        // списков не должны стоять между человеком и «Отменой».
        .safeAreaInset(edge: .bottom) {
            actions
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                // Сплошной цвет края градиента (как в «Что нового»): радиальный
                // фон начался бы заново от верха полосы светлой ступенью.
                .background(Theme.background)
                // Строки уходят под полосу плавно — видно, что список длиннее,
                // а не обрезан посреди слова.
                .background(alignment: .top) {
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .offset(y: -24)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .background(Theme.screenBackground)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear {
            // С крупным шрифтом половина экрана — это заголовок и кнопки без
            // единой строки списка: сразу во весь рост.
            if typeSize >= .xxLarge { detent = .large }
            #if DEBUG
            // `-confirmErase -eraseSheetLarge` — во весь рост на снимок.
            if ProcessInfo.processInfo.arguments.contains("-eraseSheetLarge") { detent = .large }
            #endif
        }
    }

    /// DEBUG `-eraseSheetEnd` — список прокручен до «Останется», на снимок.
    #if DEBUG
    private static let opensAtEnd = ProcessInfo.processInfo.arguments.contains("-eraseSheetEnd")
    #else
    private static let opensAtEnd = false
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "trash", tint: Theme.danger, size: 44)
            Text("Удалить всю историю?")
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Список под заголовком. Для VoiceOver — группа: заголовок (ротор
    /// «Заголовки» прыгает по ним), за ним строки по одной; значок — только
    /// для глаза, цвет списка уже сказан заголовком.
    private func group(_ title: LocalizedStringKey, _ lines: [AppEnvironment.ErasureLine],
                       tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 {
                        Divider().padding(.leading, 40)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: line.symbol)
                            .font(.rounded(17, .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(line.text)
                            .font(.rounded(17))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 14)
            .statCard(padding: 0, radius: Theme.cornerMedium)
        }
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Text("Вернуть удалённое нельзя.")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            // Красная заливка под белым текстом — dangerFill (≥ 4,9:1 в обеих
            // темах, PaletteTests); жёлтый остаётся за главным действием
            // поездки, а не за удалением.
            PrimaryButton(title: "Удалить всю историю", systemImage: "trash", tint: Theme.dangerFill) {
                env.deleteAllHistory()
                onErased()
                dismiss()
            }
            SecondaryButton(title: "Отмена") { dismiss() }
        }
    }
}
