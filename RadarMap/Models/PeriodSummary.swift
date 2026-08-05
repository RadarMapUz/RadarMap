//
//  PeriodSummary.swift
//  RadarMap
//
//  Сводка за период для отчёта «Неделя / Месяц / Всё время». Раньше на экране
//  Итогов была одна строчка «за 7 дней: N поездок» — по ней нельзя понять,
//  стал ты ездить аккуратнее или нет. Здесь считается всё, что отвечает на
//  вопрос «как прошла неделя», включая сравнение с прошлой.
//
//  Чистые функции без Date.now по умолчанию внутри вычислений — время всегда
//  приходит параметром, поэтому всё воспроизводимо в тестах (PeriodSummaryTests).
//

import Foundation
import CoreLocation

/// Период отчёта. nonisolated: читается из чистого TripHistory и его тестов.
nonisolated enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week:  return String(localized: "Неделя")
        case .month: return String(localized: "Месяц")
        case .all:   return String(localized: "Всё время")
        }
    }

    /// Длина окна в секундах; nil — без ограничения.
    var interval: TimeInterval? {
        switch self {
        case .week:  return 7 * 86400
        case .month: return 30 * 86400
        case .all:   return nil
        }
    }

    /// Сколько столбиков в графике по дням (для «всего времени» график не нужен).
    var chartDays: Int? {
        switch self {
        case .week:  return 7
        case .month: return 30
        case .all:   return nil
        }
    }

    /// Подпись под главной цифрой: «95,2 км» без периода читается двусмысленно.
    var caption: String {
        switch self {
        case .week:  return String(localized: "за неделю")
        case .month: return String(localized: "за месяц")
        case .all:   return String(localized: "за всё время")
        }
    }

    /// Заголовок блока выводов — разбор всегда о том же окне, что и цифры.
    var insightsTitle: String {
        switch self {
        case .week:  return String(localized: "Разбор недели")
        case .month: return String(localized: "Разбор месяца")
        case .all:   return String(localized: "Разбор за всё время")
        }
    }

    /// Заголовок списка поездок — список подчиняется тому же фильтру.
    var tripsTitle: String {
        switch self {
        case .week:  return String(localized: "Поездки за неделю")
        case .month: return String(localized: "Поездки за месяц")
        case .all:   return String(localized: "Последние поездки")
        }
    }
}

/// Всё, что показывает отчёт за период.
nonisolated struct PeriodSummary: Equatable {
    var trips = 0
    var distance: CLLocationDistance = 0
    /// Время в движении — стоянки склеенных поездок исключены.
    var movingDuration: TimeInterval = 0
    var cameras = 0
    /// Проезды камер в лимите и с штрафуемым превышением.
    var cleanPasses = 0
    var overPasses = 0
    var maxSpeedKmh: Double = 0
    /// Средний балл за период, взвешенный по дистанции.
    var rating: Int?
    /// Возможные штрафы за период (по реальным ступеням BRV).
    var fineRisk: Double = 0
    /// Камера, где превышали чаще всего — «зона риска».
    var topOverLocation: String?
    /// Сколько превышений пришлось на эту камеру — без числа совет «сбавьте там»
    /// звучит одинаково и для одного раза, и для пяти.
    var topOverCount = 0
    /// Самый активный день периода.
    var busiestDay: Date?
    var busiestDayKm: Double = 0
    /// Календарных дней, в которые была хоть одна поездка («дней за рулём»).
    var activeDays = 0
    /// Дистанция за предыдущий такой же период — база для дельты.
    var previousDistance: CLLocationDistance = 0
    /// Штрафуемые превышения за предыдущий такой же период: по ним видно, стал
    /// водитель ездить чище или наоборот.
    var previousOverPasses = 0
    /// Рейтинг за предыдущий период (nil — сравнивать не с чем).
    var previousRating: Int?
    /// Штрафуемые превышения по часам суток — «когда именно я рискую».
    var overByHour = [Int](repeating: 0, count: 24)

    var isEmpty: Bool { trips == 0 }
    var averageSpeedKmh: Double {
        movingDuration > 0 ? distance / movingDuration * 3.6 : 0
    }
    /// Доля чистых проездов 0…1 (nil — камер за период не было).
    var cleanShare: Double? {
        let total = cleanPasses + overPasses
        return total > 0 ? Double(cleanPasses) / Double(total) : nil
    }
    /// Насколько больше/меньше проехали, чем в предыдущем таком же периоде.
    /// nil — сравнивать не с чем (первый период).
    var distanceDeltaPercent: Int? {
        guard previousDistance > 500 else { return nil }
        return Int(((distance / previousDistance - 1) * 100).rounded())
    }

    /// Превышений на 100 км. Сравнивать периоды «в штуках» нечестно: неделя с
    /// дачей в 600 км всегда проигрывает неделе, когда машина стояла во дворе.
    /// nil — проехали слишком мало, чтобы нормировать.
    var overPer100km: Double? {
        guard distance >= 10_000 else { return nil }
        return Double(overPasses) / (distance / 100_000)
    }

    var previousOverPer100km: Double? {
        guard previousDistance >= 10_000 else { return nil }
        return Double(previousOverPasses) / (previousDistance / 100_000)
    }

    /// Изменение рейтинга к прошлому периоду (nil — сравнивать не с чем).
    var ratingDelta: Int? {
        guard let rating, let previousRating else { return nil }
        return rating - previousRating
    }

    /// Превышения по четырёхчасовым блокам суток (6 корзин) — данные полосы
    /// «часы риска» и вывода «почти всё — вечером».
    var overByBlock: [Int] {
        (0..<6).map { block in
            (0..<4).reduce(0) { $0 + overByHour[block * 4 + $1] }
        }
    }

    /// Блок суток, на который пришлось больше всего превышений, и его доля.
    var peakBlock: PeakBlock? {
        let blocks = overByBlock
        guard let top = blocks.enumerated().max(by: { $0.element < $1.element }),
              top.element > 0 else { return nil }
        let total = blocks.reduce(0, +)
        return PeakBlock(index: top.offset, count: top.element,
                         share: total > 0 ? Double(top.element) / Double(total) : 0)
    }
}

