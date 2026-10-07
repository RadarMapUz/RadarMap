//
//  ArrivalCardView.swift
//  RadarMap
//
//  Карточка «Вы на месте»: итоги пути в момент прибытия к цели маршрута.
//
//  Стоит ВМЕСТО нижней панели поездки, а не поверх экрана. Раньше она
//  висела над всем, закрывала кнопки справа, а снизу одновременно оставалась
//  панель поездки со своим «стоп» — две кнопки «завершить» на одном экране
//  (docs/plan_drive_ux_2026-10-07.md, п. 6). Теперь кнопка одна — здесь;
//  где карточку показывать, решает TripScreenLayout.
//

import SwiftUI

struct ArrivalCardView: View {
    @Environment(AppEnvironment.self) private var env
    let arrival: RouteService.ArrivalSummary
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.rounded(19, .bold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 46, height: 46)
                    .background(Theme.success.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вы на месте!")
                        .font(.rounded(20, .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !arrival.name.isEmpty {
                        Text(arrival.name)
                            .font(.rounded(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.rounded(15, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surface, in: Circle())
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Закрыть"))
                .accessibilityHint(Text("Закрывает карточку прибытия"))
            }
            .accessibilityElement(children: .contain)

            // Те же цифры, что в панели поездки и в «Поездка сохранена»: одна
            // живая сессия (env.trip), а не свой пересчёт.
            if env.trip.distanceMeters > 0 {
                HStack(spacing: 0) {
                    metric(Formatting.duration(env.trip.durationSeconds), "в пути")
                    divider
                    metric(Formatting.distance(env.trip.distanceMeters), "путь")
                    divider
                    metric("\(env.trip.camerasPassed)", "камер")
                }
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }

            // Единственная «завершить» на экране: панель поездки с её «стоп»
            // на это время убрана (TripScreenLayout.showsTripBar).
            if env.location.isTripActive {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    env.location.endTrip()
                    onDismiss()
                } label: {
                    Text("Завершить поездку")
                        .font(.rounded(16, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .background(Theme.danger, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .liftPanel()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .task {
            // Сам исчезает: водителю не до кнопок. Панель поездки вернётся на
            // своё место, и «стоп» снова будет в ней.
            await Task.pause(seconds: 12)
            onDismiss()
        }
    }

    private func metric(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.rounded(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.rounded(11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
    }
}
