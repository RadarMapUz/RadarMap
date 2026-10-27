//
//  LongTripBrief.swift
//  RadarMap
//
//  «Перед дальней дорогой» (12.4): маршрут длиннее 100 км — один лист, где
//  до «Поехали» видно три вещи, которые на трассе без связи узнать негде:
//  какие области карты уже на телефоне, какие камеры и посты встретятся и
//  по порядку на каком километре, и где по пути заправиться своим топливом.
//
//  Всё собрано из того, что уже на телефоне: камеры — из посчитанных
//  `camerasAlong` выбранного варианта (база и отметки водителей), заведения —
//  из локальных файлов клеток (CorridorVenues), области — из подписанного
//  каталога. Нового запроса к серверу этот расчёт не делает (правило 8.0).
//
//  Три решения здесь, а не в виде:
//  - камеры одного места — одна строка. На М39 у поста ДПС стоят две-четыре
//    камеры в сотне метров друг от друга; шесть строк «47 км» подряд читаются
//    как ошибка списка, а одна «47 км · Пост ДПС · ещё 2 камеры» — как место;
//  - пост старше камеры в заголовке группы: пост — остановка и проверка,
//    его ищут глазами первым; затем отметка водителей, затем камера;
//  - «дольше всего без метана — 112 км» говорится, только когда данные
//    о заведениях есть на ВЕСЬ путь вперёд. Пустая клетка без файла — не
//    «заправок нет»: на ней обещание было бы враньём, ровно там, где по
//    нему решают, заправляться ли сейчас.
//
//  Оповещений это не касается никак: лист справочный, гейты и голос живут
//  своей жизнью (правило 20).
//
//  Чистое — покрыто LongTripBriefTests, бюджет — PerformanceBudgetTests.
//

import CoreLocation
import Foundation

