//
//  MapFrameState.swift
//  RadarMap
//
//  Поля карты главного экрана: какую долю высоты закрывают панели сверху и
//  снизу. По ним карта движка ставит «я» в видимую часть, а не под панель.
//
//  Раньше это жило в SketchState схемы, а высоту вида в него писала только
//  вью схемы. Спидометр (а с ним схема на телефоне) ушёл 11.10 — высоту
//  больше никто не ставил, поля навсегда оставались нулевыми, и «я» на карте
//  движка стоял по геометрии пустого экрана, не видя панелей. Теперь высоту
//  сообщает сама карта, а панели — хозяин экрана.
//

import SwiftUI

@MainActor
@Observable
final class MapFrameState {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у MapState.
    nonisolated deinit {}

    /// Поля вида в долях высоты. Наблюдаемы: от них зависит, где стоит «я».
    private(set) var insets = MapViewport.Insets.none

    /// Высота карты в пунктах и кромки панелей в пунктах окна приходят в
    /// разном порядке — хранятся оба, поля считаются, когда есть всё.
    @ObservationIgnored private var viewHeight: CGFloat = 0
    @ObservationIgnored private var panelTop: CGFloat = 0
    @ObservationIgnored private var panelBottom: CGFloat = 0

    /// Где стоит полоса хода маршрута (29.B), пункты окна; nil — места нет.
    /// Наблюдаема только полосой: меняется на смене панелей, не на тике.
    private(set) var rail: ClosedRange<Double>?

    /// Кромки для полосы: низ колонки кнопок и верх нижних панелей. Пишем
    /// только сдвиг от пункта — панели анимируются, и каждая запись будила бы
    /// полосу на каждом кадре анимации.
    func setRail(columnBottom: CGFloat, panelBottom: CGFloat) {
        let fresh = RouteProgressBar.frame(columnBottom: Double(columnBottom), panelBottom: Double(panelBottom),
                                           gap: AppConfig.routeRailGapPoints,
                                           minHeight: AppConfig.routeRailMinHeightPoints)
        switch (rail, fresh) {
        case (nil, nil): return
        case let (old?, new?) where abs(old.lowerBound - new.lowerBound) < 1
            && abs(old.upperBound - new.upperBound) < 1: return
        default: rail = fresh
        }
    }

    /// Карта измерила себя.
    func setViewHeight(_ height: CGFloat) {
        guard height != viewHeight else { return }
        viewHeight = height
        apply()
    }

    /// Хозяин экрана измерил панели: нижняя кромка верхней стопки и верхняя
    /// кромка нижней, в пунктах окна.
    func setPanelEdges(top: CGFloat, bottom: CGFloat) {
        panelTop = top
        panelBottom = bottom
        apply()
    }

    private func apply() {
        let fresh = Self.insets(viewHeight: viewHeight, panelTop: panelTop, panelBottom: panelBottom)
        // Пишем только на изменение: раскладка случается чаще, чем меняются
        // высоты, а каждая запись будит карту.
        if fresh != insets { insets = fresh }
    }

    /// Поля по замерам. Ноль снизу — «ещё не мерили», а не «панель во весь
    /// экран»: до первого замера поле обязано быть пустым, иначе первый же
    /// кадр сожмётся в треть экрана. Без высоты вида полей нет вовсе.
    /// Нижняя кромка, над которой карта держит «я»: выше из нижней стопки
    /// панелей и карточки предупреждения о камере. 0 у панели — «не мерили».
    nonisolated static func bottomEdge(panel: CGFloat, overlay: CGFloat?) -> CGFloat {
        guard let overlay, overlay > 0 else { return panel }
        return panel > 0 ? min(panel, overlay) : overlay
    }

    nonisolated static func insets(viewHeight: CGFloat, panelTop: CGFloat,
                                   panelBottom: CGFloat) -> MapViewport.Insets {
        guard viewHeight > 0 else { return .none }
        let height = Double(viewHeight)
        let bottom = panelBottom > 0 ? max(0, height - Double(panelBottom)) / height : 0
        return MapViewport.Insets(top: max(0, Double(panelTop)) / height, bottom: bottom)
    }
}
