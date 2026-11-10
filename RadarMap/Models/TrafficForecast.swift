//
//  TrafficForecast.swift
//  RadarMap
//
//  Пробки в ETA ЛЮБОГО маршрута (27.E, п. 2): живые, где им можно верить, и
//  обычные для этого часа — где нельзя.
//
//  До 27.E задержку маршруту давал только свежий now.json (TrafficSnapshot
//  .delay), а «обычно по водителям» (traffic/typical) знала одна дорога на
//  работу. Сборщик лёг на полчаса, now.json старше 10 минут, или маршрут на
//  три часа, где живые пробки на третьем часу — уже история, — и время в пути
//  было временем пустых дорог графа, даже в 8:30 буднего утра.
//
//  Правило по шагам маршрута (~25 м, та же мерка, что у живых пробок):
//    * момент шага — выезд + время пути до него (по графу, с уже набранной
//      задержкой): пробка встретится тогда, а не сейчас;
//    * момент ближе `trafficLiveHorizonSeconds` от сейчас и now.json свеж —
//      живые пробки; живые пробки этого шага не нашли медленного ребра —
//      значит, его нет: обычную пробку поверх свежего «свободно» не кладём;
//    * иначе — файл «обычно» класса дня и часа этого момента (будни/выходные
//      по Ташкенту, праздник — выходной): маршрут через смену часа берёт
//      следующий файл; файла нет, а now.json свеж — живые, как до 27.E;
//    * ни того, ни другого — нет данных (nil), а не «пробок нет».
//  Задержка — только от медленных рёбер против скорости графа, как у живых:
//  свободный поток ETA не трогает (быстрее OSRM мы угадывать не берёмся).
//
//  «Выехать в 8:30» — тот же расчёт с выездом в будущем: живые пробки к
//  нему не относятся (момент дальше горизонта), только «обычно» того часа.
//
//  Не трогает ни личный остаток («призрак» дороги на работу —
//  personalRemaining), ни мерку объезда (engineRemaining — только живые):
//  объезд по прогнозу выдумывал бы выигрыш, которого сейчас нет.
//
//  Чистая логика, время и календарь — параметрами; покрыто TrafficForecastTests.
//

import CoreLocation
import Foundation

