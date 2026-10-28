//
//  IdleCameraChip.swift
//  RadarMap
//
//  Ближайшая камера на стоянке — чип 44 pt слева сверху (этап 31, выбор
//  владельца 26.10). Прежде здесь стоял тот же HUD, что за рулём, — карточка
//  76 pt на всю ширину, «469 м до камеры», когда машина стоит у дома. Стоя
//  смотрят на карту, а не на прибор; поехали — и сверху снова полный HUD со
//  скоростью и лимитом (MapScreen.topPanels).
//
//  Ночью чип не приглушается прозрачностью: HUD с opacity ≈ 0,61 выглядел
//  выключенным, серые цифры на графите. Ночная тема и так графитовая.
//

import SwiftUI

struct IdleCameraChip: View {
    var body: some View {
        // Содержимое — тот же NearestCameraReadout, что в HUD поездки (33H3):
        // одна цифра, одна подпись, красный и полоса — только в оповещении.
        NearestCameraReadout(compact: true)
            .padding(.leading, 7).padding(.trailing, 14).padding(.vertical, 5)
            .frame(minHeight: Theme.controlSize)
            .liftedBackground(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.edgePanel, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
