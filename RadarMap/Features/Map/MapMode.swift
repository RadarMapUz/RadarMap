//
//  MapMode.swift
//  RadarMap
//
//  Режим главного экрана — что водителю нужно прямо сейчас.
//
//  Экран рос наращиванием: каждая фича добавляла свой элемент поверх карты, а
//  видимость решалась россыпью `if` внутри одной вёрстки. В покое на карте
//  оказывалось девять элементов сразу (HUD, компас, локация, «радар здесь»,
//  легенда, Дом/Работа, «Начать поездку», бар действий, подсказка «похоже, вы
//  едете») — из них нужен один. Здесь правило «что показываем» становится
//  явным и проверяемым: режим один, набор элементов фиксирован.
//
//  Чистое перечисление без SwiftUI — покрыто тестами (MapModeTests).
//

import Foundation

nonisolated enum MapMode: Equatable {
    /// Стоим: поездки нет. Экран про «куда поедем».
    case idle
    /// Едем без маршрута. Экран про «что впереди».
    case driving
    /// Едем по маршруту. Экран про «куда поворачивать».
    case navigating

    static func current(isTripActive: Bool, hasRoute: Bool) -> MapMode {
        if isTripActive { return hasRoute ? .navigating : .driving }
        return .idle
    }

    // MARK: - Правила видимости
    //
    // Каждое свойство отвечает ровно на один вопрос и читается как чек-лист.
    // Добавляя элемент на экран, его место в этой таблице выбирается осознанно,
    // а не «ещё один if рядом с существующими».

    /// Дом/Работа и «Начать поездку» — только в покое: в движении это шум.
    var showsQuickDestinations: Bool { self == .idle }

    /// Нижний бар действий (поиск, список камер, настройки, Итоги).
    var showsActionBar: Bool { self == .idle }

    /// Легенда типов камер: справочная информация, за рулём не нужна.
    var showsLegend: Bool { self == .idle }

    /// Отметить радар одним тапом — смысл имеет только на ходу.
    var showsReportButton: Bool { self != .idle }

    /// Компактная строка поездки внизу (прибытие · остаток · камера · стоп).
    var showsTripBar: Bool { self != .idle }

    /// Баннер манёвра сверху.
    var showsManeuver: Bool { self == .navigating }

    /// Панель маршрута с вариантами — до старта поездки.
    var showsRoutePanel: Bool { self == .idle }

    /// Карта разворачивается по ходу движения и наклоняется.
    var followsHeading: Bool { self != .idle }

    /// Главный элемент экрана: на нём держится иерархия внимания, всё
    /// остальное обязано быть тише. Двух «главных» одновременно не бывает.
    var focus: Focus {
        switch self {
        case .idle:       return .destination
        case .driving:    return .speed
        case .navigating: return .maneuver
        }
    }

    enum Focus: Equatable {
        case destination   // куда поедем
        case speed         // скорость и ближайшая камера
        case maneuver      // поворот
    }
}
