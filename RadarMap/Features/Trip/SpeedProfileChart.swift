//
//  SpeedProfileChart.swift
//  RadarMap
//
//  Профиль скорости поездки: площадь + линия по километрам, проезды камер
//  на кривой, интерактивная линейка (тап/протяжка). Данные считаются из трека
//  (≤400 точек — доля миллисекунды), график статичный.
//

import SwiftUI
import Charts

struct SpeedProfileChart: View {
    let record: TripRecord
    /// Выбранная точка профиля (тап/протяжка по графику).
    @State private var selectedKm: Double?

    struct SpeedSample: Identifiable {
        let id: Int
        let km: Double
        let speedKmh: Double
    }

    struct PassMark: Identifiable {
        let id: UUID
        let km: Double
        let speedKmh: Double
        let color: Color
        /// Превышение. Второй носитель состояния: на точке 11 pt глиф не
        /// читается, поэтому различает ФОРМА — залитая точка против кольца.
        /// Цвет остаётся, но перестаёт быть единственным (см. Theme.symbol).
        let isOver: Bool
    }

    /// Профиль скорости: дистанция вдоль трека → скорость (точки трека уже прорежены,
    /// ≤400 штук — считается за долю миллисекунды, график статичный).
    private func speedSamples() -> [SpeedSample] {
        let points = record.trackPoints
        guard points.count >= 2 else { return [] }
        var samples: [SpeedSample] = [SpeedSample(id: 0, km: 0, speedKmh: points[0].speedKmh)]
        samples.reserveCapacity(points.count)
        var meters = 0.0
        for i in 1..<points.count {
            meters += GeoMath.fastDistance(points[i - 1].lat, points[i - 1].lon,
                                           points[i].lat, points[i].lon)
            samples.append(SpeedSample(id: i, km: meters / 1000, speedKmh: points[i].speedKmh))
        }
        return samples
    }

    /// Проезды камер на профиле: точка ставится у ближайшей точки трека
    /// и лежит на самой линии (высота — скорость трека в этом месте),
    /// а цвет — честный, по скорости в момент проезда относительно лимита.
    private func passMarks(on samples: [SpeedSample]) -> [PassMark] {
        let points = record.trackPoints
        guard points.count == samples.count, !points.isEmpty else { return [] }
        return record.passed.compactMap { pass in
            guard let lat = pass.lat, let lon = pass.lon else { return nil }
            var bestIndex = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, point) in points.enumerated() {
                let d = GeoMath.fastDistance(lat, lon, point.lat, point.lon)
                if d < bestDistance { bestDistance = d; bestIndex = index }
            }
            return PassMark(id: pass.id,
                            km: samples[bestIndex].km,
                            speedKmh: samples[bestIndex].speedKmh,
                            color: PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh),
                            isOver: PassStyle.symbol(speed: pass.speedKmh,
                                                     limit: pass.limitKmh) != nil)
        }
    }

    /// Профиль считается один раз на поездку, а не в body: линейка под пальцем
    /// меняет @State и прогоняет body десятки раз в секунду, а трек при этом
    /// не меняется никогда — он у записи в истории уже закрыт.
    @State private var samples: [SpeedSample] = []
    /// Метки камер на графике — вместе с выборкой, а не в body: касание
    /// графика пересобирает body на каждом сдвиге пальца, а поиск ближайшей
    /// точки трека для каждой камеры — это проезды × точки (6.5).
    @State private var marks: [PassMark] = []

    var body: some View {
        Group {
        if samples.count >= 8 {
            let topSpeed = samples.map(\.speedKmh).max() ?? 60
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "Скорость по маршруту")) {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap.fill").font(.rounded(9))
                        Text("коснитесь графика").font(.rounded(10))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }

                Chart {
                    ForEach(samples) { sample in
                        AreaMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                Theme.route.opacity(0.14)
                            )
                        LineMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            // Один цвет маршрута (палитра А): переход в индиго
                            // читался «вторым типом», а индиго — цвет камеры.
                            .foregroundStyle(Theme.route)
                    }
                    ForEach(marks) { mark in
                        PointMark(x: .value("км", mark.km), y: .value("км/ч", mark.speedKmh))
                            .symbol {
                                ZStack {
                                    if mark.isOver {
                                        Circle().fill(mark.color)
                                    } else {
                                        Circle().fill(Theme.background)
                                        Circle().strokeBorder(mark.color, lineWidth: 3)
                                    }
                                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                                }
                                .frame(width: 11, height: 11)
                            }
                    }
                    // Линейка: тап или протяжка — скорость в этой точке маршрута.
                    if let selectedKm, let sample = nearestSample(to: selectedKm, in: samples) {
                        RuleMark(x: .value("км", sample.km))
                            .foregroundStyle(Theme.textTertiary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(spacing: 1) {
                                    Text("\(Int(sample.speedKmh)) км/ч")
                                        .font(.rounded(12, .bold).monospacedDigit())
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(String(format: String(localized: "%@ км"), Formatting.decimal(sample.km)))
                                        .font(.rounded(9, .medium))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Theme.background.opacity(0.92),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.stroke, lineWidth: 1))
                            }
                        PointMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .symbolSize(120)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .chartXSelection(value: $selectedKm)
                // Запас сверху — пузырёк линейки не упирается в край графика.
                .chartYScale(domain: 0...max(topSpeed * 1.25, 20))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Theme.stroke.opacity(0.35))
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text(String(format: String(localized: "%.0f км"), km))
                            }
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .font(.rounded(9, .medium))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.stroke.opacity(0.6))
                        AxisValueLabel()
                            .foregroundStyle(Theme.textTertiary)
                            .font(.rounded(10, .medium))
                    }
                }
                .frame(height: 150)

                // Точки — проезды камер, цвет по честности относительно лимита.
                HStack(spacing: 12) {
                    chartLegendDot(Theme.success, "в лимите")
                    chartLegendDot(Theme.warning, "слегка выше")
                    chartLegendDot(Theme.danger, "превышение")
                    Spacer(minLength: 0)
                }
            }
            .statCard()
        }
        }
        .task(id: record.id) {
            let built = speedSamples()
            samples = built
            marks = passMarks(on: built)
        }
    }

    private func nearestSample(to km: Double, in samples: [SpeedSample]) -> SpeedSample? {
        samples.min { abs($0.km - km) < abs($1.km - km) }
    }

    private func chartLegendDot(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

}
