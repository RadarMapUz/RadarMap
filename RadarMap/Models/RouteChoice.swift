//
//  RouteChoice.swift
//  RadarMap
//
//  Какой вариант маршрута чем хорош — и какой предложить первым.
//
//  Движок отдаёт два-три варианта, и раньше они различались только числами:
//  «24 мин · 11 км · 📷 5». Выбирать по трём числам на ходу никто не станет,
//  поэтому у каждого варианта теперь есть ярлык — «Моя дорога» (24.4: домой
//  и на работу своим путём, MyRoad), «Знакомый», «Быстрый»,
//  «Меньше камер», «Без ваших превышений», «Проще», «Короткий» — и
//  объяснение, откуда он взялся.
//
//  Всё считается на телефоне, из того, что уже лежит в истории поездок:
//  треки и линии своего пути дом↔работа за 45 дней (для «Знакомого») и
//  проезды камер (для «Без ваших превышений»).
//  На сервер не уходит ничего — ни треки, ни выбор. И решение — правила, а
//  не обученная модель: ярлык обязан объясняться одной фразой («вы ездили
//  так 12 раз»), иначе ему не верят, а правило проверяется тестом.
//
//  Пробок здесь нет и не будет, пока нет честного источника: ярлык «Без
//  пробок» по догадке — ровно то, чего это приложение не делает.
//
//  Чистая логика — покрыта RouteChoiceTests.
//

import CoreLocation

