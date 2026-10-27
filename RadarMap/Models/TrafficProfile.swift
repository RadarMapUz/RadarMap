//
//  TrafficProfile.swift
//  RadarMap
//
//  Типичные пробки по часу недели (33C, docs/spec_traffic_33.md):
//  server/traffic_profile.py раз в сутки пишет traffic/profile.json — по
//  ребру OSM только годные медленные слоты часа недели (медиана по трём+
//  разным дням, сжатая к графу; та же типичная, что сервер кладёт в
//  маршрутизатор). Телефон по нему узнаёт скорость участка на момент, когда
//  до него доедет (TrafficTimeAhead), а не «сейчас».
//
//  Формат версии 1:
//  `{"v":1,"generated":t,"edges":[[ulat,ulon,vlat,vlon,model_kmh,[[slot,kmh],…]]]}`,
//  слот — час недели по Ташкенту, понедельник 00:00 = 0, праздник — как
//  воскресенье в тот же час (traffic_build.week_slot). Чужая версия или
//  файл старше `trafficProfileMaxAgeSeconds` — «нет данных», не «пробок нет».
//
//  Скорость в минуту m часа — смесь текущего и следующего слота с весом
//  α = m/60 (как у сервера); слота нет — модель (если ребро в ней), иначе
//  скорость графа. Задержка — только против графа (медленнее), как у живых
//  пробок.
//
//  Модель обычных пробок (33G, server/traffic_model.py): таблица `curves` —
//  168 процентов графа на слот, и строки двух видов, источник — по форме:
//    * по водителям: `[ulat,ulon,vlat,vlon,model,[[slot,kmh],…](,кривая)]` —
//      седьмой элемент, если ребро и в модели: слот без наблюдений берёт её;
//    * по модели: `[ulat,ulon,vlat,vlon,model,кривая]` — шестой элемент число.
//  Модель — догадка: она идёт в ETA (TrafficTimeAhead) и в слой «обычно в
//  это время» на карте (`usual`), но не в голос: JamAhead и DetourAdvisor
//  читают только живой now.json (TrafficService.snapshot), а рёбра профиля в
//  `snapshot` здесь — уровня 1 и сами задержки не дают.
//
//  Чистая логика, время и календарь — параметрами; покрыто TrafficTimeAheadTests.
//

import CoreLocation
import Foundation

