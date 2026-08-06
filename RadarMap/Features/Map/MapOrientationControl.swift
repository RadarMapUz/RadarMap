//
//  MapOrientationControl.swift
//  RadarMap
//
//  Одна кнопка вместо трёх: как карта соотносится с миром.
//
//  Раньше этим управляли системный компас (висел ВСЕГДА — даже при севере
//  вверху, когда он не значит ничего, и выглядел деталью из чужого набора
//  рядом с нашими стеклянными кругами), кнопка «моё местоположение» и кнопка
//  «по ходу движения», появлявшаяся только в поездке. Три контрола об одном
//  и том же занимали правый угол карты.
//
//  Состояние читается по иконке и цвету, как в Apple Maps:
//      свободна → следование → поворот
//

import SwiftUI

struct MapOrientationControl: View {
    let orientation: MapState.Orientation
    let action: () -> Void

    var body: some View {
        CircleControl(systemName: symbol, tint: tint, accessibilityLabel: label, action: action)
    }

    private var symbol: String {
        switch orientation {
        case .free:      return "location"
        case .following: return "location.fill"
        case .heading:   return "location.north.line.fill"
        }
    }

    private var tint: Color {
        orientation == .free ? Theme.textPrimary : Theme.accent
    }

    private var label: LocalizedStringKey {
        switch orientation {
        case .free:      return "Моё местоположение"
        case .following: return "Карта следует за вами"
        case .heading:   return "Карта по ходу движения"
        }
    }
}
