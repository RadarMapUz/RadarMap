//
//  TrafficTimeAhead.swift
//  RadarMap
//
//  Время прибытия во времени (33C, docs/spec_traffic_33.md): скорость
//  участка — на момент, когда до него доедешь, а не «сейчас».
//
//  Маршрут проходится по порядку шагами по ~25 м (та же мерка, что у живых
//  пробок), копится время прибытия к шагу T = выезд + время графа до него +
//  уже набранная задержка. Для шага:
//    * T − сейчас ≤ `trafficTimeAheadLiveSeconds` (15 мин) и в свежем now.json
//      есть ребро под шагом — живое (свободно — 0, медленно — его задержка);
//    * иначе — типичная слота часа недели момента T (profile.json, смесь
//      соседних слотов по минуте);
//    * иначе — граф (0).
//  Ни свежих живых, ни свежего профиля — nil («нет данных», а не «пробок нет»).
//
//  В отличие от TrafficForecast (файлы «обычно» по классу дня и часу, 27.E)
//  здесь неделя по часам: пятница вечером ≠ вторник вечером. Когда profile.json
//  есть — маршрут берёт это время («Быстрый», ETA остатка), иначе — прежний
//  прогноз.
//
//  Скорость: маршрут на 300 км — это 12 000 шагов; шагать имеет смысл только
//  там, где есть рёбра. Кандидаты (рёбра ячеек отрезка с нашим
//  направлением) собираются один раз на отрезок маршрута
//  (TrafficSnapshot.candidates); пусто — отрезок едет по графу целиком, иначе
//  шаги проверяют только их — бюджет в PerformanceBudgetTests.
//
//  Чистая логика, время и календарь — параметрами; покрыто TrafficTimeAheadTests.
//

import CoreLocation
import Foundation

