//
//  RoadNetwork.swift
//  RadarMap
//
//  Дорожная сеть для схемы на приборке — за одним интерфейсом, независимо от
//  того, откуда взялась геометрия.
//
//  Зачем интерфейс, а не прямое чтение. Источников будет два, и они появятся
//  в разное время:
//
//  1. **Сегодня, бесплатно** — индекс лимитов скорости. `speed_limits.json`
//     мы и так качаем (3,3 МБ) ради матчинга «какой тут лимит», а внутри у
//     него 21 558 сегментов дорог со 183 483 точками и сеточный индекс. Это
//     настоящие линии дорог: перекрёстки, развязки, параллельные улицы —
//     офлайн и без единой новой загрузки. Ограничение честное: там только
//     дороги с тегом maxspeed, то есть магистрали и проспекты (как раз те,
//     где стоят камеры), а дворы и часть мелочи не попадают.
//
//  2. **Дальше** — собственный `roads.json`, собранный на сервере из того же
//     OSM-экстракта: все проезжие дороги, класс, мост, тоннель, односторонность.
//     Только он позволит нарисовать мост НАД дорогой, а не рядом с ней.
//
//  Рендерер пишется один раз против `RoadLine`, а подмена источника — одна
//  строка в композиционном корне. Без этого разделения второй источник
//  означал бы переписывание отрисовки заново.
//

import CoreLocation
import Foundation
import os

/// Одна линия дороги для отрисовки.
///
/// Не `Equatable`: `CLLocationCoordinate2D` им не является, а сравнивать сырые
/// координаты и незачем — сравнивается уже спроецированная `RoadSketch.Line`.
nonisolated struct RoadLine: Sendable {
    var points: [CLLocationCoordinate2D]
    /// Класс дороги — от него ширина линии. `.unknown`, если источник не знает.
    var kind: RoadClass = .unknown
    /// Уровень: 0 — по земле, > 0 — мост/эстакада, < 0 — тоннель. Рисуется
    /// послойно, и только так камера НА мосту отличима от камеры ПОД ним.
    var level: Int = 0
    /// Одностороннее движение — рисуем стрелки по ходу линии.
    var isOneWay: Bool = false

    /// Источник знает класс и уровень по-настоящему, а не подставил дефолты.
    /// Вью рисует «незнающий» источник ровными линиями одной ширины: выдавать
    /// предположение за измеренное нельзя даже в оформлении.
    var isDetailed: Bool = false
    /// Замкнутая дорога: кольцевая развязка. Контур замыкается, а стрелки на
    /// ней не рисуются — по кругу они читаются как ошибка.
    var isRing: Bool = false
    /// Название. Есть у одной дороги из семи — только у крупных классов и
    /// только там, где оно есть в OSM. Пусто — не «безымянная», а «мы не
    /// знаем», и подписывать нечего.
    var name: String = ""
    /// Полос на дороге ВСЕГО, как в теге OSM: у двусторонней — сумма обоих
    /// направлений. 0 — «тайл не сказал», и тогда берётся дефолт класса.
    /// Едет старшими битами flags, а не отдельным полем записи — см.
    /// `RoadTiles.decodeTile`.
    var lanes: Int = 0

    /// Ширина проезжей части, метры. Считается здесь, а не возится в тайле:
    /// одно число полос дешевле числа метров и не расходится с классом.
    var widthMeters: Double {
        let counted = lanes > 0 ? lanes : kind.defaultLanes(isOneWay: isOneWay)
        return Double(min(counted, kind.maxLanes)) * kind.laneMeters
    }
}

/// Откуда берётся сеть. `nonisolated` и `Sendable`: запросы идут из отрисовки,
/// а индекс строится в фоне.
nonisolated protocol RoadNetworkSource: Sendable {
    /// Дороги, попадающие в круг заданного радиуса. Порядок не важен —
    /// рендерер сам сортирует по уровню, чтобы мост лёг поверх.
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine]
}

/// Пустая сеть: индекса ещё нет (первый запуск, файл не скачался). Схема при
/// этом остаётся рабочей — дорога камеры, маршрут и трек от сети не зависят.
nonisolated struct EmptyRoadNetwork: RoadNetworkSource {
    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] { [] }
}

/// Свои тайлы, где они есть, иначе индекс лимитов.
///
/// Тайлы знают класс, мост и односторонность, но покрытие приезжает
/// постепенно (ленивое скачивание) и может отсутствовать вовсе (первый
/// запуск без сети). Пустой ответ первичного источника — честный признак
/// «здесь покрытия нет», и тогда рисуем то, что знаем из лимитов, а не
/// пустоту.
nonisolated struct FallbackRoadNetwork: RoadNetworkSource {
    let primary: any RoadNetworkSource
    let fallback: any RoadNetworkSource

    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        let detailed = primary.roads(near: coordinate, radius: radius)
        return detailed.isEmpty ? fallback.roads(near: coordinate, radius: radius)
                                : detailed
    }
}

/// Кэш окрестности поверх любого источника.
///
/// Сеть вокруг машины меняется на сотнях метров пути, а спрашивают её на
/// каждом GPS-тике открытой приборки. Замер (PerformanceBudgetTests) показал,
/// что именно сеточный запрос с обрезкой сегментов — самая дорогая часть
/// раскладки. Поэтому запрашиваем круг с полуторным запасом и отдаём его,
/// пока запрошенный круг целиком лежит внутри, — настоящий запрос выполняется
/// раз в пару сотен метров вместо каждой секунды.
///
/// Честность не страдает: кэш — всегда НАДмножество запрошенного (никакая
/// дорога не пропадает), а лишнее раскладка отсекает рамкой вида.
nonisolated final class CachedRoadNetwork: RoadNetworkSource {
    private struct Snapshot {
        var center: CLLocationCoordinate2D
        var radius: CLLocationDistance
        var lines: [RoadLine]
    }

    private let source: any RoadNetworkSource
    private let cache = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)
    /// Насколько шире запрашиваем, чем спросили. Запас и есть срок жизни кэша:
    /// при радиусе вида ~400 м обновляемся каждые ~200 м пути.
    private static let margin = 1.5

    init(_ source: any RoadNetworkSource) { self.source = source }

    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        if let cached = cache.withLock({ $0 }) {
            let metersPerLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
            let moved = hypot(
                (coordinate.latitude - cached.center.latitude) * 111_320.0,
                (coordinate.longitude - cached.center.longitude) * metersPerLon)
            if moved + radius <= cached.radius { return cached.lines }
        }
        let fresh = Snapshot(center: coordinate, radius: radius * Self.margin,
                             lines: source.roads(near: coordinate,
                                                 radius: radius * Self.margin))
        cache.withLock { $0 = fresh }
        return fresh.lines
    }
}
