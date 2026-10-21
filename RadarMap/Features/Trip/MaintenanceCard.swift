//
//  MaintenanceCard.swift
//  RadarMap
//
//  «Обслуживание» в «Итогах» (18.2): только когда что-то «скоро», «пора» или
//  просрочено — строка на пункт, самое срочное первым. Нет срочного — нет
//  карточки: «всё в порядке» каждый раз — шум, который учит не смотреть.
//  Тап — страница обслуживания.
//

import SwiftUI

struct MaintenanceCard: View {
    let states: [Maintenance.State]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Обслуживание")) {
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                ForEach(Array(states.enumerated()), id: \.element.id) { index, state in
                    if index > 0 { Divider().overlay(Theme.stroke) }
                    row(state)
                }
            }
            .statCard(padding: 14, radius: Theme.cornerMedium)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ state: Maintenance.State) -> some View {
        let title = Text(state.kind.title)
            .font(.rounded(15, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        let detail = Text(MaintenanceText.detail(state))
            .font(.rounded(12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.kind.symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(MaintenanceText.color(state.status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                // Название и состояние — строкой, пока влезают; на крупном
                // шрифте и узбекском состояние уходит под название.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        MaintenanceChip(state: state)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        MaintenanceChip(state: state)
                    }
                }
                detail
            }
        }
        // Метка кнопки центрирует то, что не во всю ширину: ряд, где состояние
        // ушло под название, съезжал к середине карточки.
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(MaintenanceText.spoken(state)))
    }
}
