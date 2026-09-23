//
//  ArrivalCardView.swift
//  RadarMap
//
//  Карточка «Вы на месте»: итоги пути в момент прибытия к цели маршрута.
//

import SwiftUI

struct ArrivalCardView: View {
    @Environment(AppEnvironment.self) private var env
    let arrival: RouteService.ArrivalSummary
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            card
                .padding(.horizontal, 20)
                .padding(.bottom, 90)
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.opacity(0.45).ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        // Для VoiceOver тап по фону не существует: даём карточке имя, трейт
        // кнопки и действие закрытия (иначе спасало только автозакрытие).
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Вы на месте"))
        .accessibilityHint(Text("Закрывает карточку прибытия"))
        .accessibilityAction { onDismiss() }
        .onAppear {
            withMotion(.spring(duration: 0.45, bounce: 0.35)) { appeared = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .task {
            // Сам исчезает: водителю не до кнопок.
            await Task.pause(seconds: 12)
            onDismiss()
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.16)).frame(width: 74, height: 74)
                Image(systemName: "flag.checkered")
                    .font(.rounded(30, .bold))
                    .foregroundStyle(Theme.success)
            }
            VStack(spacing: 4) {
                Text("Вы на месте!")
                    .font(.rounded(22, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                if !arrival.name.isEmpty {
                    Text(arrival.name)
                        .font(.rounded(14, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            if env.trip.distanceMeters > 0 {
                HStack(spacing: 0) {
                    metric(Formatting.duration(env.trip.durationSeconds), "в пути")
                    divider
                    metric(Formatting.distance(env.trip.distanceMeters), "путь")
                    divider
                    metric("\(env.trip.camerasPassed)", "камер")
                }
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }

            if env.location.isTripActive {
                Button {
                    env.location.endTrip()
                    onDismiss()
                } label: {
                    Text("Завершить поездку")
                        .font(.rounded(16, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.danger, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }

    private func metric(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.rounded(17, .bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.rounded(11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
    }
}
