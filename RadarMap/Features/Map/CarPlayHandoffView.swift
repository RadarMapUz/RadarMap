//
//  CarPlayHandoffView.swift
//  RadarMap
//
//  Экран телефона, пока едет CarPlay: чёрный фон вместо живой карты.
//
//  Пока водитель смотрит на экран машины, телефон зря рисовал MapKit со
//  всеми маркерами — тот же самый дорогой рендер, только в держателе и без
//  зрителя. Картинка в машину стримится с телефона, так что карта на двух
//  экранах — двойной нагрев ровно там, где солнце. Так делают все большие
//  навигаторы: телефон показывает заставку, машина — карту.
//
//  Кнопка возврата — для пассажира: настройки, поиск и Итоги живут на
//  телефоне. Выбор действует до отключения CarPlay.
//

import SwiftUI

struct CarPlayHandoffView: View {
    @Environment(AppEnvironment.self) private var env
    /// «Открыть карту на телефоне» — до конца сессии CarPlay (сбрасывает RootView).
    var onShowMap: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "car.side.rear.and.exclamationmark.and.car.side.front")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 6)
                Text("Едем в CarPlay")
                    .font(.rounded(26, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("Карта и предупреждения — на экране машины.\nТелефон отдыхает и не греется.")
                    .font(.rounded(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if env.location.isTripActive, let started = env.trip.startedAt {
                    HStack(spacing: 8) {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.rounded(17, .heavy).monospacedDigit())
                            .foregroundStyle(Theme.success)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(Formatting.distance(env.trip.distanceMeters))
                            .font(.rounded(15, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                    .padding(.top, 10)
                }

                Spacer()

                Button(action: onShowMap) {
                    Text("Открыть карту на телефоне")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Theme.surface.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 32)
        }
    }
}
