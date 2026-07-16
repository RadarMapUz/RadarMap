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
                            color: PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh))
        }
    }

    var body: some View {
        let samples = speedSamples()
        if samples.count >= 8 {
            let topSpeed = samples.map(\.speedKmh).max() ?? 60
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Скорость по маршруту")
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
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
                                LinearGradient(colors: [Theme.accent.opacity(0.30), .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        LineMark(x: .value("км", sample.km), y: .value("км/ч", sample.speedKmh))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.accent, Theme.intelligent],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                    }
                    ForEach(passMarks(on: samples)) { mark in
                        PointMark(x: .value("км", mark.km), y: .value("км/ч", mark.speedKmh))
                            .symbol {
                                ZStack {
                                    Circle().fill(mark.color)
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
                                    Text(String(format: String(localized: "%.1f км"), locale: .current, sample.km))
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
                    chartLegendDot(Theme.radar, "слегка выше")
                    chartLegendDot(Theme.danger, "превышение")
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
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
