//
//  TripHistory.swift
//  RadarMap
//
//  Аналитика истории поездок: чистые функции без состояния — рейтинг, экономия,
//  сводки, группировки, чистка хранилища. Всё покрывается тестами напрямую;
//  вьюхи и TripStats читают готовые результаты.
//

import Foundation
import CoreLocation

nonisolated enum TripHistory {
    /// Сколько поездок показывает список истории.
    static let visibleHistory = 7
    /// Потолок хранилища: дальше даже «цифры для статистики» не копим.
    static let maxHistory = 50

    // MARK: - Чистка хранилища

    /// Трек — самая тяжёлая часть записи (до 400 точек). Держим его у последних
    /// `visibleHistory` поездок И у всего, что попадает в недельный отчёт: карта
    /// недели обязана рисовать все треки за 7 дней, а не только семь последних
    /// поездок — иначе в активную неделю отчёт молча врёт. Дальше трек
    /// выбрасываем (цифры остаются), а старше 30 дней удаляем совсем:
    /// пожизненные счётчики давно в lifetime.
    static func pruned(_ history: [TripRecord], now: Date = Date()) -> [TripRecord] {
        let monthAgo = now.addingTimeInterval(-30 * 86400)
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        var result: [TripRecord] = []
        result.reserveCapacity(min(history.count, maxHistory))
        for (index, record) in history.enumerated() {
            guard index < visibleHistory || record.startedAt > monthAgo else { continue }
            guard result.count < maxHistory else { break }
            if index < visibleHistory || record.startedAt > weekAgo {
                result.append(record)
            } else {
                var slim = record
                slim.track = nil
                result.append(slim)
            }
        }
        return result
    }

    // MARK: - Рейтинг и экономия

    /// Средний балл поездок за интервал, взвешенный по дистанции
    /// (длинная трасса весит больше короткой поездки до магазина).
    static func weightedRating(_ history: [TripRecord],
                               within interval: TimeInterval, now: Date) -> Int? {
        weightedRating(history, from: now.addingTimeInterval(-interval), now: now)
    }

    /// То же, но с явной нижней границей: для «всего времени» вычитать
    /// бесконечный интервал из даты нельзя.
    static func weightedRating(_ history: [TripRecord], from: Date, now: Date) -> Int? {
        var weightedSum = 0.0
        var weight = 0.0
        for record in history where record.startedAt > from && record.startedAt <= now {
            guard let score = record.score else { continue }
            let w = max(record.distanceMeters, 500)
            weightedSum += score * w
            weight += w
        }
        guard weight > 0 else { return nil }
        return Int((weightedSum / weight).rounded())
    }

    /// «Возможные штрафы» поездки/записи — красная строка в деталке.
    ///
    /// Считается ТОЛЬКО по достоверным лимитам. Лимит, предположенный по классу
    /// дороги, годится для рейтинга и для голоса — там цена ошибки лишний
    /// совет, — но назвать по догадке сумму в сумах значит соврать про деньги.
    /// Проезд с предположенным лимитом виден в разборе как превышение, но в
    /// сумму не входит.
    static func fineRisk(of passes: [PassedCamera]) -> Double {
        passes.reduce(0.0) { total, pass in
            guard pass.limitIsCertain, pass.countsTowardFines,
                  let limit = pass.limitKmh else { return total }
            return total + FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
        }
    }

    /// «Пришло штрафов» — суммы проездов, по которым постановление дошло.
    /// Те же ворота достоверности, что у fineRisk: деньги — только по
    /// известному лимиту.
    static func finesPaid(of passes: [PassedCamera]) -> Double {
        passes.reduce(0.0) { total, pass in
            guard pass.limitIsCertain, pass.finePaid == true,
                  let limit = pass.limitKmh else { return total }
            return total + FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
        }
    }

    /// Зависшие штрафы: денежные ожидания без ответа дольше `olderThanDays` —
    /// сколько их и с какого самого старого проезда. nil — напоминать не о чем.
    /// Трёхсостояние работает, только если человек отмечает исход, — а он
    /// забывает; без напоминания «риск» копит суммы, давно решившиеся на почте.
    /// Считается по всей истории, не по окну периода: зависший штраф остаётся
    /// зависшим, в каком периоде на него ни смотри; дата самого старого нужна,
    /// чтобы напоминание открывало именно тот период, где он лежит.
    static func pendingFineNudge(_ history: [TripRecord],
                                 olderThanDays: Int = AppConfig.finePendingNudgeDays,
                                 now: Date = Date()) -> (count: Int, oldest: Date)? {
        let threshold = now.addingTimeInterval(-Double(olderThanDays) * 86400)
        var count = 0
        var oldest = Date.distantFuture
        for record in history {
            for pass in record.passed {
                guard pass.limitIsCertain, pass.fineOutcome == .pending,
                      let limit = pass.limitKmh, pass.date < threshold,
                      FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0
                else { continue }
                count += 1
                oldest = min(oldest, pass.date)
            }
        }
        return count > 0 ? (count, oldest) : nil
    }

    /// Задать судьбу штрафа проезда: ожидается / пришёл / не пришёл.
    /// Состояния взаимоисключимы — «пришёл» снимает «не пришёл» и наоборот.
    /// nil — проезда нет в записи или он без штрафной ступени: отмечать нечего,
    /// и молчаливое «успешно» скрывало бы рассинхрон экрана с данными.
    static func settingFineOutcome(_ record: TripRecord, passID: UUID,
                                   outcome: PassedCamera.FineOutcome) -> TripRecord? {
        guard let index = record.passed.firstIndex(where: { $0.id == passID }),
              let limit = record.passed[index].limitKmh,
              FineSchedule.fine(overKmh: record.passed[index].speedKmh - Double(limit)) > 0
        else { return nil }
        var updated = record
        // nil, а не false: непомеченная запись не должна раздуваться полями.
        updated.passed[index].fineDismissed = outcome == .dismissed ? true : nil
        updated.passed[index].finePaid = outcome == .paid ? true : nil
        return updated
    }

    // MARK: - Сводки для экрана Итогов

    struct DayGroup {
        let day: Date
        fileprivate(set) var records: [TripRecord]
    }

    /// История приходит от новых к старым — группировка по календарным дням
    /// сохраняет порядок и не пересортировывает записи внутри дня.
    static func dayGroups(_ history: [TripRecord],
                          calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for record in history {
            let day = calendar.startOfDay(for: record.startedAt)
            if let last = groups.indices.last, groups[last].day == day {
                // Через subscript массив мутируется на месте: `+ [record]`
                // копировал весь день заново на каждую его поездку.
                groups[last].records.append(record)
            } else {
                groups.append(DayGroup(day: day, records: [record]))
            }
        }
        return groups
    }

    /// Что показывать в шапке Итогов: живую сессию (nil) или последнюю поездку.
    static func fallbackRecord(history: [TripRecord], isTripActive: Bool,
                               liveDistance: CLLocationDistance) -> TripRecord? {
        (isTripActive || liveDistance > 0) ? nil : history.first
    }

    // MARK: - Гео-чистка проездов

    /// Расстояние (метры) от точки до ломаной трека — по сегментам, не по вершинам:
    /// после Дугласа-Пекера прямые участки хранят только концы.
    static func distanceToTrack(lat: Double, lon: Double, track: [TrackPoint]) -> Double {
        guard let first = track.first else { return .greatestFiniteMagnitude }
        let metersPerLat = 111_320.0
        let metersPerLon = 111_320.0 * cos(first.lat * .pi / 180)
        func project(_ plat: Double, _ plon: Double) -> (x: Double, y: Double) {
            ((plon - first.lon) * metersPerLon, (plat - first.lat) * metersPerLat)
        }
        let p = project(lat, lon)
        guard track.count >= 2 else {
            let a = project(first.lat, first.lon)
            return hypot(p.x - a.x, p.y - a.y)
        }
        var best = Double.greatestFiniteMagnitude
        var a = project(track[0].lat, track[0].lon)
        for i in 1..<track.count {
            let b = project(track[i].lat, track[i].lon)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
            a = b
        }
        return best
    }

    /// Пороги ретро-чистки: живой гейт траверза плюс запас на упрощение трека
    /// (±22 м, точки раз в 30 м). Прежние единые 120 м были калиброваны под
    /// старый гейт в 80 м и пропускали ровно то, ради чего чистка существует:
    /// камеру поперечной улицы развязки. Для рукотворных точек (свои камеры,
    /// краудсорс — id от firstHandPlacedCameraID) порог шире, как и живой:
    /// их координату ставил человек, а не снап по оси дороги.
    static let passCleanupMaxMeters = 70.0
    static let passCleanupNoProfileMaxMeters = 110.0
    /// Зеркало CameraRepository.firstCustomID: с этого id начинаются точки,
    /// поставленные руками (свои камеры, за ними краудсорс с 2 000 000).
    static let firstHandPlacedCameraID = 1_000_001

    /// Направление трека в ближайшей к точке (lat, lon) вершине — азимут
    /// сегмента, на который пришёлся минимум расстояния. nil — трека мало.
    static func trackBearing(nearLat lat: Double, lon: Double,
                             track: [TrackPoint]) -> Double? {
        guard track.count >= 2 else { return nil }
        var best = Double.greatestFiniteMagnitude
        var index = 0
        for i in 1..<track.count {
            // Достаточно вершинной близости: сегменты трека короткие (30 м шаг).
            let d = GeoMath.fastDistance(lat, lon, track[i].lat, track[i].lon)
            if d < best { best = d; index = i }
        }
        let a = track[max(0, index - 1)]
        let b = track[min(track.count - 1, index == 0 ? 1 : index)]
        guard a.lat != b.lat || a.lon != b.lon else { return nil }
        return GeoMath.bearing(from: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                               to: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
    }

    /// Ретро-порог оси шире живого (55°): упрощённый трек срезает углы.
    static let passAxisCleanupMaxAngle = 60.0

    /// Ретро-чистка «мостовых» проездов: направление трека у камеры против оси
    /// её дороги. Ехал поперёк — это был мост/перпендикулярная улица развязки,
    /// проезд не наш: выкидываем и пересчитываем балл поездки.
    static func axisSanitized(_ history: [TripRecord],
                              axisByID: [Int: Int]) -> ([TripRecord], Bool) {
        var changed = false
        let cleaned = history.map { record -> TripRecord in
            let track = record.trackPoints
            guard track.count >= 2, !record.passed.isEmpty else { return record }
            let kept = record.passed.filter { pass in
                guard let axis = axisByID[pass.cameraID],
                      let lat = pass.lat, let lon = pass.lon,
                      let bearing = trackBearing(nearLat: lat, lon: lon, track: track)
                else { return true }   // нет оси/координат — не судим
                return GeoMath.axisDifference(course: bearing, axis: Double(axis))
                    <= passAxisCleanupMaxAngle
            }
            guard kept.count != record.passed.count else { return record }
            changed = true
            var out = record
            out = TripRecord(id: record.id, startedAt: record.startedAt,
                             endedAt: record.endedAt,
                             distanceMeters: record.distanceMeters,
                             maxSpeedKmh: record.maxSpeedKmh, passed: kept,
                             endLat: record.endLat, endLon: record.endLon,
                             track: record.track,
                             score: DrivingScore.tripScore(
                                 passes: kept.map {
                                     DrivingScore.Pass(speedKmh: $0.speedKmh,
                                                       limitKmh: $0.limitKmh)
                                 },
                                 trackSpeeds: track.map(\.speedKmh)),
                             stops: record.stops,
                             endedManually: record.endedManually)
            return out
        }
        return (cleaned, changed)
    }

    /// Ретро-чистка истории: убирает «проезды» камер, до которых трек ближе
    /// 120 м не подходил (раньше засчитывались камеры с параллельных улиц),
    /// и пересчитывает балл затронутых поездок. Возвращает (история, менялось ли).
    static func sanitized(_ history: [TripRecord]) -> ([TripRecord], Bool) {
        var changed = false
        let cleaned = history.map { record -> TripRecord in
            let track = record.trackPoints
            guard track.count >= 2, !record.passed.isEmpty else { return record }
            let kept = record.passed.filter { pass in
                guard let lat = pass.lat, let lon = pass.lon else { return true }
                let limit = pass.cameraID >= firstHandPlacedCameraID
                    ? passCleanupNoProfileMaxMeters : passCleanupMaxMeters
                return distanceToTrack(lat: lat, lon: lon, track: track) <= limit
            }
            guard kept.count != record.passed.count else { return record }
            changed = true
            return TripRecord(id: record.id, startedAt: record.startedAt,
                              endedAt: record.endedAt,
                              distanceMeters: record.distanceMeters,
                              maxSpeedKmh: record.maxSpeedKmh, passed: kept,
                              endLat: record.endLat, endLon: record.endLon,
                              track: record.track,
                              score: DrivingScore.tripScore(
                                  passes: kept.map {
                                      DrivingScore.Pass(speedKmh: $0.speedKmh,
                                                        limitKmh: $0.limitKmh)
                                  },
                                  trackSpeeds: track.map(\.speedKmh)),
                              stops: record.stops,
                              endedManually: record.endedManually)
        }
        return (cleaned, changed)
    }

    // MARK: - Ручное разделение склеенной поездки

    /// Разделить поездку на две по остановке — страховка на случай, когда
    /// автоматика (TripMerge) склеила лишнее: «заехал на час к другу» она видит
    /// как обед по пути. Возвращает две записи в порядке «новее → старше»,
    /// как их хранит история.
    ///
    /// Проезды камер делим по времени (у PassedCamera есть дата), трек — по
    /// точке, ближайшей к месту остановки: временных меток у точек трека нет,
    /// а координата стоянки известна точно. Дистанцию раскладываем по длине
    /// своей части трека, чтобы сумма осталась равна накопленной по GPS.
    static func split(_ record: TripRecord, at stop: TripStop) -> [TripRecord] {
        let track = record.trackPoints
        guard track.count >= 4 else { return [record] }

        // Индекс разреза: ближайшая к стоянке точка трека, но не на самом краю.
        let cut = (1..<(track.count - 1)).min {
            GeoMath.fastDistance(track[$0].lat, track[$0].lon, stop.lat, stop.lon)
                < GeoMath.fastDistance(track[$1].lat, track[$1].lon, stop.lat, stop.lon)
        } ?? track.count / 2
        let head = Array(track[0...cut])
        let tail = Array(track[cut...])

        let headLength = polylineLength(head)
        let tailLength = polylineLength(tail)
        let total = headLength + tailLength
        let headShare = total > 0 ? headLength / total : 0.5

        let remaining = (record.stops ?? []).filter { $0.id != stop.id }
        let first = leg(of: record, track: head, stops: remaining.filter { $0.to <= stop.from },
                        from: record.startedAt, to: stop.from,
                        distance: record.distanceMeters * headShare,
                        passes: record.passed.filter { $0.date <= stop.from })
        let second = leg(of: record, track: tail, stops: remaining.filter { $0.from >= stop.to },
                         from: stop.to, to: record.endedAt,
                         distance: record.distanceMeters * (1 - headShare),
                         passes: record.passed.filter { $0.date > stop.from })
        return [second, first]   // история идёт от новых к старым
    }

    private static func leg(of record: TripRecord, track: [TrackPoint], stops: [TripStop],
                            from: Date, to: Date, distance: CLLocationDistance,
                            passes: [PassedCamera]) -> TripRecord {
        let speeds = track.map(\.speedKmh)
        return TripRecord(
            id: from.timeIntervalSince1970,
            startedAt: from, endedAt: to,
            distanceMeters: distance,
            maxSpeedKmh: speeds.max() ?? record.maxSpeedKmh,
            passed: passes,
            endLat: track.last?.lat, endLon: track.last?.lon,
            track: track.count >= 2 ? track.flatMap { [$0.lat, $0.lon, $0.speedKmh] } : nil,
            score: DrivingScore.tripScore(
                passes: passes.map {
                    DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh)
                },
                trackSpeeds: speeds),
            stops: stops.isEmpty ? nil : stops,
            endedManually: record.endedManually)
    }

    private static func polylineLength(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(0.0) { sum, i in
            sum + GeoMath.fastDistance(points[i - 1].lat, points[i - 1].lon,
                                       points[i].lat, points[i].lon)
        }
    }
}
