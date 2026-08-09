//
//  TripEndCard.swift
//  RadarMap
//
//  «Поездка сохранена» — итог сразу после стопа.
//
//  Цифры поездки интереснее всего в момент, когда заглушён двигатель, — а
//  приложение молчало: итог был виден, только если самому открыть Итоги.
//  Карточка показывает главное (балл, путь, время, проезды камер и деньги)
//  и одним тапом ведёт в деталку. Если новая запись похожа на продолжение
//  предыдущей (заехал в магазин, по привычке нажал «Завершить») — склейка
//  предлагается прямо здесь, в момент, а не потом карточкой в списке.
//
//  Показывается только на переднем плане и только для свежесохранённой
//  записи (см. MapScreen.maybeShowTripEnd): автозавершение в кармане
//  обслуживает уведомление, а не карточка поверх карты, которую никто не видит.
//

import SwiftUI

struct TripEndCard: View {
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    var onDetail: (TripRecord) -> Void
    var onMerged: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                scoreBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text("Поездка сохранена")
                        .font(.rounded(17, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(moneyLine)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(moneyTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Скрыть итог поездки"))
            }

            HStack(spacing: 0) {
                metric(Formatting.distance(record.distanceMeters),
                       String(localized: "путь"))
                metricDivider
                metric(Formatting.duration(record.movingDuration),
                       String(localized: "в движении"))
                metricDivider
                metric("\(record.camerasPassed)", String(localized: "камер"))
            }
            .padding(.vertical, 10)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))

            if let previous = mergeCandidate {
                mergeRow(previous: previous)
            }

            Button {
                onDetail(record)
            } label: {
                HStack(spacing: 6) {
                    Text("Подробнее")
                        .font(.rounded(14, .bold))
                    Image(systemName: "chevron.right")
                        .font(.rounded(11, .bold))
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent.gradient, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(16)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Балл

    /// Кольцо с баллом поездки — тем же цветом, что в списках истории.
    @ViewBuilder private var scoreBadge: some View {
        if let score = record.score.map({ Int($0) }) {
            let tint = TripHistorySection.scoreColor(score)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.04, Double(score) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.rounded(16, .heavy).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .frame(width: 46, height: 46)
            .accessibilityLabel(Text(String(format: String(localized: "Балл поездки: %lld"), score)))
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.rounded(22, .bold))
                .foregroundStyle(Theme.success)
                .frame(width: 46, height: 46)
                .background(Theme.success.opacity(0.12), in: Circle())
        }
    }

    /// Одна честная строка про деньги: риск, если он есть, иначе «всё в лимите».
    private var moneyLine: String {
        let risk = TripHistory.fineRisk(of: record.passed)
        if risk > 0 {
            return String(format: String(localized: "риск ≈ %@"), Formatting.money(risk))
        }
        if record.camerasPassed > 0 {
            return String(format: String(localized: "Камер: %lld — все в лимите"),
                          record.camerasPassed)
        }
        return String(localized: "Без камер и превышений")
    }

    private var moneyTint: Color {
        TripHistory.fineRisk(of: record.passed) > 0 ? Theme.danger : Theme.success
    }

    // MARK: - Склейка «это продолжение прошлой»

    /// Предыдущая запись, если свежая выглядит её продолжением. Считается по
    /// тем же правилам, что карточка в Итогах, — здесь просто раньше по времени.
    private var mergeCandidate: TripRecord? {
        let history = env.trip.history
        guard history.count >= 2, history[0].id == record.id else { return nil }
        let previous = history[1]
        guard TripMerge.suggestsMerge(previous: previous, next: record,
                                      savedPlaces: env.settings.savedPlaceCoordinates)
        else { return nil }
        return previous
    }

    private func mergeRow(previous: TripRecord) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.snappy(duration: 0.35)) {
                env.trip.mergeWithPrevious(id: record.id)
                onMerged()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Похоже, это продолжение прошлой")
                        .font(.rounded(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "Объединить с поездкой в %@"),
                                previous.startedAt.formatted(date: .omitted, time: .shortened)))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
            .background(Theme.accent.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Метрики

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.rounded(16, .heavy).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.rounded(10, .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 26)
    }
}
