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
    }

    /// Продолжать прошлую поездку вместо новой записи?
    static func shouldMerge(_ context: Context) -> Bool {
        // Нажал «Завершить» — значит поездка закончена, что бы ни говорила геометрия.
        if context.endedManually { return false }
        // Стартовали в другом месте: телефон приехал сюда не за рулём этой машины
        // (пассажиром, пешком, на такси) — склеивать нечего.
        if context.metersFromPreviousEnd > AppConfig.tripMergeMaxMeters { return false }
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
}
