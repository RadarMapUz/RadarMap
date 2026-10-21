//
//  CommuteLiveSession.swift
//  RadarMap
//
//  Одна поездка дом↔работа на ходу (этап 8.8.2): куда мы на линии варианта,
//  сколько сегодня шли участки и когда пересчитать призрак. Чистая структура
//  без GPS и таймеров — её кормит CommuteLiveService фиксами, которые и так
//  приходят в поездке (ни одного нового запроса геопозиции).
//
//  Каждый вариант пути (их ≤ 3) ведётся отдельно: своя точка входа на линию,
//  свои пересечения границ и свой темп ρ. Общего состояния нет — иначе
//  пересечения по чужой линии портили темп, а выбранный однажды вариант
//  держал призрак немым, когда водитель уходил на другой знакомый путь
//  (ревью 19.10). Ведущий — ближайший к машине из тех, что на линии и
//  прошли 1,5 км; смена — только когда другой ближе заметно.
//
//  Отклонение Δ считается от точки входа на линию: поездка, начатая
//  автоматикой на 800-м метре или продолженная после магазина, сравнивается
//  с обычным временем от той же точки, а не от дома.
//
//  Бюджет на фикс: проекция только в окне линии вокруг прошлой точки; полный
//  проход — когда окно потеряло машину, не чаще раза в 200 м пути; далёкая
//  линия (едем другим путём) не сканируется вовсе, пока до неё заведомо
//  дальше порога; пересчёт прогноза — на границе участка или раз в 30 с.
//

import CoreLocation
import Foundation
import simd

