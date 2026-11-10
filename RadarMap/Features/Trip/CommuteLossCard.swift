//
//  CommuteLossCard.swift
//  RadarMap
//
//  «Где ушло время» последней поездки (CommuteLoss, 8.8.8): до трёх улиц с
//  минутами сверх обычного в это время, отдельной строкой — край пути
//  («у работы, до выезда на дорогу»: стоянка и ворота, не пробка; разбор
//  10.11), и раскрывающееся «Как это работает» — метод в четырёх строках.
//  Минуты — тревожным цветом, не красным: красный — камера и штраф.
//

import SwiftUI

/// Место, где поездка потеряла время, — с подписью из своего адресника.
struct CommuteLossPlace: Identifiable, Equatable {
    let id: Int
    /// Улица; nil — в адреснике рядом ничего (подписью станет расстояние).
    let street: String?
    /// Начало и конец места по пути, м от начала (после слияния по
    /// улице — от первого отрезка до последнего).
    let startMeters: Double
    let endMeters: Double
    let lostSeconds: Double

    /// Середина места от начала пути, м.
    var fromStart: Double { (startMeters + endMeters) / 2 }
    var lostMinutes: Int { max(1, Int((lostSeconds / 60).rounded())) }

    /// Два медленных отрезка одной улицы — одно место (34): время
    /// складывается, протяжённость — от первого до последнего.
    static func merged(_ places: [CommuteLossPlace]) -> [CommuteLossPlace] {
        PlaceMerge.byStreet(places, street: \.street) { lhs, rhs in
            CommuteLossPlace(id: lhs.id, street: lhs.street,
                             startMeters: min(lhs.startMeters, rhs.startMeters),
                             endMeters: max(lhs.endMeters, rhs.endMeters),
                             lostSeconds: lhs.lostSeconds + rhs.lostSeconds)
        }
        .sorted { $0.lostSeconds > $1.lostSeconds }
    }
}

struct CommuteLossCard: View {
    let direction: Commute.Direction
    let lastDeparture: Date
    let places: [CommuteLossPlace]
    /// Сверх обычного у начала и конца пути, с (CommuteLoss.Report).
    let leaving: Double
    let arriving: Double

    var isEmpty: Bool { places.isEmpty && leaving <= 0 && arriving <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(symbol: "hourglass", tint: Theme.textSecondary, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Где ушло время")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "Последняя поездка, %@ · сверх обычного в это время"),
                                CommuteCard.dayLine(lastDeparture).lowercased()))
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(places) { place in
                row(title: place.street ?? fromStartText(place.fromStart),
                    caption: place.street != nil ? fromStartText(place.fromStart) : nil,
                    minutes: place.lostMinutes, tint: Theme.warning)
            }
            if leaving > 0 {
                row(title: direction == .toHome ? String(localized: "У работы, до выезда на дорогу")
                                                : String(localized: "У дома, до выезда на дорогу"),
                    caption: String(localized: "Стоянка, прогрев, ворота — не пробка"),
                    minutes: Self.minutes(leaving), tint: Theme.textSecondary)
            }
            if arriving > 0 {
                row(title: direction == .toHome ? String(localized: "У дома, подъезд и парковка")
                                                : String(localized: "У работы, подъезд и парковка"),
                    caption: String(localized: "Поиск места — не пробка"),
                    minutes: Self.minutes(arriving), tint: Theme.textSecondary)
            }
            SettingsExplainer([
                "Путь делим на участки по 200 м и сравниваем с вашими поездками по этой дороге в это же время: ±2 часа, будни отдельно от выходных.",
                "Участок медленный, если вы ехали его дольше, чем в трёх поездках из четырёх. Минуты — сколько ушло сверх обычного.",
                "Остановки по дороге — магазин, заправка — не считаем.",
                "Первые и последние 400 м — стоянка и выезд, а не дорога: их время показано отдельно.",
            ])
        }
        .statCard()
    }

    private func row(title: String, caption: String?, minutes: Int, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(Formatting.unbreakable(String(format: String(localized: "%@ мин"), "+\(minutes)")))
                .font(.rounded(15, .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded())) }

    /// «1,5 км от дома» — где на пути это место, если улицы рядом не нашлось.
    private func fromStartText(_ meters: Double) -> String {
        Self.fromStartText(meters, direction: direction)
    }

    static func fromStartText(_ meters: Double, direction: Commute.Direction) -> String {
        let distance = Formatting.distance(meters)
        return direction == .toWork ? String(localized: "\(distance) от дома")
                                    : String(localized: "\(distance) от работы")
    }
}