nonisolated enum TrafficForecast {

    /// Откуда задержка: живые пробки, обычные для часа или обе (ближняя часть
    /// пути — живые, дальняя — обычные).
    enum Source: Equatable, Sendable {
        case live, typical, mixed
    }

    struct Delay: Equatable, Sendable {
        let seconds: TimeInterval
        let source: Source
        /// Часть `seconds` от живых пробок (now.json); остальное — «обычно»
        /// (профиль часа недели или файл часа). Не задана — по источнику:
        /// живые — вся задержка, иначе ноль.
        let liveSeconds: TimeInterval
        /// Доля пути в живом горизонте, где под шагом было измеренное ребро
        /// свежего now.json (0…1); живого горизонта нет — 0. Не задана — 1.
        let liveMeasuredShare: Double

        init(seconds: TimeInterval, source: Source, liveSeconds: TimeInterval? = nil,
             liveMeasuredShare: Double = 1) {
            self.seconds = seconds
            self.source = source
            self.liveSeconds = liveSeconds ?? (source == .live ? seconds : 0)
            self.liveMeasuredShare = liveMeasuredShare
        }
    }

    /// Задержка, которую можно показать водителю (77). Почти ноль — это
    /// «без пробок» и зелёный, а их вправе сказать только измеренные рёбра:
    /// путь, о котором свежий now.json почти ничего не знает, — «нет данных»
    /// (nil: нейтральная подпись и цвет, в машине — системный), а не «свободно».
    /// Заметная задержка остаётся: медленные рёбра измерены.
    static func claimable(_ delay: Delay?) -> Delay? {
        guard let delay, delay.seconds < AppConfig.trafficFreeClaimSeconds,
              delay.liveMeasuredShare < AppConfig.trafficFreeMinMeasuredShare else { return delay }
        return nil
    }

    /// Доля измеренного пути: `measured` метров из `span` в живом горизонте.
    static func share(measured: Double, of span: Double) -> Double {
        span > 0 ? min(1, measured / span) : 0
    }

    /// Чем подписать задержку варианта (решение 28.10): «+N мин из-за пробок»
    /// или «обычно +N мин в это время».
    enum Cause: Equatable, Sendable {
        case jams, usual
    }

    /// Живая часть — не меньше половины задержки: это пробки сейчас; иначе —
    /// обычная картина часа. Смешанный источник со свежим, но пустым на
    /// нашем пути now.json — «обычно», а не живые пробки (симуляция 27.10:
    /// «+10 мин из-за пробок» почти целиком из профиля).
    static func cause(total: TimeInterval, live: TimeInterval) -> Cause {
        guard total > 0 else { return .jams }
        return max(0, live) * 2 >= total ? .jams : .usual
    }

    /// Файлы «обычно», которые понадобятся маршруту: час выезда и каждый
    /// следующий час пути (с запасом на пробки — половина времени сверху),
    /// но не дальше `typicalTrafficMaxSpanSeconds`.
    static func buckets(departure: Date, travelTime: TimeInterval,
                        calendar: Calendar = TypicalTraffic.tashkent) -> Set<TypicalTraffic.Bucket> {
        let span = min(max(0, travelTime) * 1.5, AppConfig.typicalTrafficMaxSpanSeconds)
        var out: Set<TypicalTraffic.Bucket> = [TypicalTraffic.bucket(for: departure, calendar: calendar)]
        var moment = departure
        while let next = calendar.dateInterval(of: .hour, for: moment)?.end,
              next.timeIntervalSince(departure) <= span {
            out.insert(TypicalTraffic.bucket(for: next, calendar: calendar))
            moment = next
        }
        return out
    }

    /// Задержка пробками на маршруте `route` с временем по графу `baseTime`.
    /// - Parameters:
    ///   - departure: выезд (сейчас или «выехать в 8:30»);
    ///   - live: now.json как есть — свежесть проверяется здесь;
    ///   - typical: файл «обычно» часа или nil — нет файла.
    static func delay(along route: [CLLocationCoordinate2D], baseTime: TimeInterval,
                      departure: Date, now: Date, live: TrafficSnapshot?,
                      typical: (TypicalTraffic.Bucket) -> TrafficSnapshot?,
                      calendar: Calendar = TypicalTraffic.tashkent) -> Delay? {
        guard route.count >= 2 else { return nil }
        var length = 0.0
        for (p, q) in zip(route, route.dropFirst()) {
            length += GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
        }
        guard length > 0 else { return nil }
        let pace = max(0, baseTime) / length          // с/м по графу
        let liveFresh = live.map { $0.isFresh(now: now) } ?? false
        let liveUntil = now.addingTimeInterval(AppConfig.trafficLiveHorizonSeconds)
        // Запасной путь «файла часа нет — по живым» — только для поездки,
        // которая начинается сейчас: к выезду завтра в 8:30 вечерняя пробка
        // не относится ни ближней частью, ни дальней.
        let liveFallback = liveFresh && departure <= liveUntil

        var files: [TypicalTraffic.Bucket: TrafficSnapshot?] = [:]
        var bucket: (until: Date, file: TrafficSnapshot?)?
        func typicalFile(at moment: Date) -> TrafficSnapshot? {
            if let bucket, moment < bucket.until { return bucket.file }
            let key = TypicalTraffic.bucket(for: moment, calendar: calendar)
            let file: TrafficSnapshot?
            if let cached = files[key] { file = cached } else {
                file = typical(key)
                files[key] = file
            }
            let until = calendar.dateInterval(of: .hour, for: moment)?.end ?? moment.addingTimeInterval(3600)
            bucket = (until, file)
            return file
        }

        var total: TimeInterval = 0, liveTotal: TimeInterval = 0
        var travelled = 0.0, liveSpan = 0.0, liveMeasured = 0.0
        var usedLive = false, usedTypical = false
        func liveStep(_ live: TrafficSnapshot, at point: CLLocationCoordinate2D, course: Double, step: Double) {
            usedLive = true
            liveSpan += step
            guard let delay = live.measuredStepDelay(at: point, course: course, length: step) else { return }
            liveMeasured += step
            total += delay
            liveTotal += delay
        }
        for (p, q) in zip(route, route.dropFirst()) {
            let segment = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard segment > 0.5 else { continue }
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((segment / RouteTraffic.stepMeters).rounded(.up)))
            let step = segment / Double(steps)
            for s in 0..<steps {
                let t = (Double(s) + 0.5) / Double(steps)
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                let moment = departure.addingTimeInterval((travelled + step / 2) * pace + total)
                travelled += step
                if liveFresh, let live, moment <= liveUntil {
                    liveStep(live, at: point, course: course, step: step)
                } else if let file = typicalFile(at: moment) {
                    usedTypical = true
                    total += file.stepDelay(at: point, course: course, length: step)
                } else if liveFallback, let live {
                    // Файла часа нет — дальняя часть по живым, как до 27.E:
                    // пробка сорокаминутной давности ближе к правде, чем ничего.
                    liveStep(live, at: point, course: course, step: step)
                }
            }
        }
        let measured = share(measured: liveMeasured, of: liveSpan)
        switch (usedLive, usedTypical) {
        case (true, true):  return Delay(seconds: total, source: .mixed, liveSeconds: liveTotal,
                                         liveMeasuredShare: measured)
        case (true, false): return Delay(seconds: total, source: .live, liveMeasuredShare: measured)
        case (false, true): return Delay(seconds: total, source: .typical, liveMeasuredShare: measured)
        case (false, false): return nil
        }
    }
}
