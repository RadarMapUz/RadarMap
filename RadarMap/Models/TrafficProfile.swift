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
//  α = m/60 (как у сервера); слота нет — скорость графа. Задержка — только
//  против графа (медленнее), как у живых пробок.
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

    static func decode(_ data: Data) -> TrafficProfile? {
        // Не JSON или чужая версия — «нет данных»: догадка о формате хуже.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == AppConfig.trafficProfileVersion,
              let generated = object["generated"] as? Double ?? (object["generated"] as? Int).map(Double.init),
              let raw = object["edges"] as? [[Any]] else { return nil }
        var edges: [TrafficEdge] = []
        var slots: [[Int: Double]] = []
        edges.reserveCapacity(raw.count)
        slots.reserveCapacity(raw.count)
        for row in raw {
            guard row.count >= 6,
                  let lat1 = Self.number(row[0]), let lon1 = Self.number(row[1]),
                  let lat2 = Self.number(row[2]), let lon2 = Self.number(row[3]),
                  let model = Self.number(row[4]), model > 0, model <= 200,
                  let pairs = row[5] as? [[Any]] else { continue }
            var bySlot: [Int: Double] = [:]
            for pair in pairs {
                guard pair.count >= 2, let slot = Self.number(pair[0]), let kmh = Self.number(pair[1]),
                      (0..<168).contains(Int(slot)), kmh > 0, kmh <= model else { continue }
                bySlot[Int(slot)] = kmh
            }
            guard !bySlot.isEmpty else { continue }
            edges.append(TrafficEdge(a: CLLocationCoordinate2D(latitude: lat1, longitude: lon1),
                                     b: CLLocationCoordinate2D(latitude: lat2, longitude: lon2),
                                     level: 1, kmh: model, modelKmh: model))
            slots.append(bySlot)
        }
        return TrafficProfile(generated: Date(timeIntervalSince1970: generated),
                              snapshot: TrafficSnapshot(generated: Date(timeIntervalSince1970: generated),
                                                        edges: edges, cellDegrees: cellDegrees),
                              slots: slots)
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

    /// Скорость ребра в смеси слотов; нет слота — скорость графа.
    func speed(edge index: Int, mix: Mix) -> Double {
        let model = snapshot.edges[index].modelKmh
        let bySlot = slots[index]
        return (1 - mix.alpha) * (bySlot[mix.current] ?? model) + mix.alpha * (bySlot[mix.next] ?? model)
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