nonisolated enum TrafficTimeAhead {

    static func delay(along route: [CLLocationCoordinate2D], baseTime: TimeInterval,
                      departure: Date, now: Date, live: TrafficSnapshot?, profile: TrafficProfile?,
                      calendar: Calendar = TypicalTraffic.tashkent) -> TrafficForecast.Delay? {
        guard route.count >= 2 else { return nil }
        let liveSnapshot = live.flatMap { $0.isFresh(now: now) ? $0 : nil }
        let profileFile = profile.flatMap { $0.isFresh(now: now) ? $0 : nil }
        guard liveSnapshot != nil || profileFile != nil else { return nil }
        // Один проход по точкам: длины отрезков (темп графа) и рамки кусков по
        // `block` отрезков с их длиной — кусок без данных потом пропускается
        // целиком, без второго прохода по точкам.
        let block = 32
        let count = route.count - 1
        var lengths = [Double](repeating: 0, count: count)
        var boxes: [(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, length: Double)] = []
        boxes.reserveCapacity(count / block + 1)
        var length = 0.0
        var previous = route[0]
        for i in 0..<count {
            let q = route[i + 1]
            let segment = GeoMath.fastDistance(previous.latitude, previous.longitude, q.latitude, q.longitude)
            lengths[i] = segment
            length += segment
            if i % block == 0 {
                boxes.append((min(previous.latitude, q.latitude), min(previous.longitude, q.longitude),
                              max(previous.latitude, q.latitude), max(previous.longitude, q.longitude), segment))
            } else {
                let b = boxes.count - 1
                boxes[b].minLat = min(boxes[b].minLat, q.latitude)
                boxes[b].minLon = min(boxes[b].minLon, q.longitude)
                boxes[b].maxLat = max(boxes[b].maxLat, q.latitude)
                boxes[b].maxLon = max(boxes[b].maxLon, q.longitude)
                boxes[b].length += segment
            }
            previous = q
        }
        guard length > 0 else { return nil }
        let pace = max(0, baseTime) / length          // с/м по графу
        let liveUntil = now.addingTimeInterval(AppConfig.trafficTimeAheadLiveSeconds)

        // Слоты меняются раз в час пути — календарь и праздники спрашиваем
        // раз в час, а вес следующего слота α = (t − начало часа)/3600 —
        // арифметикой (то же, что TrafficProfile.mix: минута/60; у Ташкента
        // нет перехода на летнее время, сдвиг пояса один на весь путь).
        let zone = Double(calendar.timeZone.secondsFromGMT(for: departure))
        var slotCache: (hour: TimeInterval, current: Int, next: Int)?
        func mix(at moment: Date) -> TrafficProfile.Mix {
            let t = moment.timeIntervalSince1970
            let hour = ((t + zone) / 3600).rounded(.down) * 3600 - zone
            if slotCache?.hour != hour {
                slotCache = (hour, TrafficProfile.weekSlot(Date(timeIntervalSince1970: hour), calendar: calendar),
                             TrafficProfile.weekSlot(Date(timeIntervalSince1970: hour + 3600), calendar: calendar))
            }
            return TrafficProfile.Mix(current: slotCache!.current, next: slotCache!.next, alpha: (t - hour) / 3600)
        }

        var total: TimeInterval = 0, liveTotal: TimeInterval = 0
        var travelled = 0.0
        var usedLive = false, usedTypical = false
        for (b, box) in boxes.enumerated() {
            // Кусок маршрута в 32 отрезка, в рамке которого нет ни рёбер
            // профиля, ни (в живом горизонте) рёбер now.json, — по графу целиком.
            let i = b * block
            let end = min(count, i + block)
            let blockStart = departure.addingTimeInterval(travelled * pace + total)
            let liveBlock = liveSnapshot.map { blockStart <= liveUntil
                && $0.mayCover(minLat: box.minLat, minLon: box.minLon, maxLat: box.maxLat, maxLon: box.maxLon) } ?? false
            let profileBlock = profileFile?.snapshot.mayCover(minLat: box.minLat, minLon: box.minLon,
                                                              maxLat: box.maxLat, maxLon: box.maxLon) ?? false
            if !liveBlock && !profileBlock {
                if liveSnapshot != nil && blockStart <= liveUntil { usedLive = true }
                if profileFile != nil { usedTypical = true }
                travelled += box.length
                continue
            }
            for k in i..<end {
                let p = route[k], q = route[k + 1]
                let segment = lengths[k]
                guard segment > 0.5 else { continue }
                let start = departure.addingTimeInterval(travelled * pace + total)
                let inHorizon = liveSnapshot != nil && start <= liveUntil
                let course = GeoMath.bearing(from: p, to: q)
                // Кандидаты отрезка — один раз на отрезок; пусто у обоих — шагать
                // незачем: участок едет по графу.
                let liveEdges = inHorizon ? liveSnapshot!.candidates(p, q, course: course) : []
                let profileEdges = profileFile?.snapshot.candidates(p, q, course: course) ?? []
                if liveEdges.isEmpty && profileEdges.isEmpty {
                    if inHorizon { usedLive = true } else if profileFile != nil { usedTypical = true }
                    travelled += segment
                    continue
                }
                let steps = max(1, Int((segment / RouteTraffic.stepMeters).rounded(.up)))
                let step = segment / Double(steps)
                for s in 0..<steps {
                    let t = (Double(s) + 0.5) / Double(steps)
                    let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                       longitude: p.longitude + (q.longitude - p.longitude) * t)
                    let moment = departure.addingTimeInterval((travelled + step / 2) * pace + total)
                    travelled += step
                    if let liveSnapshot, moment <= liveUntil,
                       let index = liveSnapshot.matchingIndex(at: point, among: liveEdges) {
                        usedLive = true
                        let edge = liveSnapshot.edges[index]
                        if edge.level >= 2, edge.modelKmh > 0 {
                            let delay = max(0, step / (max(3, edge.kmh) / 3.6) - step / (edge.modelKmh / 3.6))
                            total += delay
                            liveTotal += delay
                        }
                    } else if let profileFile {
                        usedTypical = true
                        if let index = profileFile.snapshot.matchingIndex(at: point, among: profileEdges) {
                            total += profileFile.stepDelay(edge: index, length: step, mix: mix(at: moment))
                        }
                    } else if liveSnapshot != nil, moment <= liveUntil {
                        usedLive = true      // свежие живые без ребра под шагом — граф
                    }
                }
            }
        }
        switch (usedLive, usedTypical) {
        case (true, true):  return TrafficForecast.Delay(seconds: total, source: .mixed, liveSeconds: liveTotal)
        case (true, false): return TrafficForecast.Delay(seconds: total, source: .live)
        case (false, true): return TrafficForecast.Delay(seconds: total, source: .typical)
        case (false, false): return nil
        }
    }
}