nonisolated struct TrafficProfile: Sendable {
    let generated: Date
    /// Рёбра для поиска по месту и направлению (TrafficSnapshot.matchingIndex):
    /// `kmh` = `modelKmh`, уровень 1 — сами по себе задержки не дают.
    let snapshot: TrafficSnapshot
    /// Скорость по слотам часа недели — по номеру ребра в `snapshot.edges`.
    let slots: [[Int: Double]]
    /// Номер кривой модели по номеру ребра; -1 — ребра нет в модели.
    let curveIndex: [Int32]
    /// Кривые модели: 168 долей графа (0,35…1) на слот.
    let curves: [[Double]]

    /// Откуда «обычно» на ребре — для честной подписи на карте.
    enum Source: Sendable, Equatable {
        /// Типичная по поездкам водителей (годные слоты, сжатие к модели или графу).
        case drivers
        /// Только модель по дороге (OSM): класс, светофоры, центр, час недели.
        case model
    }

    init(generated: Date, snapshot: TrafficSnapshot, slots: [[Int: Double]],
         curveIndex: [Int32]? = nil, curves: [[Double]] = []) {
        self.generated = generated
        self.snapshot = snapshot
        self.slots = slots
        self.curveIndex = curveIndex ?? [Int32](repeating: -1, count: slots.count)
        self.curves = curves
    }

    /// Источник «обычно» ребра в смеси слотов: водители, если у них есть
    /// годный слот этого часа, иначе модель.
    func source(edge index: Int, mix: Mix) -> Source {
        let bySlot = slots[index]
        return bySlot[mix.current] != nil || bySlot[mix.next] != nil ? .drivers : .model
    }

    static func decode(_ data: Data) -> TrafficProfile? {
        // Не JSON или чужая версия — «нет данных»: догадка о формате хуже.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == AppConfig.trafficProfileVersion,
              let generated = object["generated"] as? Double ?? (object["generated"] as? Int).map(Double.init),
              let raw = object["edges"] as? [[Any]] else { return nil }
        // Таблица кривых модели (33G); битая кривая — строки модели с ней
        // пропускаются, а не читаются наугад.
        var curves: [[Double]] = []
        var curveValid: [Bool] = []
        for raw in object["curves"] as? [[Any]] ?? [] {
            let values = raw.compactMap(Self.number)
            let ok = values.count == 168 && values.allSatisfy { (30...100).contains($0) }
            curves.append(ok ? values.map { $0 / 100 } : [])
            curveValid.append(ok)
        }
        func curve(_ value: Any?) -> Int32? {
            guard let value, let number = Self.number(value), number >= 0, Int(number) < curves.count,
                  curveValid[Int(number)] else { return nil }
            return Int32(number)
        }
        var edges: [TrafficEdge] = []
        var slots: [[Int: Double]] = []
        var curveIndex: [Int32] = []
        edges.reserveCapacity(raw.count)
        slots.reserveCapacity(raw.count)
        curveIndex.reserveCapacity(raw.count)
        for row in raw {
            guard row.count >= 6,
                  let lat1 = Self.number(row[0]), let lon1 = Self.number(row[1]),
                  let lat2 = Self.number(row[2]), let lon2 = Self.number(row[3]),
                  let model = Self.number(row[4]), model > 0, model <= 200 else { continue }
            var bySlot: [Int: Double] = [:]
            let index: Int32
            if let pairs = row[5] as? [[Any]] {
                // По водителям (+ кривая модели седьмым, если есть).
                for pair in pairs {
                    guard pair.count >= 2, let slot = Self.number(pair[0]), let kmh = Self.number(pair[1]),
                          (0..<168).contains(Int(slot)), kmh > 0, kmh <= model else { continue }
                    bySlot[Int(slot)] = kmh
                }
                index = row.count >= 7 ? curve(row[6]) ?? -1 : -1
                guard !bySlot.isEmpty || index >= 0 else { continue }
            } else {
                // По модели: шестой элемент — номер кривой.
                guard let model = curve(row[5]) else { continue }
                index = model
            }
            edges.append(TrafficEdge(a: CLLocationCoordinate2D(latitude: lat1, longitude: lon1),
                                     b: CLLocationCoordinate2D(latitude: lat2, longitude: lon2),
                                     level: 1, kmh: model, modelKmh: model))
            slots.append(bySlot)
            curveIndex.append(index)
        }
        return TrafficProfile(generated: Date(timeIntervalSince1970: generated),
                              snapshot: TrafficSnapshot(generated: Date(timeIntervalSince1970: generated),
                                                        edges: edges, cellDegrees: cellDegrees),
                              slots: slots, curveIndex: curveIndex, curves: curves)
    }

    /// Ячейка сетки профиля — ~165 × 125 м: рёбра профиля плотные, и на
    /// отрезке маршрута кандидатов должно быть единицы, а не сотни.
    nonisolated static let cellDegrees = 0.0015

    private static func number(_ value: Any) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
    }

    /// Файл старше 36 ч — нет данных (сервер пересобирает раз в сутки).
    func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(generated)
        return age <= AppConfig.trafficProfileMaxAgeSeconds && age >= -3600
    }

    // MARK: - Слот

    /// Час недели по Ташкенту: понедельник 00:00 = 0, праздник — воскресенье.
    static func weekSlot(_ date: Date, calendar: Calendar = TypicalTraffic.tashkent) -> Int {
        let hour = calendar.component(.hour, from: date)
        if UzHolidays.isHoliday(date, calendar: calendar) { return 6 * 24 + hour }
        let weekday = (calendar.component(.weekday, from: date) + 5) % 7   // понедельник = 0
        return weekday * 24 + hour
    }

    /// Смесь слотов момента: (текущий, следующий, вес следующего α = m/60).
    struct Mix: Equatable, Sendable {
        let current: Int
        let next: Int
        let alpha: Double
    }

    static func mix(at date: Date, calendar: Calendar = TypicalTraffic.tashkent) -> Mix {
        let minute = Double(calendar.component(.minute, from: date)) + Double(calendar.component(.second, from: date)) / 60
        return Mix(current: weekSlot(date, calendar: calendar),
                   next: weekSlot(date.addingTimeInterval(3600), calendar: calendar),
                   alpha: minute / 60)
    }

    /// Скорость ребра в смеси слотов; нет слота — модель (33G), нет и её —
    /// скорость графа.
    func speed(edge index: Int, mix: Mix) -> Double {
        let model = snapshot.edges[index].modelKmh
        let bySlot = slots[index]
        let curve = curveIndex[index] >= 0 ? curves[Int(curveIndex[index])] : nil
        func prior(_ slot: Int) -> Double { curve.map { model * $0[slot] } ?? model }
        return (1 - mix.alpha) * (bySlot[mix.current] ?? prior(mix.current))
            + mix.alpha * (bySlot[mix.next] ?? prior(mix.next))
    }

    // MARK: - Слой «обычно в это время» (33G)

    /// Ребро слоя: где в этот час обычно медленно. Свой тип, а не
    /// TrafficEdge: в JamAhead и DetourAdvisor его не передать по ошибке —
    /// догадку голосом не продаём.
    struct UsualEdge: Equatable, Sendable {
        let a: CLLocationCoordinate2D
        let b: CLLocationCoordinate2D
        /// Обычная скорость / скорость графа в этот момент.
        let ratio: Double
        let source: Source
        /// Скорость графа — класс толщины линии на карте (TrafficLines, 33H).
        var modelKmh: Double = 0
        var isHeavy: Bool { ratio < AppConfig.usualTrafficHeavyRatio }

        static func == (l: UsualEdge, r: UsualEdge) -> Bool {
            l.a.latitude == r.a.latitude && l.a.longitude == r.a.longitude
                && l.b.latitude == r.b.latitude && l.b.longitude == r.b.longitude
                && l.ratio == r.ratio && l.source == r.source && l.modelKmh == r.modelKmh
        }
    }

    /// Рёбра, где в момент `date` обычно медленнее `usualTrafficShowRatio`
    /// графа (смесь слотов по минуте, как у ETA). Ночью и в воскресенье днём —
    /// почти пусто: так и должно быть.
    func usual(at date: Date, calendar: Calendar = TypicalTraffic.tashkent) -> [UsualEdge] {
        let mix = Self.mix(at: date, calendar: calendar)
        var out: [UsualEdge] = []
        for (index, edge) in snapshot.edges.enumerated() where edge.modelKmh > 0 {
            let ratio = speed(edge: index, mix: mix) / edge.modelKmh
            guard ratio < AppConfig.usualTrafficShowRatio else { continue }
            out.append(UsualEdge(a: edge.a, b: edge.b, ratio: ratio, source: source(edge: index, mix: mix),
                                 modelKmh: edge.modelKmh))
        }
        return out
    }

    /// Задержка шага маршрута против графа в смеси слотов; 0 — ребра нет или
    /// в этот час едут как граф.
    func stepDelay(at point: CLLocationCoordinate2D, course: Double, length: Double, mix: Mix) -> TimeInterval {
        guard let index = snapshot.matchingIndex(at: point, course: course) else { return 0 }
        return stepDelay(edge: index, length: length, mix: mix)
    }

    /// Задержка шага длиной `length` на ребре `index` в смеси слотов.
    func stepDelay(edge index: Int, length: Double, mix: Mix) -> TimeInterval {
        let model = snapshot.edges[index].modelKmh
        let typical = speed(edge: index, mix: mix)
        // Допуск 0,01 км/ч: смесь двух «нет слота» — это граф, а не граф
        // минус ошибка округления.
        guard model > 0, typical < model - 0.01 else { return 0 }
        return max(0, length / (max(3, typical) / 3.6) - length / (model / 3.6))
    }
}