/// Пик риска по времени суток: какой четырёхчасовой блок и какая доля превышений.
nonisolated struct PeakBlock: Equatable {
    let index: Int
    let count: Int
    let share: Double

    /// «18:00–22:00» — подпись блока.
    var title: String {
        String(format: "%02d:00–%02d:00", index * 4, (index * 4 + 4) % 24)
    }
}

extension TripHistory {

    /// Сводка за период. `now` параметром — чтобы тесты не зависели от часов.
    static func summary(_ history: [TripRecord], period: StatsPeriod,
                        calendar: Calendar = .current,
                        now: Date = Date()) -> PeriodSummary {
        var result = PeriodSummary()
        let records = self.records(history, period: period, now: now)
        guard !records.isEmpty else { return result }

        var overByLocation: [String: Int] = [:]
        var kmByDay: [Date: Double] = [:]
        for record in records {
            result.trips += 1
            result.distance += record.distanceMeters
            result.movingDuration += record.movingDuration
            result.cameras += record.camerasPassed
            result.maxSpeedKmh = max(result.maxSpeedKmh, record.maxSpeedKmh)
            let day = calendar.startOfDay(for: record.startedAt)
            kmByDay[day, default: 0] += record.distanceMeters / 1000

            for pass in record.passed {
                // Без известного лимита нарушения не выдумываем — как в month30.
                guard let limit = pass.limitKmh else { continue }
                let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
                if fine > 0 {
                    result.overPasses += 1
                    result.fineRisk += fine
                    result.overByHour[calendar.component(.hour, from: pass.date)] += 1
                    if !pass.location.isEmpty { overByLocation[pass.location, default: 0] += 1 }
                } else {
                    result.cleanPasses += 1
                }
            }
        }
        if let top = overByLocation.max(by: { $0.value < $1.value }) {
            result.topOverLocation = top.key
            result.topOverCount = top.value
        }
        if let busiest = kmByDay.max(by: { $0.value < $1.value }) {
            result.busiestDay = busiest.key
            result.busiestDayKm = busiest.value
        }
        result.activeDays = kmByDay.count
        result.rating = weightedRating(
            history,
            from: period.interval.map { now.addingTimeInterval(-$0) } ?? .distantPast,
            now: now)

        // Предыдущее такое же окно — база для всех сравнений «стало лучше/хуже».
        if let interval = period.interval {
            let to = now.addingTimeInterval(-interval)
            let from = to.addingTimeInterval(-interval)
            let previous = window(history, from: from, to: to)
            result.previousDistance = previous.distance
            result.previousOverPasses = previous.overPasses
            result.previousRating = weightedRating(history, from: from, now: to)
        }
        return result
    }

