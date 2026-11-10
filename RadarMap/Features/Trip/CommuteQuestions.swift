//
//  CommuteQuestions.swift
//  RadarMap
//
//  Вопросы распорядка на экране «Дорога на работу»: срок «быть к 9:00» и
//  напоминания о выезде — по одному разу, когда есть о чём спросить.
//

import SwiftUI

/// «Вам нужно быть на работе к 9:00?» — один раз, когда распорядок уже
/// виден по поездкам (ArrivalTarget.suggestion). Без ответа «да» срока нет,
/// и призрак не говорит «позже срока» никогда.
struct ArrivalTargetQuestion: View {
    let minute: Int
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "clock.fill", tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: String(localized: "Вам нужно быть на работе к %@?"),
                                Formatting.clock(minuteOfDay: minute)))
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Тогда в дороге будет видно, успеваете ли: «с запасом» или «впритык». Срок останется на телефоне.")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "Нет", touch: .cancel) { onAnswer(false) }
                SecondaryButton(title: "Да", systemImage: "checkmark") { onAnswer(true) }
            }
        }
        .statCard()
    }
}

/// «Напоминать, когда выезжать?» — один раз, когда есть что напомнить:
/// выгодное время выезда или срок «быть к 9:00» (DepartureReminder).
struct DepartureReminderOffer: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(symbol: "bell.fill", tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Напоминать, когда выезжать?")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "По будням, за %lld мин до выезда — только когда выехать в другое время выгоднее или нужно успеть к сроку. По вашим поездкам, на телефоне."),
                                AppConfig.departureReminderLeadMinutes))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "Не нужно") { onAnswer(false) }
                SecondaryButton(title: "Напоминать", systemImage: "bell") { onAnswer(true) }
            }
        }
        .statCard()
    }
}
