//
//  CarPlayBrowse.swift
//  RadarMap
//
//  Осмотр карты в машине: когда карта едет за машиной, когда водитель
//  смотрит сам и когда пора вернуть всё как было.
//
//  До 18.10 осмотр закрывала только кнопка «Готово» в баре. Автовозврат через
//  20 с и подъезд к камере возвращали карту к машине, а интерфейс осмотра
//  оставался: карта ехала как обычно, а в баре вместо «Поездки», «Звука»,
//  «Куда» и «Радар!» стояла одна «Готово» — пока водитель не догадается её
//  найти (аудит 18.10, п. 1: «нет кнопок, где функционал»). Если в осмотре
//  ничего не двигали, таймера не было вовсе. Теперь возврат к машине и
//  закрытие осмотра — одно решение здесь.
//
//  Чистая логика без таймеров и UIKit: события на входе, действия на выходе.
//  Покрыто CarPlayBrowseTests.
//

import Foundation

nonisolated enum CarPlayBrowse {

    /// Удержанная стрелка повторяет шаг, пока шагов меньше потолка
    /// (`carPlayPanHoldMaxSeconds`). Отпускание приходит событием, но теряется
    /// при автозакрытии осмотра и отключении — потолок не даёт карте уехать
    /// навсегда.
    static func panHoldContinues(steps: Int,
                                 interval: TimeInterval = AppConfig.carPlayPanHoldInterval,
                                 maxSeconds: TimeInterval = AppConfig.carPlayPanHoldMaxSeconds) -> Bool {
        Double(steps) * interval < maxSeconds
    }

    struct State: Equatable, Sendable {
        /// Карта едет за машиной.
        var following = true
        /// На экране интерфейс осмотра шаблона: стрелки и «Готово» в баре.
        var panning = false
    }

    enum Event: Equatable, Sendable {
        /// Интерфейс осмотра открылся (нашей кнопкой или мимо нас).
        case panningShown
        /// Интерфейс осмотра закрыт («Готово» или нами).
        case panningHidden
        /// Водитель сдвинул карту: стрелки осмотра, крутилка, палец.
        case moved
        /// «+» или «−».
        case zoomed
        /// Весь маршрут на экране — выбор маршрута.
        case overview
        /// «К себе» или новая карта, которая стартует со слежения.
        case recenter
        /// Водитель ничего не трогал `carPlayFollowReturnSeconds`.
        case idleTimeout
        /// Впереди камера: карта обязана быть у машины.
        case cameraAhead
    }

    enum Effect: Equatable, Sendable {
        /// Взвести таймер бездействия заново.
        case armIdle
        case cancelIdle
        /// Карта — снова за машиной.
        case recenter
        /// Закрыть интерфейс осмотра шаблона (бар вернётся по его событию).
        case closePanning
    }

    /// Следующее состояние и что сделать. `previewing` — на экране выбор
    /// маршрута: обзор линии стоит, пока водитель выбирает, и ни таймер, ни
    /// камера его не сбивают (машина при этом стоит — выбор только стоя).
    static func reduce(_ state: inout State, _ event: Event, previewing: Bool) -> [Effect] {
        switch event {
        case .panningShown:
            state.panning = true
            // Осмотр без единого движения тоже обязан закрыться сам.
            return previewing ? [] : [.armIdle]

        case .panningHidden:
            state.panning = false
            // Свободная карта после «Готово» по-прежнему вернётся сама.
            return state.following ? [.cancelIdle] : []

        case .moved:
            state.following = false
            return previewing ? [] : [.armIdle]

        case .zoomed:
            // Зум при слежении — сдвиг автозума, а не осмотр: таймер нужен,
            // только если карта свободна или открыт интерфейс осмотра.
            guard !previewing, !state.following || state.panning else { return [] }
            return [.armIdle]

        case .overview:
            state.following = false
            // На выборе маршрута обзор стоит, пока выбирают; во время ведения
            // («Весь маршрут» из сетки, 10.4) — вернётся к машине сам, как
            // свободная карта.
            return previewing ? [.cancelIdle] : [.armIdle]

        case .recenter:
            let wasPanning = state.panning
            state.following = true
            return wasPanning ? [.closePanning, .recenter, .cancelIdle] : [.recenter, .cancelIdle]

        case .idleTimeout, .cameraAhead:
            guard !previewing else { return [] }
            var effects: [Effect] = []
            if state.panning { effects.append(.closePanning) }
            if !state.following { effects.append(.recenter) }
            guard !effects.isEmpty else { return [] }
            state.following = true
            return effects + [.cancelIdle]
        }
    }
}