    /// Дистанция и штрафуемые превышения в произвольном окне — общая основа
    /// сравнения с прошлым периодом.
    private static func window(_ history: [TripRecord], from: Date, to: Date)
        -> (distance: CLLocationDistance, overPasses: Int) {
        var distance = 0.0
        var overPasses = 0
        for record in history where record.startedAt > from && record.startedAt <= to {
            distance += record.distanceMeters
            for pass in record.passed {
                guard let limit = pass.limitKmh else { continue }
                if FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0 { overPasses += 1 }
            }
        }
        return (distance, overPasses)
    }

    /// Записи, попадающие в период.
    static func records(_ history: [TripRecord], period: StatsPeriod,
                        now: Date = Date()) -> [TripRecord] {
        guard let interval = period.interval else { return history }
        let from = now.addingTimeInterval(-interval)
        return history.filter { $0.startedAt > from && $0.startedAt <= now }
    }

    /// Километры по дням периода (нулевые дни включены) — данные графика.
    /// Вместе с километрами считаем штрафуемые превышения дня: красный столбик
    /// отвечает на вопрос «когда именно я нарушал», а не просто «сколько ездил».
    static func dailyKm(_ history: [TripRecord], days: Int,
                        calendar: Calendar = .current,
                        now: Date = Date()) -> [DayBar] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: DayBar] = [:]
        for record in history {
            let day = calendar.startOfDay(for: record.startedAt)
            var bar = byDay[day] ?? DayBar(day: day)
            bar.km += record.distanceMeters / 1000
            bar.overPasses += record.passed.reduce(0) { count, pass in
                guard let limit = pass.limitKmh,
                      FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0
                else { return count }
                return count + 1
            }
            byDay[day] = bar
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today)
            else { return nil }
            return byDay[day] ?? DayBar(day: day)
        }
    }

    /// Поездки для списка истории. Список подчиняется тому же фильтру, что и весь
    /// экран: раньше он всегда показывал «последние 7» — переключаешь «Месяц», а
    /// список не меняется, и непонятно, чем управляет фильтр. Для «Всего времени»
    /// показываем последние `visibleHistory`: там записей может быть под сотню.
    static func historyList(_ history: [TripRecord], period: StatsPeriod,
                            now: Date = Date()) -> [TripRecord] {
        guard period.interval != nil else { return Array(history.prefix(visibleHistory)) }
        return records(history, period: period, now: now)
    }

    /// Треки периода для карты отчёта: только те записи, у которых трек ещё жив
    /// (см. pruned — за пределами недели он выброшен).
    static func tracks(_ history: [TripRecord], period: StatsPeriod,
                       now: Date = Date()) -> [[TrackPoint]] {
        records(history, period: period, now: now)
            .map(\.trackPoints)
            .filter { $0.count >= 2 }
    }

    /// Всё, что рисует карта проездов: треки, маркеры камер и слой частоты.
    /// Собирается на смену периода, а не на каждый пересчёт вьюхи.
    /// @concurrent обязателен: `nonisolated async` при NonisolatedNonsendingByDefault
    /// бежит на акторе вызывающего — расчёт шёл на main и дёргал открытие Итогов.
    @concurrent static func mapData(_ history: [TripRecord], period: StatsPeriod,
                                    now: Date = Date()) async -> PeriodMapData {
        let tracks = self.tracks(history, period: period, now: now)
        return PeriodMapData(tracks: tracks,
                             markers: passMarkers(history, period: period, now: now),
                             heat: await heatLines(tracks))
    }

    /// Данные карты для одной поездки: сам трек и камеры именно этого проезда.
    /// Слой частоты для одной поездки не имеет смысла — линия рисуется яркой.
    static func mapData(of record: TripRecord) -> PeriodMapData {
        let track = record.trackPoints
        return PeriodMapData(tracks: track.count >= 2 ? [track] : [],
                             markers: passMarkers(of: record), heat: [])
    }

    /// Проезды камер одной поездки — маркеры выбранного трека.
    static func passMarkers(of record: TripRecord) -> [PassMarker] {
        markers(from: [record])
    }

    /// Проезды камер периода, сгруппированные по точке: сколько раз проезжали,
    /// было ли превышение, максимальная скорость проезда. Маркеры карты отчёта
    /// и карточка по тапу («где я превышал»).
    static func passMarkers(_ history: [TripRecord], period: StatsPeriod,
                            now: Date = Date()) -> [PassMarker] {
        markers(from: records(history, period: period, now: now))
    }

    private static func markers(from records: [TripRecord]) -> [PassMarker] {
        var byCamera: [Int: PassMarker] = [:]
        for record in records {
            for pass in record.passed {
                guard let lat = pass.lat, let lon = pass.lon else { continue }
                let over = pass.limitKmh.map {
                    FineSchedule.fine(overKmh: pass.speedKmh - Double($0)) > 0
                } ?? false
                if var existing = byCamera[pass.cameraID] {
                    existing.times += 1
                    existing.overTimes += over ? 1 : 0
                    existing.maxSpeedKmh = max(existing.maxSpeedKmh, pass.speedKmh)
                    existing.limitKmh = existing.limitKmh ?? pass.limitKmh
                    byCamera[pass.cameraID] = existing
                } else {
                    byCamera[pass.cameraID] = PassMarker(
                        cameraID: pass.cameraID, lat: lat, lon: lon,
                        location: pass.location, times: 1, overTimes: over ? 1 : 0,
                        maxSpeedKmh: pass.speedKmh, limitKmh: pass.limitKmh)
                }
            }
        }
        return byCamera.values.sorted { $0.times > $1.times }
    }
}

