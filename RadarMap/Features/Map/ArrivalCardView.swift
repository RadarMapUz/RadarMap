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
                    .font(.dense(19, .bold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 46, height: 46)
                    .background(Theme.quietFill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вы на месте!")
                        .font(.dense(20, .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !arrival.name.isEmpty {
                        Text(arrival.name)
                            .font(.dense(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.dense(15, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Theme.background, in: Circle())
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
                    metric(Formatting.duration(env.trip.durationSeconds), String(localized: "в пути"))
                    divider
                    metric(Formatting.distance(env.trip.distanceMeters), String(localized: "путь"))
                    divider
                    metric("\(env.trip.camerasPassed)", Formatting.camerasLabel(env.trip.camerasPassed))
                }
                .padding(.vertical, 10)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }

            // Единственная «завершить» на экране: панель поездки с её «стоп»
            // на это время убрана (TripScreenLayout.showsTripBar).
            // На ходу — двумя касаниями, как «Стоп» в панели поездки: карточка
            // встаёт туда, где была «Радар!», и слепой тап по ней иначе
            // заканчивал поездку одним касанием. На стоянке — одним.
            if env.location.isTripActive {
                StopTripButton(wide: true) {
                    env.location.endTrip()
                    onDismiss()
                }
                // Кнопка — чтобы закрыть сразу, а не потому, что иначе поездка
                // не кончится: на стоянке у цели она закроется сама
                // (ArrivalFinish). 21.10 карточка молчала об этом, и поездку
                // закрыли рукой. В «Ручном» следить некому — и подписи нет.
                if env.location.arrivalWatch != nil {
                    Text("Завершится сама, когда машина встанет")
                        .font(.dense(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, -6)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
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

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.dense(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.dense(11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
    }
}
