//
//  SketchPlace.swift
//  RadarMap
//
//  Населённый пункт: имя и точка. Слой, которого на схеме не было вовсе.
//
//  Сервер считает его с самого перехода на формат 2 (SET_PLACES в
//  build_roads.py, 3 540 файлов на 0,7 МБ по стране), а в RoadTiles.Set такого
//  случая просто не завели — и набор ездил на диск сервера впустую.
//
//  Заметно это стало ровно тогда, когда карту научили отодвигаться. На охвате
//  района и дальше улицы с неё уходят по замыслу: там раздельные проезжие
//  сведены в одну ось и подписывать нечего. Остаётся сеть серых линий, по
//  которой нельзя понять даже, город это или трасса между кишлаками. Имя
//  посёлка отвечает на этот вопрос одним словом.
//
//  Ранги — контракт с PLACE_RANKS в build_roads.py.
//

import CoreLocation
import Foundation

nonisolated struct SketchPlace: Sendable, Equatable {

    enum Rank: Int, Sendable, CaseIterable {
        case city = 1
        case town = 2
        case village = 3
        case hamlet = 4
        case suburb = 5
        case neighbourhood = 6

        /// С какого охвата имя показывается.
        ///
        /// Не «чем крупнее, тем раньше» ради стройности: на ближнем плане
        /// подписаны улицы, и второе имя поверх них — шум. Махалля же на
        /// охвате области — толпа надписей в углу: их в одном Ташкенте сотни.
        /// Каждому рангу свой диапазон, и диапазоны почти не пересекаются.
        var fromSpanMeters: Double {
            switch self {
            case .city, .town:              return MapViewport.farNetworkSpan
            case .village, .hamlet:         return MapViewport.farNetworkSpan
            case .suburb, .neighbourhood:   return MapViewport.farNetworkSpan
            }
        }

        /// До какого охвата имя ещё осмысленно.
        ///
        /// Город виден до конца: на двадцати километрах он и есть ответ на
        /// вопрос «где я». Кишлак на таком охвате — точка среди сотни таких
        /// же, а махалля — вовсе внутригородское деление, и за городской
        /// чертой её название не значит ничего.
        var toSpanMeters: Double {
            switch self {
            case .city:                     return .greatestFiniteMagnitude
            case .town:                     return .greatestFiniteMagnitude
            case .village:                  return 9_000
            case .hamlet:                   return 5_000
            case .suburb:                   return 4_000
            case .neighbourhood:            return 2_500
            }
        }

        func isVisible(atSpan span: Double) -> Bool {
            span >= fromSpanMeters && span <= toSpanMeters
        }

        /// Кого подписываем первым, когда мест больше, чем места на экране.
        var priority: Int { rawValue }

        /// Насколько крупно. Город обязан читаться раньше кишлака — это и
        /// есть вся иерархия карты на обзорном охвате.
        var fontScale: Double {
            switch self {
            case .city:                     return 1.35
            case .town:                     return 1.18
            case .village, .hamlet:         return 1.0
            case .suburb, .neighbourhood:   return 0.92
            }
        }
    }

    var coordinate: CLLocationCoordinate2D
    var rank: Rank
    var name: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rank == rhs.rank && lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}