// MARK: - Слой частоты («тепло») карты проездов

extension TripHistory {

    /// Склеивает треки периода в слой линий с частотой проездов: сколько РАЗНЫХ
    /// поездок прошло по каждому участку (проезд «туда и обратно» внутри одной
    /// поездки счётчик не накручивает). Каждый трек затем режется на куски одного
    /// градуса частоты.
    ///
    /// Зачем: десяток наложенных друг на друга линий одной яркости давал паутину,
    /// в которой ежедневная дорога на работу выглядела так же, как единственная
    /// поездка на дачу. С частотой постоянный коридор виден сразу, а разовые
    /// поездки уходят в фон как контекст.
    ///
    /// Считаем ячейки ВДОЛЬ СЕГМЕНТОВ, а не только в вершинах: трек хранится
    /// упрощённым (Дуглас-Пекер ±22 м), поэтому на прямой улице два проезда
    /// оставляют вершины в разных местах — по вершинам совпадение не нашлось бы
    /// и коридор никогда не загорелся.
    /// @concurrent: десятки тысяч ячеек сетки — этому не место на main.
    @concurrent static func heatLines(_ tracks: [[TrackPoint]],
                                      cellMeters: Double = AppConfig.heatCellMeters) async -> [HeatLine] {
        guard let reference = tracks.first(where: { $0.count >= 2 })?.first else { return [] }
        let latStep = cellMeters / 111_320
        let lonStep = cellMeters / (111_320 * max(0.2, cos(reference.lat * .pi / 180)))

        func cell(lat: Double, lon: Double) -> Int64 {
            let y = Int64((lat / latStep).rounded())
            let x = Int64((lon / lonStep).rounded())
            return y << 32 | (x & 0xFFFF_FFFF)
        }

        /// Ячейки, которые покрывает участок: шаг полклетки, чтобы не проскакивать.
        func cells(from a: TrackPoint, to b: TrackPoint) -> [Int64] {
            let steps = max(1, Int((GeoMath.fastDistance(a.lat, a.lon, b.lat, b.lon)
                                    / (cellMeters * 0.5)).rounded(.up)))
            return (0...steps).map { step in
                let t = Double(step) / Double(steps)
                return cell(lat: a.lat + (b.lat - a.lat) * t,
                            lon: a.lon + (b.lon - a.lon) * t)
            }
        }

        let drawable = tracks.filter { $0.count >= 2 }
        var cellsByTrack: [[[Int64]]] = []
        cellsByTrack.reserveCapacity(drawable.count)
        var counts: [Int64: Int] = [:]
        for track in drawable {
            var perSegment: [[Int64]] = []
            perSegment.reserveCapacity(track.count - 1)
            var visited = Set<Int64>()
            for index in 1..<track.count {
                let keys = cells(from: track[index - 1], to: track[index])
                perSegment.append(keys)
                visited.formUnion(keys)
            }
            cellsByTrack.append(perSegment)
            for key in visited { counts[key, default: 0] += 1 }
        }

        /// Частота участка — по самой редкой его ячейке: коридор считается общим
        /// только если поездки шли рядом на всём участке.
        func times(of keys: [Int64]) -> Int {
            keys.reduce(Int.max) { min($0, counts[$1] ?? 1) }
        }

        var result: [HeatLine] = []
        var id = 0
        var fallback: [HeatLine] = []
        for (trackIndex, track) in drawable.enumerated() {
            let perSegment = cellsByTrack[trackIndex]
            let smoothed = medianSmoothed(perSegment.map(times(of:)))
            var run = [track[0]]
            var runTimes = smoothed[0]
            for index in 1..<track.count {
                let segmentTimes = smoothed[index - 1]
                if HeatLine.tier(times: segmentTimes) == HeatLine.tier(times: runTimes) {
                    run.append(track[index])
                } else {
                    result.append(HeatLine(id: id, points: run, times: runTimes))
                    id += 1
                    // Граничная вершина входит в оба куска — линия без разрыва.
                    run = [track[index - 1], track[index]]
                    runTimes = segmentTimes
                }
            }
            if run.count >= 2 {
                result.append(HeatLine(id: id, points: run, times: runTimes))
                id += 1
            }
            fallback.append(HeatLine(id: trackIndex, points: track,
                                     times: medianSmoothed(smoothed, window: smoothed.count)
                                         .first ?? 1))
        }
        // Страховка от дробления: за потолком рисуем по одной линии на поездку.
        guard result.count <= AppConfig.heatMaxLines else { return fallback }
        // Редкие участки рисуются первыми, частый коридор — поверх них.
        return result.sorted { $0.tier < $1.tier }
    }

