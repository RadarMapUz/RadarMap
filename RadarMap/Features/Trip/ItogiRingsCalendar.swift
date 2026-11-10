//
//  ItogiRingsCalendar.swift
//  RadarMap
//
//  Месяцы кольцами: внешнее — аккуратность, внутреннее — пробег, точка —
//  штраф или идеальный день. Лист всегда тёмный: цвета колец держатся на
//  тёмном поле и не зависят от темы.
//

import SwiftUI

struct ItogiRingsCalendar: View {
    let days: [TripDay]
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var months: [ItogiCalendar.Month] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(months) { month in
                        monthView(month)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .top, spacing: 0) { weekdays }
            .safeAreaInset(edge: .bottom, spacing: 0) { legend }
            .background(Theme.Stats.ringGround)
            .navigationTitle("Календарь поездок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task(id: days) {
            months = ItogiCalendar.months(days: days, now: Date())
        }
    }

    private var weekdays: some View {
        var calendar = Calendar.current
        calendar.locale = NumberFormat.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[1...]) + [symbols[0]]
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Stats.ringGround)
        .accessibilityHidden(true)
    }

    private func monthView(_ month: ItogiCalendar.Month) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(month.start.formatted(.dateTime.month(.wide).year().locale(NumberFormat.locale)))
                .font(.rounded(20, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<month.leading, id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(month.cells) { cell in
                    dayCell(cell)
                }
            }
        }
    }

    private func dayCell(_ cell: ItogiCalendar.Cell) -> some View {
        let isToday = Calendar.current.isDateInToday(cell.day)
        return Button {
            guard cell.ring != nil else { return }
            dismiss()
            onPick(cell.day)
        } label: {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: cell.day))")
                    .font(.rounded(15, isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.black : Color.white.opacity(cell.isFuture ? 0.4 : 0.92))
                    .frame(width: 26, height: 26)
                    .background(isToday ? Theme.action : Color.clear, in: Circle())
                ItogiDayRing(ring: cell.ring, dimmed: cell.isFuture)
                    .frame(width: 42, height: 42)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(cell.ring == nil)
        .accessibilityLabel(Text(Formatting.dayTitle(cell.day)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(Theme.Stats.ringCalm.first ?? Theme.success, "Аккуратность")
            legendDot(Theme.Stats.ringRoad.first ?? Theme.Stats.commute, "Пробег")
            legendDot(Theme.action, "Идеально")
            legendDot(Theme.danger, "Штраф")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.Stats.ringGround)
    }

    private func legendDot(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.rounded(12, .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Два кольца дня и точка в углу.
struct ItogiDayRing: View {
    let ring: ItogiCalendar.Ring?
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let width = side * 0.14
            ZStack(alignment: .topTrailing) {
                ZStack {
                    arc(value: ring?.score.map { Double($0) / 100 } ?? 0, colors: scoreColors, width: width, inset: 0)
                    arc(value: ring?.road ?? 0, colors: Theme.Stats.ringRoad, width: width, inset: width * 1.35)
                }
                .opacity(dimmed ? 0.45 : 1)
                if let ring, ring.fine || ring.perfect {
                    Circle()
                        .fill(ring.fine ? Theme.danger : Theme.action)
                        .frame(width: side * 0.2, height: side * 0.2)
                        .offset(x: side * 0.05, y: -side * 0.05)
                }
            }
        }
    }

    private var scoreColors: [Color] {
        guard let score = ring?.score else { return Theme.Stats.ringCalm }
        switch DrivingScore.tier(for: score) {
        case 2:  return Theme.Stats.ringCalm
        case 1:  return Theme.Stats.ringWatch
        default: return Theme.Stats.ringRisk
        }
    }

    private func arc(value: Double, colors: [Color], width: CGFloat, inset: CGFloat) -> some View {
        ZStack {
            Circle().stroke((colors.last ?? .white).opacity(0.2), lineWidth: width)
            if value > 0 {
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(AngularGradient(colors: colors + [colors.first ?? .white], center: .center),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(width / 2 + inset)
    }
}
