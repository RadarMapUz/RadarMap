//
//  ParkedCarChip.swift
//  RadarMap
//
//  «Машина · 350 м» со стрелкой (12б.1). Капсула, а не карточка: над ней
//  может стоять «Домой», и вторая полноразмерная строка съела бы низ карты.
//  Стрелка смотрит туда же, где метка машины на карте (азимут минус поворот карты):
//  в режиме «по компасу» карта крутится за телефоном, и стрелка становится
//  компасной сама — без отдельного запроса к магнитометру.
//
//  Подсказку читает только эта капсула — `parkedCarHint` меняется ступенями
//  по 10 м, пока человек идёт, и главный экран из-за неё не пересобирается.
//

import SwiftUI

struct ParkedCarChip: View {
    @Environment(AppEnvironment.self) private var env
    let map: MapState

    var body: some View {
        if let hint = env.location.parkedCarHint, let spot = env.location.parkedCarOnMap {
            Button {
                map.center(on: spot.coordinate)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .font(.dense(11, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.accentFill, in: Circle())
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "Машина · %@"), Formatting.distance(hint.meters)))
                        .font(.dense(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "location.north.fill")
                        .font(.dense(13, .bold))
                        .foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(ParkedCar.arrowRotation(bearing: hint.bearing,
                                                                         mapDirection: map.displayedDirection)))
                        .accessibilityHidden(true)
                }
                .padding(.leading, 8)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
                .liftedBackground(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
                // Капсула 38 pt, мишень — 44 (правило 22): растёт только
                // область касания, капсула остаётся своего размера.
                .tapTarget()
            }
            .buttonStyle(PressableStyle())
            // Голосом — словами: «До машины 330 метров», а не «Машина в 330 м».
            .accessibilityLabel(Text(String(format: String(localized: "До машины %@"),
                                            SpokenUnits.distance(hint.meters))))
            .accessibilityHint(Text("Показать на карте"))
            // «Забыть» живёт в долгом нажатии — жесте, которого у VoiceOver
            // нет: то же действие кладём в ротор действий.
            .accessibilityAction(named: Text("Забыть место")) {
                env.location.forgetParkedCar()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .contextMenu {
                Button {
                    env.location.forgetParkedCar()
                } label: {
                    Label("Забыть место", systemImage: "xmark.circle")
                }
            }
        }
    }
}