    /// Медиана по окну: одиночные провалы частоты (шум GPS то попадает в ячейку
    /// соседнего проезда, то нет) иначе резали бы трек на сотни коротких кусков.
    static func medianSmoothed(_ values: [Int], window: Int = 5) -> [Int] {
        guard values.count > 2, window > 1 else { return values }
        let radius = max(1, window / 2)
        return values.indices.map { index in
            let from = max(0, index - radius)
            let to = min(values.count - 1, index + radius)
            let slice = values[from...to].sorted()
            return slice[slice.count / 2]
        }
    }
}

/// Готовые данные карты проездов: считаются один раз на смену периода или выбор
/// поездки, а не на каждый пересчёт вьюхи.
nonisolated struct PeriodMapData {
    var tracks: [[TrackPoint]] = []
    var markers: [PassMarker] = []
    /// Пусто — рисуем `tracks` в полную яркость (режим одной поездки).
    var heat: [HeatLine] = []

    var isEmpty: Bool { tracks.isEmpty && markers.isEmpty }
}

/// Участок карты проездов с частотой: сколько поездок прошло по этому коридору.
nonisolated struct HeatLine: Identifiable {
    let id: Int
    let points: [TrackPoint]
    let times: Int

    /// 0 — разовый участок, 1 — повторяющийся, 2 — постоянный коридор.
    var tier: Int { Self.tier(times: times) }

    static func tier(times: Int) -> Int {
        if times >= AppConfig.heatFrequentTimes { return 2 }
        if times >= AppConfig.heatRepeatedTimes { return 1 }
        return 0
    }

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

/// Столбик графика «километры по дням».
nonisolated struct DayBar: Identifiable, Equatable {
    let day: Date
    var km: Double = 0
    /// Штрафуемых превышений за этот день — столбик краснеет.
    var overPasses = 0

    var id: Date { day }
    var hasOverspeed: Bool { overPasses > 0 }
}

/// Камера на карте отчёта: сколько раз проезжали, сколько из них с превышением
/// и с какой максимальной скоростью.
nonisolated struct PassMarker: Identifiable, Equatable {
    let cameraID: Int
    let lat: Double
    let lon: Double
    let location: String
    var times: Int
    var overTimes: Int
    var maxSpeedKmh: Double
    var limitKmh: Int?

    var id: Int { cameraID }
    var hasViolation: Bool { overTimes > 0 }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
