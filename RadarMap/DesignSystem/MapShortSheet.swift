//
//  MapShortSheet.swift
//  RadarMap
//
//  Короткий лист над картой (33H3, 28.10, выбор владельца): тот же язык,
//  что у остальных листов над картой (CameraDetailSheet, NearbyCamerasSheet,
//  «Мои места»), — заголовок по центру строки навигации, «Готово» справа,
//  фон `Theme.background`, — но высотой ровно по содержимому, а не
//  medium/large: справка на три строки не должна открываться на полэкрана.
//
//  До этого листы пробок жили своим обликом: заголовок 20 pt слева, белая
//  поверхность, без «Готово», высота — числом на глаз (320 при содержимом
//  на 240 — внизу пустота).
//

import SwiftUI

struct MapShortSheet<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    /// Высота содержимого — мерится, лист подстраивается (uz длиннее ru).
    @State private var contentHeight: CGFloat = 0

    /// Строка навигации с заголовком и ручка листа над содержимым, точки.
    private static var chromeHeight: CGFloat { 64 }
    /// Пока содержимое не измерено — не выше половины SE.
    private static var fallbackHeight: CGFloat { 280 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(contentHeight > 0 ? contentHeight + Self.chromeHeight
                                                        : Self.fallbackHeight)])
        .presentationDragIndicator(.visible)
    }
}