nonisolated enum LongTripBrief {

    // MARK: - Камеры и посты

    /// Что за точка в списке — по ней значок группы и счёт в сводке.
    enum Category: Int, Comparable, Sendable {
        case camera, crowd, post

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// nil — точке в плане поездки не место: ДТП живёт около часа, и на
    /// 250-м километре его уже не будет.
    static func category(_ type: CameraType) -> Category? {
        switch type {
        case .dpsPost:              return .post
        case .mobileRadar, .tripod: return .crowd
        case .accident:             return nil
        default:                    return .camera
        }
    }

    /// Камера маршрута — вход расчёта (из `RouteService.RouteCamera`).
    struct Marker: Equatable, Sendable {
        let camera: Camera
        /// Метры от старта маршрута до проекции камеры на линию.
        let along: CLLocationDistance
        /// Доказанно встречная (27.J): в коридоре, но не наша.
        var oncoming = false
    }

    /// Строка списка: камеры одного места по порядку вдоль пути.
    struct Checkpoint: Identifiable, Equatable, Sendable {
        /// Метры от старта до первой точки группы.
        let along: CLLocationDistance
        /// Все точки группы по ходу.
        let cameras: [Camera]
        /// Заголовок группы: пост, иначе отметка водителей, иначе камера.
        let lead: Camera

        var id: Int { cameras[0].id }
        /// Сколько ещё точек в группе кроме заголовка.
        var others: Int { cameras.count - 1 }
        var category: Category { LongTripBrief.category(lead.kind) ?? .camera }
    }

    /// Счёт для сводки: камер, постов, отметок водителей.
    struct Tally: Equatable, Sendable {
        var cameras = 0
        var posts = 0
        var crowd = 0

        var isEmpty: Bool { cameras + posts + crowd == 0 }
    }

    /// Камеры и посты впереди `progress` по порядку вдоль пути; точки ближе
    /// `groupMeters` к началу группы — в одной строке. Встречные, ДТП и
    /// истёкшие отметки — не в плане.
    static func checkpoints(_ markers: [Marker], progress: CLLocationDistance, now: Date,
                            groupMeters: CLLocationDistance = AppConfig.longTripGroupMeters) -> [Checkpoint] {
        var seen = Set<Int>()
        let ahead = markers
            .filter { marker in
                !marker.oncoming && marker.along >= progress
                    && category(marker.camera.kind) != nil
                    && !marker.camera.isExpiredMobile(at: now)
            }
            .sorted { ($0.along, $0.camera.id) < ($1.along, $1.camera.id) }
            .filter { seen.insert($0.camera.id).inserted }

        var out: [Checkpoint] = []
        var group: [Marker] = []
        func close() {
            guard let first = group.first else { return }
            // Старший по категории; среди равных — первый по ходу.
            var lead = first.camera
            for marker in group.dropFirst()
            where (category(marker.camera.kind) ?? .camera) > (category(lead.kind) ?? .camera) {
                lead = marker.camera
            }
            out.append(Checkpoint(along: first.along, cameras: group.map(\.camera), lead: lead))
            group.removeAll(keepingCapacity: true)
        }
        for marker in ahead {
            if let first = group.first, marker.along - first.along > groupMeters { close() }
            group.append(marker)
        }
        close()
        return out
    }

    static func tally(_ checkpoints: [Checkpoint]) -> Tally {
        var tally = Tally()
        for camera in checkpoints.lazy.flatMap(\.cameras) {
            switch category(camera.kind) {
            case .post:   tally.posts += 1
            case .crowd:  tally.crowd += 1
            case .camera: tally.cameras += 1
            case nil:     break
            }
        }
        return tally
    }

    // MARK: - Заправки

    /// Отрезок пути без заправки своего вида: метры от старта.
    struct Gap: Equatable, Sendable {
        let from: CLLocationDistance
        let to: CLLocationDistance

        var meters: CLLocationDistance { to - from }
    }

    /// Самый длинный отрезок между соседними заправками — считая от
    /// `start` (машина) до первой и от последней до `finish` (цель: туда
    /// тоже надо доехать). Заправок нет — весь путь. nil — пути нет.
    static func longestGap(_ stations: [CLLocationDistance], from start: CLLocationDistance,
                           to finish: CLLocationDistance) -> Gap? {
        guard finish > start else { return nil }
        let stops = [start] + stations.filter { $0 > start && $0 < finish }.sorted() + [finish]
        var best: Gap?
        for (a, b) in zip(stops, stops.dropFirst()) where best.map({ b - a > $0.meters }) ?? true {
            best = Gap(from: a, to: b)
        }
        return best
    }

    /// Заправки одного вида по пути.
    struct Fuel: Equatable, Sendable, Identifiable {
        let kind: Venue.Kind
        /// Все найденные этого вида, по порядку вдоль пути.
        let items: [CorridorVenues.Item]
        /// Самый длинный отрезок без них; nil — данных на весь путь нет, и
        /// обещать «дальше нет» нельзя.
        let gap: Gap?

        var id: Int { kind.rawValue }
    }

    /// По виду на каждое топливо машины (`VehicleEnergy.stops`, по порядку):
    /// найденные и самый длинный отрезок без них. `complete` — файлы
    /// заведений есть на весь путь впереди.
    static func fuel(_ items: [CorridorVenues.Item], kinds: [Venue.Kind], progress: CLLocationDistance,
                     routeLength: CLLocationDistance, complete: Bool) -> [Fuel] {
        var seen = Set<Venue.Kind>()
        return kinds.filter { seen.insert($0).inserted }.map { kind in
            let own = items.filter { $0.venue.kind == kind && $0.along >= progress }
            return Fuel(kind: kind, items: own,
                        gap: complete ? longestGap(own.map(\.along), from: progress, to: routeLength) : nil)
        }
    }

    // MARK: - Области офлайн-карты

    enum RegionStatus: Equatable, Sendable {
        case ready, updateAvailable, downloading(Double), missing

        /// Карта области нарисуется без связи (обновление — не пробел: старый
        /// выпуск рисуется так же).
        var isOnPhone: Bool {
            switch self {
            case .ready, .updateAvailable: return true
            case .downloading, .missing:   return false
            }
        }
    }

    struct RegionRow: Equatable, Sendable, Identifiable {
        let region: RegionCatalog.Region
        let status: RegionStatus

        var id: String { region.id }
    }

    struct Regions: Equatable, Sendable {
        /// Области коридора по ходу, каждая со своим состоянием.
        let rows: [RegionRow]

        var onPhone: Int { rows.filter(\.status.isOnPhone).count }
        var missing: Int { rows.filter { $0.status == .missing }.count }
        var downloading: Bool { rows.contains { if case .downloading = $0.status { true } else { false } } }
        var allOnPhone: Bool { !rows.isEmpty && onPhone == rows.count }
    }

    static func regions(_ corridor: [RegionCatalog.Region],
                        status: (RegionCatalog.Region) -> RegionStatus) -> Regions {
        Regions(rows: corridor.map { RegionRow(region: $0, status: status($0)) })
    }

    // MARK: - Лист целиком

    struct Brief: Equatable, Sendable {
        let checkpoints: [Checkpoint]
        let tally: Tally
        let fuel: [Fuel]
        let routeLength: CLLocationDistance
        /// Файлы заведений есть на весь путь впереди.
        let venuesComplete: Bool
    }

    static func make(markers: [Marker], venues: [CorridorVenues.Item], kinds: [Venue.Kind],
                     progress: CLLocationDistance, routeLength: CLLocationDistance,
                     venuesComplete: Bool, now: Date) -> Brief {
        let points = checkpoints(markers, progress: progress, now: now)
        return Brief(checkpoints: points, tally: tally(points),
                     fuel: fuel(venues, kinds: kinds, progress: progress, routeLength: routeLength,
                                complete: venuesComplete),
                     routeLength: routeLength, venuesComplete: venuesComplete)
    }

    /// То же вне главного потока: сотни камер и тысячи заведений на 600 км —
    /// не работа для main (правило 11).
    @concurrent static func build(markers: [Marker], venues: [CorridorVenues.Item], kinds: [Venue.Kind],
                                  progress: CLLocationDistance, routeLength: CLLocationDistance,
                                  venuesComplete: Bool, now: Date) async -> Brief {
        make(markers: markers, venues: venues, kinds: kinds, progress: progress, routeLength: routeLength,
             venuesComplete: venuesComplete, now: now)
    }
}
