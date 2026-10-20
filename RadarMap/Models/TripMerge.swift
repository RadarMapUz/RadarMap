//
//  TripMerge.swift
//  RadarMap
//
//  «Это та же поездка или новая?» — решение о склейке после остановки.
//
//  Автостарт по CoreMotion гаснет на любой устойчивой остановке, поэтому заезд
//  в магазин по дороге домой распадался на три поездки: до магазина, ноль метров
//  по парковке, от магазина. История превращалась в мусор, а средняя скорость и
//  рейтинг считались по обрубкам.
//
//  Решает не один таймер, а признаки. Главные два: РУЧНОЕ завершение поездки —
//  это выраженное намерение, его не переигрываем никогда; и ГДЕ стояли — час у
//  случайного места по пути (обед, банк, встреча) поездку продолжает, а те же
//  двадцать минут у дома означают «приехал, дело сделано».
//
//  Чистая логика без Date.now и без хранилища — покрыта тестами (TripMergeTests).
//

import Foundation
import CoreLocation

nonisolated enum TripMerge {

    /// Всё, что нужно знать о паузе между двумя поездками.
    struct Context {
        /// Сколько простояли между финишем прошлой и стартом новой.
        let stopDuration: TimeInterval
        /// Насколько новый старт далеко от точки финиша прошлой поездки.
        let metersFromPreviousEnd: CLLocationDistance
        /// Прошлую поездку завершил пользователь кнопкой (а не автостоп).
        let endedManually: Bool
        /// Стояли у сохранённого места (Дом/Работа) — это пункт назначения.
        let stopNearSavedPlace: Bool
        /// Пауза перешла через полночь — календарно это уже другая поездка.
        let crossesDay: Bool
        /// Сколько остановок уже склеено в прошлой поездке.
        let existingStops: Int
        /// Длительность прошлой поездки (со всеми её стоянками).
        let previousDuration: TimeInterval
        /// Сколько уже ехали до старта поездки (автостарт поймал езду поздно,
        /// CoreMotion знает её начало): за это время машина честно уехала от
        /// точки финиша дальше 400 м (S19, 20.10). 0 — не знаем.
        var lateStartSeconds: TimeInterval = 0
    }

    /// Продолжать прошлую поездку вместо новой записи?
    static func shouldMerge(_ context: Context) -> Bool {
        // Нажал «Завершить» — значит поездка закончена, что бы ни говорила геометрия.
        if context.endedManually { return false }
        // Стартовали в другом месте: телефон приехал сюда не за рулём этой машины
        // (пассажиром, пешком, на такси) — склеивать нечего.
        // Поздний автостарт: дальше — ровно настолько, насколько машина
        // успела уехать с начала езды (с потолком).
        let reach = AppConfig.tripMergeMaxMeters
            + min(max(0, context.lateStartSeconds) * AppConfig.tripMergeLateStartSpeedMps,
                  AppConfig.tripMergeLateStartMaxMeters)
        if context.metersFromPreviousEnd > reach { return false }
        if context.crossesDay { return false }
        // Страховка от «одна поездка на весь день»: и по числу заездов, и по времени.
        if context.existingStops >= AppConfig.tripMergeMaxStops { return false }
        if context.previousDuration + context.stopDuration
            > AppConfig.tripMergeMaxTotalSeconds { return false }
        // Короткая пауза — почти всегда заезд: магазин, заправка, забрал человека.
        if context.stopDuration <= AppConfig.tripMergeShortStopSeconds { return true }
        if context.stopDuration > AppConfig.tripMergeMaxStopSeconds { return false }
        // Серая зона (15–60 мин): решает место. Случайная точка по пути — дело в
        // пути, поездка продолжается. Дом или работа — приехали.
        return !context.stopNearSavedPlace
    }

    /// Стояли ли у одного из сохранённых мест.
    static func isNearSavedPlace(_ coordinate: CLLocationCoordinate2D,
                                 places: [CLLocationCoordinate2D]) -> Bool {
        places.contains { place in
            GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                 place.latitude, place.longitude)
                <= AppConfig.tripMergeSavedPlaceMeters
        }
    }

    // MARK: - Ручное объединение записей (после факта)
    //
    // Автосклейка никогда не переигрывает ручное «Завершить» — и это правильно.
    // Но водитель жмёт стоп у магазина по привычке, а через двадцать минут едет
    // дальше: история получает две записи там, где была одна поездка. Ручное
    // объединение — симметрия к TripHistory.split: то чинит лишнюю склейку,
    // это — лишний разрез.

    /// Можно ли объединить `next` с предыдущей по времени `previous`.
    /// Ворота те же, что у автосклейки, кроме намерения: само объединение —
    /// уже намерение, и «Завершить» его не блокирует.
    /// `maxMeters` — от финиша до старта: ручное объединение — уже намерение,
    /// и поздний автостарт (старт в 800 м от магазина) его не блокирует (S19);
    /// предложение в Итогах держит строгий предел автосклейки.
    static func manualMergeAllowed(previous: TripRecord, next: TripRecord,
                                   calendar: Calendar = .current,
                                   maxMeters: CLLocationDistance = AppConfig.tripMergeMaxMeters) -> Bool {
        guard next.startedAt >= previous.endedAt else { return false }
        guard calendar.isDate(previous.endedAt, inSameDayAs: next.startedAt) else { return false }
        guard next.startedAt.timeIntervalSince(previous.endedAt)
            <= AppConfig.tripMergeMaxStopSeconds else { return false }
        // Стартовали далеко от финиша — точно разные поездки. Координаты старта
        // у записи нет — берём первую точку трека; без треков (старые записи)
        // решают только день и пауза.
        if let end = previous.endCoordinate, let start = next.trackPoints.first {
            guard GeoMath.fastDistance(end.latitude, end.longitude, start.lat, start.lon)
                <= maxMeters else { return false }
        }
        // Те же страховки «одна поездка на весь день», что у автосклейки.
        guard (previous.stops?.count ?? 0) + (next.stops?.count ?? 0)
            < AppConfig.tripMergeMaxStops else { return false }
        return next.endedAt.timeIntervalSince(previous.startedAt)
            <= AppConfig.tripMergeMaxTotalSeconds
    }

    /// Предлагать ли объединение в Итогах само: пара склеилась бы автоматикой,
    /// если бы не ручное «Завершить» у предыдущей. Остальные причины отказа —
    /// не наши: там автоматика сказала «нет» по делу (другое место, полночь).
    static func suggestsMerge(previous: TripRecord, next: TripRecord,
                              savedPlaces: [CLLocationCoordinate2D],
                              calendar: Calendar = .current) -> Bool {
        guard previous.endedManually == true else { return false }
        guard manualMergeAllowed(previous: previous, next: next,
                                 calendar: calendar) else { return false }
        // Серая зона автосклейки действует и тут: долгая стоянка у Дома/Работы —
        // «приехал, дело сделано», ручной стоп это только подтверждает.
        if let end = previous.endCoordinate,
           next.startedAt.timeIntervalSince(previous.endedAt)
               > AppConfig.tripMergeShortStopSeconds,
           isNearSavedPlace(end, places: savedPlaces) { return false }
        return true
    }

    /// Объединить две записи в одну поездку: пауза становится остановкой в
    /// пути, треки сшиваются, балл пересчитывается по объединённым данным.
    /// Ворота проверяет вызывающий (manualMergeAllowed).
    static func merged(previous: TripRecord, next: TripRecord) -> TripRecord {
        let gapStop = TripStop(
            id: UUID(),
            lat: previous.endLat ?? previous.trackPoints.last?.lat ?? 0,
            lon: previous.endLon ?? previous.trackPoints.last?.lon ?? 0,
            from: previous.endedAt, to: next.startedAt)
        // Трек — простая сшивка: обе ноги уже упрощены при своих финишах,
        // а живут треки всё равно неделю (чистка истории).
        let track = previous.trackPoints + next.trackPoints
        let passes = previous.passed + next.passed
        return TripRecord(
            id: previous.id,
            startedAt: previous.startedAt,
            endedAt: next.endedAt,
            distanceMeters: previous.distanceMeters + next.distanceMeters,
            maxSpeedKmh: max(previous.maxSpeedKmh, next.maxSpeedKmh),
            passed: passes,
            endLat: next.endLat ?? next.trackPoints.last?.lat,
            endLon: next.endLon ?? next.trackPoints.last?.lon,
            track: track.count >= 2 ? track.flatMap { [$0.lat, $0.lon, $0.speedKmh] } : nil,
            // Балл — той же арифметикой, что у живого финиша: склейка не должна
            // отличаться от поездки, которую не разрезали.
            score: DrivingScore.tripScore(
                passes: passes.map {
                    DrivingScore.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh)
                },
                trackSpeeds: track.map(\.speedKmh)),
            stops: (previous.stops ?? []) + [gapStop] + (next.stops ?? []),
            endedManually: next.endedManually,
            batteryDropPercent: mergedBatteryDrop(previous.batteryDropPercent,
                                                  next.batteryDropPercent),
            // Рейс в склейке — склейка рейс (12б.9): иначе она выпадала из
            // «Смен» и шла в выученные Дом/Работу с адресом пассажира на конце
            // (ревью 14.1). Смешанная — тоже рейс: адрес пассажира учить нельзя.
            work: previous.work == true || next.work == true ? true : nil)
    }

    /// Сумма дельт заряда — только когда известны обе ноги: «−2 %» за поездку,
    /// стоившую пять, хуже, чем промолчать (та же логика, что resumedStartPercent).
    private static func mergedBatteryDrop(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a + b
    }
}