nonisolated enum RouteChoice {

    /// Порядок объявления — порядок важности: в узкой плашке варианта
    /// помещается один ярлык, и это первый из его списка.
    enum Label: String, CaseIterable, Equatable, Sendable {
        /// «На пути перекрытие» (12б.5) — не достоинство, а предупреждение,
        /// поэтому первым: в узкой плашке виден именно он.
        case blocked
        /// «Моя дорога» (24.4): домой или на работу тем путём, которым
        /// водитель ездит сам (линия CommuteProfile). Выше «Знакомого»: это
        /// не «ездили похоже», а именно его ежедневный путь.
        case myRoad
        case familiar
        case fastest
        case fewerCameras
        case avoidsOverspeed
        case simpler
        case shortest
    }

    /// Вариант глазами выбора: путь, длина, время, камеры, манёвры.
    struct Input: Sendable {
        let path: [CLLocationCoordinate2D]
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let cameraIDs: [Int]
        /// Сложные манёвры (левые, развороты, кольца). nil — движок не
        /// назвал типы манёвров (MKDirections): тогда «Проще» не судим.
        let hardManeuvers: Int?
        /// Подтверждённых перекрытий на пути в нашу сторону (RoadEventRules).
        var closures: Int = 0
        /// Вариант — своя дорога домой или на работу (MyRoad); nil — нет.
        var personal: Personal? = nil
    }

    /// Своя дорога (24.4): куда, сколько поездок этим путём и время по ним.
    struct Personal: Equatable, Sendable {
        let direction: Commute.Direction
        let trips: Int
        /// Время по своим поездкам в этот час с пробками сверх обычного (с);
        /// nil — у часа мало поездок, сравниваем по времени движка.
        let seconds: TimeInterval?
        /// Пробки толпы сверх своего обычного, с.
        var jamSeconds: TimeInterval = 0
    }

    /// Линия своего пути из профиля дороги (CommuteProfile): одна на
    /// вариант, весом в число поездок, не попавших в треки истории.
    struct WeightedLine: Sendable {
        let line: [CLLocationCoordinate2D]
        let trips: Int
    }

    /// Что выбор знает о водителе.
    struct History: Sendable {
        /// Треки поездок: плоские тройки lat, lon, скорость (как в TripRecord).
        var tracks: [[Double]]
        /// Камеры, у которых водитель превышал (по той же мерке, что CameraFamiliarity).
        var overspeedCameraIDs: Set<Int>
        /// Свои пути дом↔работа за 45 дней (24.4): треки живут неделю, и
        /// «Знакомый» по ним одним видел ~5 поездок вместо месяца.
        var commuteLines: [WeightedLine] = []
    }

    struct Assessment: Equatable, Sendable {
        var labels: [Label] = []
        /// Доля варианта, пройденная раньше (без начала и конца пути).
        var familiarShare: Double = 0
        /// Сколько поездок прошли этим путём (покрыли его большую часть).
        var familiarTrips = 0
        /// Камеры варианта, у которых водитель превышал.
        var overspeedCameras = 0
        var hardManeuvers: Int?
        var closures = 0
        /// Своя дорога (24.4) — с временем по своим поездкам.
        var myRoad: Personal?

        static let none = Assessment()
    }

    struct Verdict: Equatable, Sendable {
        let assessments: [Assessment]
        /// Индекс варианта, который выбрать сразу.
        let recommended: Int
    }

    // MARK: - Решение

    static func decide(_ inputs: [Input], history: History?) -> Verdict {
        guard inputs.count > 1 else {
            // Один вариант — выбирать не из чего, но о перекрытии сказать надо.
            return Verdict(assessments: inputs.map { input in
                var single = Assessment.none
                single.closures = input.closures
                single.myRoad = input.personal
                single.labels = [input.closures > 0 ? Label.blocked : nil,
                                 input.personal != nil ? Label.myRoad : nil].compactMap { $0 }
                return single
            }, recommended: 0)
        }
        var result = inputs.map { Assessment(hardManeuvers: $0.hardManeuvers, closures: $0.closures) }

        if let history {
            let lines = history.commuteLines.filter { $0.trips > 0 && $0.line.count >= 2 }
            let familiarity = familiarity(of: inputs.map(\.path),
                                          tracks: history.tracks + lines.map(flatTrack),
                                          weights: history.tracks.map { _ in 1 } + lines.map(\.trips))
            for index in inputs.indices {
                result[index].familiarShare = familiarity[index].share
                result[index].familiarTrips = familiarity[index].trips
                result[index].overspeedCameras = inputs[index].cameraIDs
                    .filter(history.overspeedCameraIDs.contains).count
            }
        }

        // Быстрый — опорный: остальные ярлыки говорят «лучше быстрого в чём-то».
        let fastest = inputs.indices.min { inputs[$0].travelTime < inputs[$1].travelTime } ?? 0
        let base = inputs[fastest]
        var labels = Array(repeating: Set<Label>(), count: inputs.count)
        labels[fastest].insert(.fastest)
        for index in inputs.indices where inputs[index].closures > 0 {
            labels[index].insert(.blocked)
        }
        // Своя дорога — одна: её строит сам выбор (MyRoad), а не движок.
        let mine = inputs.firstIndex { $0.personal != nil }
        if let mine {
            labels[mine].insert(.myRoad)
            result[mine].myRoad = inputs[mine].personal
        }

        // Знакомый: заметно знакомее всех остальных и проезжен не раз.
        if history != nil, let best = result.indices.max(by: { result[$0].familiarShare < result[$1].familiarShare }) {
            let others = result.indices.filter { $0 != best }.map { result[$0].familiarShare }
            if result[best].familiarShare >= AppConfig.routeFamiliarMinShare,
               result[best].familiarTrips >= AppConfig.routeFamiliarMinTrips,
               others.allSatisfy({ result[best].familiarShare - $0 >= AppConfig.routeFamiliarMargin }) {
                labels[best].insert(.familiar)
            }
        }

        // Меньше камер: единственный минимум и меньше, чем у быстрого.
        if let fewest = uniqueMin(inputs.indices, by: { inputs[$0].cameraIDs.count }),
           inputs[fewest].cameraIDs.count < base.cameraIDs.count {
            labels[fewest].insert(.fewerCameras)
        }

        // Без ваших превышений: на быстром есть камеры, где вы превышали, а
        // на этом — ни одной. Кандидатов несколько — берём самый быстрый.
        if history != nil, result[fastest].overspeedCameras > 0 {
            let clean = inputs.indices.filter { result[$0].overspeedCameras == 0 }
            if let pick = clean.min(by: { inputs[$0].travelTime < inputs[$1].travelTime }) {
                labels[pick].insert(.avoidsOverspeed)
            }
        }

        // Проще: судим, только когда типы манёвров известны у ВСЕХ вариантов.
        let hard = inputs.compactMap(\.hardManeuvers)
        if hard.count == inputs.count, let baseHard = base.hardManeuvers,
           let simplest = uniqueMin(inputs.indices, by: { inputs[$0].hardManeuvers ?? .max }),
           baseHard - (inputs[simplest].hardManeuvers ?? baseHard) >= AppConfig.routeSimplerMinDelta {
            labels[simplest].insert(.simpler)
        }

        // Короткий: заметно короче быстрого.
        if let shortest = uniqueMin(inputs.indices, by: { inputs[$0].distance }), shortest != fastest {
            let gain = base.distance - inputs[shortest].distance
            if gain >= max(AppConfig.routeShorterMinMeters, base.distance * AppConfig.routeShorterMinShare) {
                labels[shortest].insert(.shortest)
            }
        }

        for index in inputs.indices {
            result[index].labels = Label.allCases.filter(labels[index].contains)
        }

        // Первым — своя дорога, если по сегодняшнему прогнозу она не дольше
        // быстрого (с пробками) больше допуска; затем знакомый на тех же
        // условиях; иначе быстрый.
        var recommended = fastest
        if let mine, isAffordable(time: inputs[mine].personal?.seconds ?? inputs[mine].travelTime,
                                  against: base.travelTime) {
            recommended = mine
        } else if let familiar = labels.firstIndex(where: { $0.contains(.familiar) }) {
            if isAffordable(time: inputs[familiar].travelTime, against: base.travelTime) {
                recommended = familiar
            }
        }
        // На пути перекрытие — первым не предлагаем: быстрейший из чистых.
        // Все перекрыты — оставляем как есть, ярлык скажет сам.
        if inputs[recommended].closures > 0,
           let clean = inputs.indices.filter({ inputs[$0].closures == 0 })
            .min(by: { inputs[$0].travelTime < inputs[$1].travelTime }) {
            recommended = clean
        }
        return Verdict(assessments: result, recommended: recommended)
    }

    /// Привычка стоит недорого: дольше быстрого не больше чем на
    /// max(3 мин, 10 %). `fastest` — время быстрого с пробками.
    static func isAffordable(time: TimeInterval, against fastest: TimeInterval) -> Bool {
        time - fastest <= max(AppConfig.routeFamiliarMaxExtraSeconds,
                              fastest * AppConfig.routeFamiliarMaxExtraShare)
    }

    /// Индекс единственного минимума; при ничьей — nil (ярлык «меньше» у
    /// двух вариантов сразу ничего не различает).
    private static func uniqueMin<T: Comparable>(_ indices: Range<Int>, by key: (Int) -> T) -> Int? {
        guard let best = indices.min(by: { key($0) < key($1) }) else { return nil }
        let value = key(best)
        return indices.filter { key($0) == value }.count == 1 ? best : nil
    }

    // MARK: - Сложные манёвры

    /// Левый поворот через встречку, разворот, крутой поворот, кольцо — то,
    /// что делает дорогу трудной. nil — хоть у одного шага тип неизвестен.
    static func hardManeuvers(_ steps: [RouteStep]) -> Int? {
        var count = 0
        for step in steps {
            guard let kind = step.kind else { return nil }
            switch kind {
            case .left, .sharpLeft, .sharpRight, .uturn, .roundabout: count += 1
            case .straight, .slightLeft, .slightRight, .right, .arrive: break
            }
        }
        return count
    }

    // MARK: - История

    /// Что выбор берёт из истории: последние поездки за окно — их треки и
    /// камеры, где было превышение. `now` параметром — воспроизводимо в тестах.
    static func history(from records: [TripRecord], profile: CommuteProfile.Book? = nil, now: Date,
                        windowDays: Int = AppConfig.routeFamiliarWindowDays,
                        maxTrips: Int = AppConfig.routeFamiliarMaxTrips) -> History {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        let recent = records.filter { $0.endedAt >= since }
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(maxTrips)
        var overspeed: Set<Int> = []
        var tracks: [[Double]] = []
        for record in recent {
            if let track = record.track, track.count >= 6 { tracks.append(track) }
            for pass in record.passed where pass.date >= since {
                if let over = pass.overLimitKmh, over > FineSchedule.toleranceKmh {
                    overspeed.insert(pass.cameraID)
                }
            }
        }
        return History(tracks: tracks, overspeedCameraIDs: overspeed,
                       commuteLines: commuteLines(profile, since: since,
                                                  tracked: Set(recent.filter { ($0.track?.count ?? 0) >= 6 }.map(\.id))))
    }

    /// Линии профиля дороги весом в поездки за окно. Поездка, чей трек уже
    /// есть в истории, не считается второй раз — её строка из веса вычтена.
    static func commuteLines(_ profile: CommuteProfile.Book?, since: Date,
                             tracked: Set<Double>) -> [WeightedLine] {
        guard let profile else { return [] }
        return (profile.toWork + profile.toHome).compactMap { variant in
            let trips = variant.rows.filter { $0.departure >= since && !tracked.contains($0.tripID) }.count
            let line = variant.coordinates
            return trips > 0 && line.count >= 2 ? WeightedLine(line: line, trips: trips) : nil
        }
    }

    /// Линия в формате трека истории (тройки lat, lon, скорость).
    static func flatTrack(_ line: WeightedLine) -> [Double] {
        line.line.flatMap { [$0.latitude, $0.longitude, 0] }
    }

    // MARK: - Знакомость

    struct Familiarity: Equatable, Sendable {
        var share: Double
        var trips: Int
    }

    /// Насколько каждый путь совпадает с прошлыми треками.
    ///
    /// Путь проходится шагом ~20 м (без начала и конца), каждая точка —
    /// клетка сетки ~30 м вместе с соседями. Треки растеризуются тем же
    /// шагом: они упрощены, и между точками бывают сотни метров прямой.
    /// Обратный индекс «клетка → точки путей» делает проверку одним поиском
    /// на точку трека, а не перебором всех путей.
    static func familiarity(of paths: [[CLLocationCoordinate2D]],
                            tracks: [[Double]], weights: [Int]? = nil) -> [Familiarity] {
        guard let reference = paths.first(where: { !$0.isEmpty })?.first else {
            return paths.map { _ in Familiarity(share: 0, trips: 0) }
        }
        let grid = Grid(latitude: reference.latitude)
        let samples = paths.map { sample($0, grid: grid) }

        var index: [Int64: [(path: Int, sample: Int)]] = [:]
        var bounds = Bounds()
        for (p, cells) in samples.enumerated() {
            for (s, cell) in cells.enumerated() {
                bounds.add(cell)
                for dy in -1...1 {
                    for dx in -1...1 {
                        index[Grid.key(cell.y + dy, cell.x + dx), default: []].append((p, s))
                    }
                }
            }
        }

        var covered = samples.map { Array(repeating: false, count: $0.count) }
        var trips = Array(repeating: 0, count: paths.count)
        // Отрезок длиннее — не дорога, а потеря GPS. Порог щедрый: трек
        // упрощён, и на прямой трассе между его точками бывают километры.
        let maxGap = 10_000.0

        for (number, track) in tracks.enumerated() {
            guard track.count >= 6 else { continue }
            // Линия профиля — это сразу несколько поездок одним путём.
            let weight = weights.map { number < $0.count ? max(1, $0[number]) : 1 } ?? 1
            var hit = samples.map { Array(repeating: false, count: $0.count) }
            var touched = false
            var previous: CLLocationCoordinate2D?
            for i in stride(from: 0, to: track.count - 2, by: 3) {
                let point = CLLocationCoordinate2D(latitude: track[i], longitude: track[i + 1])
                defer { previous = point }
                let cells: [Grid.Cell]
                if let previous {
                    let length = grid.meters(previous, point)
                    guard length <= maxGap else { continue }
                    cells = grid.walk(from: previous, to: point, length: length)
                } else {
                    cells = [grid.cell(point)]
                }
                for cell in cells where bounds.contains(cell) {
                    guard let entries = index[Grid.key(cell.y, cell.x)] else { continue }
                    touched = true
                    for entry in entries { hit[entry.path][entry.sample] = true }
                }
            }
            guard touched else { continue }
            for p in paths.indices where !samples[p].isEmpty {
                var count = 0
                for s in samples[p].indices where hit[p][s] {
                    count += 1
                    covered[p][s] = true
                }
                if Double(count) / Double(samples[p].count) >= AppConfig.routeFamiliarTripShare {
                    trips[p] += weight
                }
            }
        }

        return paths.indices.map { p in
            let total = samples[p].count
            let share = total == 0 ? 0 : Double(covered[p].filter { $0 }.count) / Double(total)
            return Familiarity(share: share, trips: trips[p])
        }
    }

    /// Точки пути шагом `routeFamiliarStepMeters`, без краёв. Короткий путь
    /// (краёв на нём не останется) берётся целиком.
    private static func sample(_ path: [CLLocationCoordinate2D], grid: Grid) -> [Grid.Cell] {
        guard path.count >= 2 else { return path.map(grid.cell) }
        var lengths: [Double] = [0]
        for i in 1..<path.count { lengths.append(lengths[i - 1] + grid.meters(path[i - 1], path[i])) }
        let total = lengths[lengths.count - 1]
        let step = AppConfig.routeFamiliarStepMeters
        var edge = AppConfig.routeFamiliarEdgeMeters
        if total < edge * 2 + step * 10 { edge = 0 }

        var cells: [Grid.Cell] = []
        var segment = 1
        var along = edge
        while along <= total - edge {
            while segment < path.count - 1, lengths[segment] < along { segment += 1 }
            let a = path[segment - 1], b = path[segment]
            let span = lengths[segment] - lengths[segment - 1]
            let t = span > 0 ? (along - lengths[segment - 1]) / span : 0
            let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                               longitude: a.longitude + (b.longitude - a.longitude) * t)
            let cell = grid.cell(point)
            if cells.last != cell { cells.append(cell) }
            along += step
        }
        return cells
    }

    /// Равноугольная сетка в метрах вокруг широты маршрута — для страны
    /// размером с Узбекистан искажение по широте меньше процента на 100 км.
    struct Grid {
        struct Cell: Equatable { let y: Int; let x: Int }

        let latStep: Double
        let lonStep: Double
        let metersPerLat = 111_320.0
        let metersPerLon: Double

        init(latitude: Double) {
            metersPerLon = 111_320.0 * cos(latitude * .pi / 180)
            latStep = AppConfig.routeFamiliarCellMeters / 111_320.0
            lonStep = AppConfig.routeFamiliarCellMeters / max(metersPerLon, 1)
        }

        func cell(_ c: CLLocationCoordinate2D) -> Cell {
            Cell(y: Int((c.latitude / latStep).rounded(.down)),
                 x: Int((c.longitude / lonStep).rounded(.down)))
        }

        func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            let dy = (b.latitude - a.latitude) * metersPerLat
            let dx = (b.longitude - a.longitude) * metersPerLon
            return (dx * dx + dy * dy).squareRoot()
        }

        /// Клетки отрезка шагом `routeFamiliarStepMeters` (конец включительно).
        func walk(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                  length: Double) -> [Cell] {
            let steps = max(1, Int((length / AppConfig.routeFamiliarStepMeters).rounded(.up)))
            var cells: [Cell] = []
            cells.reserveCapacity(steps)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let cell = cell(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t))
                if cells.last != cell { cells.append(cell) }
            }
            return cells
        }

        static func key(_ y: Int, _ x: Int) -> Int64 {
            (Int64(y) << 32) | (Int64(x) & 0xFFFF_FFFF)
        }
    }

    /// Рамка всех путей с запасом в клетку: трек вне неё не проверяется.
    private struct Bounds {
        var minY = Int.max, maxY = Int.min, minX = Int.max, maxX = Int.min

        mutating func add(_ c: Grid.Cell) {
            minY = min(minY, c.y - 1); maxY = max(maxY, c.y + 1)
            minX = min(minX, c.x - 1); maxX = max(maxX, c.x + 1)
        }

        func contains(_ c: Grid.Cell) -> Bool {
            c.y >= minY && c.y <= maxY && c.x >= minX && c.x <= maxX
        }
    }
}
