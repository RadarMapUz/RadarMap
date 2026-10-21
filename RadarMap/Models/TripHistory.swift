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

    /// Сроки хранения — параметром, а не числами внутри чистки (15.1): срок
    /// станет настройкой «Хранить историю» (15.2), и это должно быть заменой
    /// одной строки `current`, а не переписыванием чистки. Числа `current` —
    /// те же, что жили в pruned с самого начала.
    struct Retention: Equatable, Sendable {
        /// Запись старше стольких дней удаляется (кроме `keepLast` новейших);
        /// nil — по возрасту не удаляется.
        var recordDays: Int?
        /// Столько новейших поездок не трогают ни срок, ни вырезка трека:
        /// список последних поездок не пустеет у того, кто ездит раз в месяц.
        var keepLast: Int
        /// Потолок числа записей; nil — без потолка.
        var maxRecords: Int?
        /// Трек старше стольких дней вырезается, цифры остаются; nil — живёт
        /// вместе с записью.
        var trackDays: Int?

        static let current = Retention(recordDays: 30, keepLast: visibleHistory,
                                       maxRecords: maxHistory, trackDays: 7)

        func recordCutoff(now: Date) -> Date? {
            recordDays.map { now.addingTimeInterval(-Double($0) * 86400) }
        }

        func trackCutoff(now: Date) -> Date? {
            trackDays.map { now.addingTimeInterval(-Double($0) * 86400) }
        }
    }

    /// Трек — самая тяжёлая часть записи (до 400 точек). Держим его у последних
    /// `visibleHistory` поездок И у всего, что попадает в недельный отчёт: карта
    /// недели обязана рисовать все треки за 7 дней, а не только семь последних
    /// поездок — иначе в активную неделю отчёт молча врёт. Дальше трек
    /// выбрасываем (цифры остаются), а старше 30 дней удаляем совсем:
    /// пожизненные счётчики давно в lifetime.
    ///
    /// `offset` — сколько записей НОВЕЕ этого куска уже оставлено (история
    /// по месяцам, 15.1): месяц, который не читался на старте, чистится
    /// отдельно, и его позиции в общей истории начинаются не с нуля. Чистка
    /// кусками от новых к старым с таким сдвигом даёт ровно то же, что чистка
    /// всей истории разом (проверено тестом).
    static func pruned(_ history: [TripRecord], retention: Retention = .current,
                       now: Date = Date(), offset: Int = 0) -> [TripRecord] {
        let recordCutoff = retention.recordCutoff(now: now)
        let trackCutoff = retention.trackCutoff(now: now)
        var result: [TripRecord] = []
        result.reserveCapacity(min(history.count, retention.maxRecords ?? history.count))
        for (index, record) in history.enumerated() {
            let protected = offset + index < retention.keepLast
            guard protected || recordCutoff.map({ record.startedAt > $0 }) ?? true else { continue }
            if let cap = retention.maxRecords, offset + result.count >= cap { break }
            if protected || trackCutoff.map({ record.startedAt > $0 }) ?? true {
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

    /// «Пришло штрафов» — суммы проездов, по которым постановление дошло:
    /// сумма постановления, если его внесли, иначе оценка по достоверному
    /// лимиту (PassedCamera.paidAmount — одно правило с днём и периодом).
    static func finesPaid(of passes: [PassedCamera]) -> Double {
        passes.reduce(0.0) { $0 + ($1.paidAmount ?? 0) }
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
              FineSchedule.fine(overKmh: record.passed[index].speedKmh - Double(limit)) > 0,
              // Сверен с внесённым постановлением — судьбу правит экран
              // «Штрафы» (отвязка), а не кнопка: иначе штраф в списке и
              // проезд разошлись бы.
              record.passed[index].fineReceiptID == nil
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
    /// Отметки водителей — id от этого (MobileCameraService.idOffset).
    static let firstCrowdCameraID = 2_000_000

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
            // Копия с правкой, а не сборка по полям: чистка выбрасывает ЛОЖНЫЕ
            // проезды и пересчитывает балл, остальное — как было. Сборка по
            // полям молча теряла каждое поле с дефолтом nil, которое забыли
            // передать: расход заряда, пометку рейса (12б.9), точку старта
            // (ревью 14.1, хвост 14.8).
            var out = record
            out.passed = kept
            out.score = DrivingScore.tripScore(
                passes: kept.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                trackSpeeds: track.map(\.speedKmh))
            return out
        }
        return (cleaned, changed)
    }

    /// Ретро-подъём лимитов до пола фиксации (EnforcedLimit).
    ///
    /// Записи, сделанные до появления пола, судились по тегу OSM: проезд на
    /// 66 км/ч по улице с тегом 50 стоил 440 000 сум возможного штрафа и −8 к
    /// баллу, хотя камера на 50 в городе не стоит ни одна. Чистка снимает это
    /// обвинение задним числом.
    ///
    /// Проезды НЕ удаляются — у них меняется только лимит, и сырой уезжает в
    /// `roadLimitKmh`, чтобы экран проезда по-прежнему мог назвать знак.
    /// Балл поездки пересчитывается тем же `DrivingScore`, что и живой.
    /// Возвращает (история, менялось ли).
    static func limitFloored(_ history: [TripRecord]) -> ([TripRecord], Bool) {
        var changed = false
        let cleaned = history.map { record -> TripRecord in
            guard record.passed.contains(where: { EnforcedLimit.isFloored(road: $0.limitKmh) })
            else { return record }
            changed = true
            let raised = record.passed.map { pass -> PassedCamera in
                guard EnforcedLimit.isFloored(road: pass.limitKmh) else { return pass }
                var out = pass
                out.roadLimitKmh = pass.limitKmh
                out.limitKmh = EnforcedLimit.applied(to: pass.limitKmh)
                return out
            }
            // Копия с правкой — остальные поля как были (см. axisSanitized).
            var out = record
            out.passed = raised
            // Балла может не быть вовсе (старая запись без трека) — тогда его и
            // не появляется: выдумывать рейтинг там, где его не считали, нельзя.
            out.score = record.score == nil ? nil : DrivingScore.tripScore(
                passes: raised.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                trackSpeeds: record.trackPoints.map(\.speedKmh))
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
            // Копия с правкой — остальные поля как были (см. axisSanitized).
            var out = record
            out.passed = kept
            out.score = DrivingScore.tripScore(
                passes: kept.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                trackSpeeds: track.map(\.speedKmh))
            return out
        }
        return (cleaned, changed)
    }

    /// Разовая чистка после S6 (S30, 20.10): проезды мимо отметок «Пост ДПС»
    /// и «ДТП» (скорость они не меряют, а стоили баллов и «возможных
    /// штрафов») из истории снимаются; у отметок водителей — подпись
    /// «Отмечен водителями, исчезнет ~14:05», бессмысленная после проезда.
    /// Записи копируются, а не собираются заново: поля, добавленные позже
    /// (старт поездки, «промолчало»), не теряются. Возвращает (история,
    /// снятые проезды, менялось ли).
    static func crowdCleaned(_ history: [TripRecord]) -> ([TripRecord], [PassedCamera], Bool) {
        var changed = false
        var removed: [PassedCamera] = []
        let cleaned = history.map { record -> TripRecord in
            guard record.passed.contains(where: { !$0.kind.recordsPasses || isCrowdCaption($0) }) else {
                return record
            }
            changed = true
            var copy = record
            removed += record.passed.filter { !$0.kind.recordsPasses }
            copy.passed = record.passed.filter(\.kind.recordsPasses).map { pass in
                guard isCrowdCaption(pass) else { return pass }
                var out = pass
                out.location = ""
                return out
            }
            if record.score != nil, copy.passed.count != record.passed.count {
                copy.score = DrivingScore.tripScore(
                    passes: copy.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                    trackSpeeds: record.trackPoints.map(\.speedKmh))
            }
            return copy
        }
        return (cleaned, removed, changed)
    }

    // MARK: - Одна точка — один проезд (11.1)

    /// Тот же проезд, записанный второй раз: в базе есть настоящие дубли —
    /// две камеры одного типа в 1–11 м друг от друга с одним направлением
    /// (13 пар в v11, план 11.1). PassTracking следит за каждой, что стала
    /// ближайшей, и проезд такой пары писался дважды: двойной «штраф» и
    /// двойной минус в рейтинге за одну точку. Повтор — тот же тип в
    /// `passDuplicateMeters` за `passDuplicateSeconds`; у старых записей без
    /// координат судить не по чему — не повтор.
    static func isDuplicate(cameraID: Int, typeRaw: String, lat: Double?, lon: Double?, date: Date,
                            of previous: [PassedCamera]) -> Bool {
        guard let lat, let lon else { return false }
        return previous.contains { other in
            guard other.cameraID != cameraID, other.typeRaw == typeRaw,
                  let otherLat = other.lat, let otherLon = other.lon,
                  abs(date.timeIntervalSince(other.date)) <= AppConfig.passDuplicateSeconds else { return false }
            return GeoMath.fastDistance(lat, lon, otherLat, otherLon) <= AppConfig.passDuplicateMeters
        }
    }

    /// Разовая чистка уже записанных повторов: в каждой поездке остаётся
    /// первый проезд точки. Записи копируются (как `crowdCleaned`), балл
    /// пересчитывается. Возвращает (история, снятые проезды, менялось ли).
    static func duplicatesCleaned(_ history: [TripRecord]) -> ([TripRecord], [PassedCamera], Bool) {
        var changed = false
        var removed: [PassedCamera] = []
        let cleaned = history.map { record -> TripRecord in
            var kept: [PassedCamera] = []
            var dropped: [PassedCamera] = []
            for pass in record.passed.sorted(by: { $0.date < $1.date }) {
                if isDuplicate(cameraID: pass.cameraID, typeRaw: pass.typeRaw, lat: pass.lat, lon: pass.lon,
                               date: pass.date, of: kept) {
                    dropped.append(pass)
                } else {
                    kept.append(pass)
                }
            }
            guard !dropped.isEmpty else { return record }
            changed = true
            removed += dropped
            var copy = record
            let droppedIDs = Set(dropped.map(\.id))
            copy.passed = record.passed.filter { !droppedIDs.contains($0.id) }
            if record.score != nil {
                copy.score = DrivingScore.tripScore(
                    passes: copy.passed.map { DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                    trackSpeeds: record.trackPoints.map(\.speedKmh))
            }
            return copy
        }
        return (cleaned, removed, changed)
    }

    /// Подписи проездов камер базы — одним алфавитом, как база после 11.6
    /// (AddressText): «Итоги» складывают превышения по тексту места, и одно
    /// место раскололось бы на «старое» и «новое». Свои камеры и отметки
    /// водителей не трогаем — их подписи на языке интерфейса. Счёт не
    /// меняется, поэтому дни и «за всё время» не трогаются.
    static func labelsNormalized(_ history: [TripRecord]) -> ([TripRecord], Bool) {
        var changed = false
        let normalized = history.map { record -> TripRecord in
            guard record.passed.contains(where: { $0.cameraID < firstHandPlacedCameraID
                && AddressText.normalized($0.location) != $0.location }) else { return record }
            changed = true
            var copy = record
            copy.passed = record.passed.map { pass in
                guard pass.cameraID < firstHandPlacedCameraID else { return pass }
                var out = pass
                out.location = AddressText.normalized(pass.location)
                return out
            }
            return copy
        }
        return (normalized, changed)
    }

    private static func isCrowdCaption(_ pass: PassedCamera) -> Bool {
        pass.cameraID >= firstCrowdCameraID && !pass.location.isEmpty
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

        // Расход заряда делим ПО ВРЕМЕНИ, а не по километрам: батарея садится
        // за часы, а не за расстояние — в пробке она тратится, а километры нет.
        // Остаток отдаём второй ноге целиком, поэтому сумма половин равна
        // исходной цифре ровно — это обратная операция к TripMerge, которая при
        // склейке расходы складывает.
        let headSeconds = stop.from.timeIntervalSince(record.startedAt)
        let tailSeconds = record.endedAt.timeIntervalSince(stop.to)
        let batterySeconds = headSeconds + tailSeconds
        let batteryShare = batterySeconds > 0 ? headSeconds / batterySeconds : headShare
        let headDrop = record.batteryDropPercent
            .map { Int((Double($0) * batteryShare).rounded()) }
        let tailDrop = record.batteryDropPercent
            .flatMap { total in headDrop.map { total - $0 } }

        let remaining = (record.stops ?? []).filter { $0.id != stop.id }
        // Старт первой ноги — старт исходной записи, второй — точка разреза
        // (там же кончается первая): без них ноги через неделю, когда трек
        // вырезан, теряли начало (ревью 14.1, хвост 14.8).
        let first = leg(of: record, track: head, stops: remaining.filter { $0.to <= stop.from },
                        start: record.startCoordinate,
                        from: record.startedAt, to: stop.from,
                        distance: record.distanceMeters * headShare,
                        passes: record.passed.filter { $0.date <= stop.from },
                        batteryDrop: headDrop)
        let second = leg(of: record, track: tail, stops: remaining.filter { $0.from >= stop.to },
                         start: tail.first.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                         from: stop.to, to: record.endedAt,
                         distance: record.distanceMeters * (1 - headShare),
                         passes: record.passed.filter { $0.date > stop.from },
                         batteryDrop: tailDrop)
        return [second, first]   // история идёт от новых к старым
    }

    private static func leg(of record: TripRecord, track: [TrackPoint], stops: [TripStop],
                            start: CLLocationCoordinate2D?,
                            from: Date, to: Date, distance: CLLocationDistance,
                            passes: [PassedCamera], batteryDrop: Int?) -> TripRecord {
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
            endedManually: record.endedManually,
            batteryDropPercent: batteryDrop,
            startLat: start?.latitude, startLon: start?.longitude,
            // Половины рейса — рейсы (12б.9): без пометки разделённый рейс
            // выпадал из «Смен» и учился как своя поездка (ревью 14.1).
            work: record.work)
    }

    private static func polylineLength(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(0.0) { sum, i in
            sum + GeoMath.fastDistance(points[i - 1].lat, points[i - 1].lon,
                                       points[i].lat, points[i].lon)
        }
    }
}