nonisolated struct CommuteLiveSession: Sendable {

    /// Что увидеть и услышать после фикса.
    struct Output: Equatable, Sendable {
        let forecast: CommuteGhost.Forecast?
        let isOff: Bool
        /// Осталось по линии ведущего варианта, м (для правила голоса «≥ 2 км»).
        var remainingMeters: Double = 0
        /// Есть ведущий вариант. Нет — прогноз прятать: ведущий сошёл, а
        /// другой ещё не прошёл своих 1,5 км.
        var hasLead = false
        /// Почему дольше (8.8.12) — одним словом, и только когда причина видна.
        var reason: CommuteGhost.Reason?
        /// Ранний прогноз (24.3): ведущий ещё не прошёл 1,5 км — показать с
        /// вилкой, голосом не говорить.
        var early = false
        /// Пройдено и всего по линии ведущего, м — для журнала точности (24.1).
        var alongMeters: Double = 0
        var lengthMeters: Double = 0
        /// Честная вилка прогноза, с: разброс участков или целых поездок (что
        /// шире) на остаток пути.
        var spread: Double = 0
    }

    /// Вариант пути с базой, индексом линии и сегодняшним проездом по ней.
    private struct Candidate: Sendable {
        let base: CommuteGhost.Baseline
        let xy: [SIMD2<Double>]
        let cumulative: [Double]
        /// Линия в координатах — для рёбер пробок (CommuteEstimate.crowdSeconds).
        let coordinates: [CLLocationCoordinate2D]
        /// Время по пробкам на участках из последнего свежего `now.json`; nil —
        /// данных нет (8.8.10).
        var crowd: [Double?]?
        // Проекция.
        var cursor = 0
        var floor = 0.0
        /// Метров пути с прошлого полного прохода по линии.
        var sinceRescan = Double.infinity
        /// Отклонение на прошлом полном проходе, если линия была далеко: машина
        /// не приближается к линии быстрее, чем едет, поэтому пока
        /// `farOffset − sinceRescan` больше порога, линию можно не сканировать.
        var farOffset: Double?
        var offsetEMA: Double?
        // Сегодня по этой линии.
        var track = CommuteGhost.Track()
        /// Где и когда сегодня вошли на линию — от этой точки считается Δ.
        var joined: (along: Double, at: Date)?
        var lastAlong: Double?
        var lastTime: Date?
        var crossTimes: [Int: Date] = [:]
        var live: [(seconds: Double, median: Double, length: Double)] = []
        var rho = 1.0
        /// Секунды сверх медианы на пройденных участках, где и пробки по
        /// `now.json`, и сам проезд были хуже q75 (8.8.12): «пробка» — только
        /// если в ней и правда тащились, а не по старому файлу.
        var jamSeconds = 0.0
    }

    private let frame: CommuteProfile.Frame
    private var candidates: [Candidate]
    /// Ведущий вариант — его прогноз виден и слышен.
    private(set) var active: Int?
    private var lastPoint: SIMD2<Double>?
    private var lastForecastAt: Date?
    /// Где и когда машина встала (8.8.12): стоянка — время, пока фиксы не
    /// уходят от якоря дальше `commuteStandRadiusMeters`; пропуск фиксов
    /// (экран погашен, фильтр по расстоянию) засчитывается за вычетом времени
    /// на проезд расстояния медленным ходом — шаг между фиксами тут не годится.
    private var standAnchor: (p: SIMD2<Double>, t: Date)?
    private var longestStand: TimeInterval = 0
    /// Когда сделан файл пробок, легший в `crowd`: старше 10 мин — данных нет,
    /// даже если новый файл не пришёл (поездка ушла из сети).
    private var crowdGenerated: Date?
    /// Пришли новые пробки — пересчитать прогноз на ближайшем фиксе.
    private var crowdChanged = false

    /// Пробки на линиях вариантов (8.8.10): файл свежий — время по рёбрам на
    /// каждом участке, иначе — нет данных. Сам прогноз берёт из этого только
    /// участки дальше 2 км впереди: ближе сегодняшний темп уже знает пробку.
    mutating func setTraffic(_ snapshot: TrafficSnapshot?, now: Date) {
        guard let snapshot, snapshot.isFresh(now: now) else {
            if crowdGenerated != nil { crowdChanged = true }
            crowdGenerated = nil
            for i in candidates.indices { candidates[i].crowd = nil }
            return
        }
        crowdGenerated = snapshot.generated
        crowdChanged = true
        for i in candidates.indices {
            candidates[i].crowd = CommuteEstimate.crowdSeconds(line: candidates[i].coordinates,
                                                               base: candidates[i].base, snapshot: snapshot)
        }
    }

    /// nil — призрака нет: ни у одного варианта направления нет трёх
    /// подходящих поездок (выходной, непривычный час, мало истории).
    /// `bias` — сдвиг из журнала точности (CommuteAccuracy.biasFactor, 24.2).
    init?(variants: [CommuteProfile.Variant], weekend: Bool, departure: Date,
          bias: Double = 1, calendar: Calendar = .current) {
        var built: [Candidate] = []
        var lat0: Double?
        for variant in variants {
            // Выборка по близости выезда и база, приведённая к целым поездкам
            // (24.2): иначе 7:40 и 8:30 давали один прогноз, и он был
            // оптимистичнее каждой настоящей поездки на сумму красных.
            guard let selection = CommuteGhost.select(variant.rows, weekend: weekend,
                                                      departure: departure, calendar: calendar),
                  let base = CommuteGhost.calibratedBaseline(variant, selection: selection, bias: bias),
                  let first = variant.coordinates.first else { continue }
            if lat0 == nil { lat0 = first.latitude }
            let frame = CommuteProfile.Frame(latitude: lat0!)
            let xy = variant.coordinates.map { frame.xy($0.latitude, $0.longitude) }
            guard xy.count >= 2 else { continue }
            var cumulative: [Double] = [0]
            for (a, b) in zip(xy, xy.dropFirst()) { cumulative.append(cumulative.last! + simd_distance(a, b)) }
            built.append(Candidate(base: base, xy: xy, cumulative: cumulative,
                                   coordinates: variant.coordinates, crowd: nil))
        }
        guard let lat0, !built.isEmpty else { return nil }
        frame = CommuteProfile.Frame(latitude: lat0)
        candidates = built
    }

    mutating func note(lat: Double, lon: Double, accuracy: Double, at now: Date) -> Output {
        let p = frame.xy(lat, lon)
        let step = lastPoint.map { simd_distance($0, p) } ?? 0
        lastPoint = p
        // Стоянка — фиксы почти на месте подряд; одна долгая (заехал,
        // ждал у ворот) объясняет задержку словом «стояли» (8.8.12).
        if let anchor = standAnchor {
            let away = simd_distance(anchor.p, p)
            let since = now.timeIntervalSince(anchor.t)
            if away < AppConfig.commuteStandRadiusMeters {
                longestStand = max(longestStand, since)
            } else {
                longestStand = max(longestStand, since - away / AppConfig.commuteCrawlSpeedMps)
                standAnchor = (p, now)
            }
        } else {
            standAnchor = (p, now)
        }
        let accuracy = max(accuracy, 0)

        var crossed = Set<Int>()
        for i in candidates.indices where Self.advance(&candidates[i], p, step: step,
                                                       accuracy: accuracy, now: now) {
            crossed.insert(i)
        }
        let previous = active
        active = Self.lead(candidates, previous: previous)

        guard let index = active else {
            return Output(forecast: nil, isOff: candidates.allSatisfy { $0.track.isOff })
        }
        let c = candidates[index]
        let remainingMeters = max(0, c.base.length - c.floor)
        let early = !CommuteGhost.isConfirmed(along: c.floor)
        let due = index != previous || crossed.contains(index) || crowdChanged || lastForecastAt.map {
            now.timeIntervalSince($0) >= AppConfig.commuteGhostRecomputeSeconds
        } ?? true
        guard due, let joined = c.joined else {
            return Output(forecast: nil, isOff: false, remainingMeters: remainingMeters, hasLead: true,
                          early: early, alongMeters: c.floor, lengthMeters: c.base.length)
        }
        lastForecastAt = now
        crowdChanged = false
        // «В пути» — как если бы ехали от начала линии: сегодня с точки входа
        // плюс обычное время до неё.
        let elapsed = now.timeIntervalSince(joined.at) + c.base.total - c.base.usualRemaining(at: joined.along)
        let ahead = jamAhead(c, now: now)
        let forecast = CommuteGhost.forecast(c.base, along: c.floor, elapsed: elapsed,
                                             rho: Self.standingPace(c, now: now), now: now, jamAhead: ahead)
        return Output(forecast: forecast, isOff: false, remainingMeters: remainingMeters, hasLead: true,
                      reason: CommuteGhost.reason(delta: forecast.delta, jamSeconds: c.jamSeconds,
                                                  longestStand: longestStand, jamAhead: ahead),
                      early: early, alongMeters: c.floor, lengthMeters: c.base.length,
                      spread: max(forecast.sigma, c.base.spread * forecast.remaining))
    }

    /// Темп с учётом участка, на котором стоим (24.3): участок не пройден, а
    /// времени на нём уже больше его медианы — это нижняя граница его
    /// сегодняшнего времени, и она входит в темп сразу, а не после пересечения
    /// границы. Раньше стоянка в пробке двигала прибытие только на своё время
    /// (минута стоим — минута позже), а остаток пробки впереди темп узнавал
    /// лишь на следующем участке. Не запоминается: на пересечении темп
    /// посчитается по настоящему времени участка.
    private static func standingPace(_ c: Candidate, now: Date) -> Double {
        let base = c.base
        let k = base.locate(c.floor).segment
        guard k > 0, let entered = c.crossTimes[k - 1] else { return c.rho }
        let inSegment = now.timeIntervalSince(entered)
        guard inSegment > base.median[k] else { return c.rho }
        return CommuteGhost.pace(live: c.live + [(inSegment, base.median[k], base.length(of: k))],
                                 previous: c.rho)
    }

    /// Варианты, по которым идёт построенный маршрут (8.8.11): не меньше
    /// `commuteRouteOverlap` маршрута у линии варианта и финиш маршрута у
    /// конца линии. Тогда остаток призрака — по своим прошлым поездкам —
    /// честнее линейной доли маршрута; маршрут дальше работы (заехать после
    /// неё) — уже не дорога на работу, и остаток призрака его не покрыл бы.
    func matchingCandidates(route: [CLLocationCoordinate2D]) -> Set<Int> {
        guard let finish = route.last else { return [] }
        var result = Set<Int>()
        for (i, c) in candidates.enumerated() {
            guard let end = c.coordinates.last,
                  GeoMath.fastDistance(finish.latitude, finish.longitude, end.latitude, end.longitude)
                      <= AppConfig.commuteRouteFinishMeters,
                  DetourAdvisor.overlap(route, with: c.coordinates) >= AppConfig.commuteRouteOverlap
            else { continue }
            result.insert(i)
        }
        return result
    }

    /// Пробки сверх обычного на участках впереди (8.8.10): по каждому участку
    /// — то, на что пробка по `now.json` хуже того, что уже несёт сегодняшний
    /// темп ρ (он затухает с расстоянием). Так пробка в 300 м впереди
    /// учитывается сразу, а одна и та же пробка не считается дважды. Порог —
    /// своя медиана плюс четверть (24.3), а не q75: при широком своём разбросе
    /// q75 пропускал настоящие пробки, а медиана уже откалибрована к целым
    /// поездкам (обычные красные в ней есть). Файл старше 10 мин — ноль.
    private func jamAhead(_ c: Candidate, now: Date) -> Double {
        guard let crowd = c.crowd, let generated = crowdGenerated,
              now.timeIntervalSince(generated) <= AppConfig.trafficStaleSeconds else { return 0 }
        let base = c.base
        let k = base.locate(c.floor).segment
        let a = min(max(0, c.floor), base.length)
        var extra = 0.0
        for j in (k + 1)..<min(crowd.count, base.median.count) where j > k {
            guard let time = crowd[j], time > base.median[j] * AppConfig.commuteCrowdOverMedian else { continue }
            let rhoExcess = max(0, (c.rho - 1) * base.median[j]
                                * exp(-(base.start(of: j) - a) / AppConfig.commuteGhostDecayMeters))
            extra += max(0, time - base.median[j] - rhoExcess)
        }
        return extra
    }

    /// Фикс по одной линии: проекция, сход/возврат, пересечения границ и
    /// темп. true — пересекли границу участка (повод пересчитать).
    private static func advance(_ c: inout Candidate, _ p: SIMD2<Double>, step: Double,
                                accuracy: Double, now: Date) -> Bool {
        let (along, offset) = project(p, &c, step: step)
        c.offsetEMA = c.offsetEMA.map { $0 + (offset - $0) * 0.3 } ?? offset
        guard c.track.update(offset: offset, accuracy: accuracy, stepMeters: step) else {
            // Сошли: участок, растянутый через сход, — не темп. Вход до
            // подтверждения забываем — это могло быть пересечение линии на
            // перекрёстке, а не въезд на неё.
            c.lastAlong = nil
            c.lastTime = nil
            c.crossTimes.removeAll()
            if !CommuteGhost.isConfirmed(along: c.floor) { c.joined = nil }
            return false
        }
        if c.joined == nil {
            guard offset <= max(AppConfig.commuteGhostOffMeters, accuracy + 30) else { return false }
            c.joined = (along, now)
        }
        var crossed = false
        if let lastAlong = c.lastAlong, let lastTime = c.lastTime, along > lastAlong, now > lastTime {
            // Только границы между прошлой и новой точкой — не все участки.
            let base = c.base
            var j = base.locate(lastAlong).segment
            while j < base.ends.count, base.ends[j] <= along {
                defer { j += 1 }
                guard base.ends[j] > lastAlong else { continue }
                let share = (base.ends[j] - lastAlong) / (along - lastAlong)
                let t = lastTime.addingTimeInterval(share * now.timeIntervalSince(lastTime))
                c.crossTimes[j] = t
                if j > 0, let previous = c.crossTimes[j - 1] {
                    let live = t.timeIntervalSince(previous)
                    // Пробка на пройденном участке — и по файлу, и по своему
                    // проезду хуже обычного разброса (8.8.12).
                    if let crowd = c.crowd, j < crowd.count, let jam = crowd[j],
                       jam > base.median[j] * AppConfig.commuteCrowdOverMedian, live > base.q75[j] {
                        c.jamSeconds += live - base.median[j]
                    }
                    c.live.append((live, base.median[j], base.length(of: j)))
                    // Темпу нужны последние ~2 км — хвост дальше не храним.
                    if c.live.count > 64 { c.live.removeFirst(c.live.count - 64) }
                }
                crossed = true
            }
        }
        c.lastAlong = along
        c.lastTime = now
        if crossed { c.rho = CommuteGhost.pace(live: c.live, previous: c.rho) }
        return crossed
    }

    /// Может вести: на линии и прошёл 1,5 км по ней — или (24.3) уже 300 м,
    /// если въехал на линию у её начала: выехали от дома этой дорогой, а не
    /// пересекли её на перекрёстке. Гейт «уехал с пути» (Track) — тот же.
    private static func isEligible(_ c: Candidate) -> Bool {
        guard !c.track.isOff, let joined = c.joined else { return false }
        if CommuteGhost.isConfirmed(along: c.floor) { return true }
        return c.floor >= AppConfig.commuteGhostEarlyAlongMeters
            && joined.along <= AppConfig.commuteGhostEarlyJoinMeters
    }

    /// Ведущий: на линии и прошёл 1,5 км по ней (рано — см. isEligible). Прежний остаётся, пока другой
    /// не ближе к машине на `commuteGhostSwitchMeters`; при равенстве — тот,
    /// где больше поездок (обычнее).
    private static func lead(_ candidates: [Candidate], previous: Int?) -> Int? {
        let eligible = candidates.indices.filter { Self.isEligible(candidates[$0]) }
        guard let best = eligible.min(by: { a, b in
            let (ea, eb) = (candidates[a].offsetEMA ?? .infinity, candidates[b].offsetEMA ?? .infinity)
            return ea != eb ? ea < eb : candidates[a].base.rows > candidates[b].base.rows
        }) else { return nil }
        if let previous, eligible.contains(previous),
           (candidates[previous].offsetEMA ?? .infinity) - (candidates[best].offsetEMA ?? .infinity)
               < AppConfig.commuteGhostSwitchMeters {
            return previous
        }
        return best
    }

    /// Проекция в окне линии вокруг прошлой точки; потеряли — полный проход
    /// (для далёкой линии — не чаще раза в `commuteGhostRescanStepMeters`).
    /// Пройденное не откатывается назад дальше допуска (как в свёртке профиля).
    private static func project(_ p: SIMD2<Double>, _ c: inout Candidate,
                                step: Double) -> (along: Double, offset: Double) {
        func scan(_ range: ClosedRange<Int>) -> (along: Double, offset: Double, segment: Int) {
            var best = (along: c.floor, offset: Double.infinity, segment: c.cursor)
            for i in range {
                let (q, f) = CommuteProfile.Geometry.nearest(p, c.xy[i], c.xy[i + 1])
                let along = c.cumulative[i] + f * (c.cumulative[i + 1] - c.cumulative[i])
                if along + AppConfig.commuteProfileNearMeters < c.floor { continue }
                let offset = simd_distance(p, q)
                if offset < best.offset { best = (along, offset, i) }
            }
            return best
        }
        c.sinceRescan += step
        if let far = c.farOffset, far - c.sinceRescan > AppConfig.commuteGhostRescanMeters {
            return (c.floor, far - c.sinceRescan)
        }
        let last = c.xy.count - 2
        let lo = max(0, c.cursor - 2), hi = min(last, c.cursor + AppConfig.commuteGhostWindowSegments)
        var best = scan(lo...hi)
        if best.offset <= AppConfig.commuteGhostRescanMeters {
            c.farOffset = nil
        } else if last >= 0, c.sinceRescan >= AppConfig.commuteGhostRescanStepMeters {
            c.sinceRescan = 0
            let full = scan(0...last)
            if full.offset < best.offset { best = full }
            c.farOffset = best.offset > AppConfig.commuteGhostRescanMeters ? best.offset : nil
        }
        if best.offset.isFinite {
            c.cursor = best.segment
            c.floor = max(c.floor, best.along)
        }
        return (c.floor, best.offset)
    }
}
