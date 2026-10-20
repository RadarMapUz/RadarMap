//
//  MobilePassWatch.swift
//  RadarMap
//
//  «Радар ещё стоит?» — когда спрашивать водителя о передвижной отметке.
//
//  Отметки водителей живут на сервере по таймеру: поставили — через несколько
//  часов исчезнет. Это плохая замена знанию: патруль уезжает через двадцать
//  минут, а точка висит ещё три часа и пугает зря; или наоборот — стоит весь
//  день, а отметка истекла. Единственный, кто знает правду, — тот, кто ТОЛЬКО
//  ЧТО там проехал.
//
//  Поэтому спрашиваем ровно один раз и ровно тогда, когда ответ достоверен:
//  человек прошёл вплотную к точке и уже удалился от неё. Не «подъезжает»
//  (ещё не видел), не «в двухстах метрах сбоку» (мог не туда смотреть) —
//  а именно проехал мимо.
//
//  Молчание — не ответ: если водитель ничего не нажал, мы НЕ шлём ничего.
//  Голос «не знаю» испортил бы данные сильнее, чем их отсутствие.
//
//  Чистая логика, покрыта MobilePassWatchTests.
//

import CoreLocation
import Foundation

nonisolated enum MobilePassWatch {

    /// Насколько близко надо пройти, чтобы вопрос был честным. 90 м — ширина
    /// перекрёстка с развязкой: ближе точно видно, стоит ли кто-то.
    static let approachMeters: CLLocationDistance = 90

    /// На сколько надо отъехать, чтобы считать проезд состоявшимся. Больше
    /// подхода с запасом — иначе на дрожании GPS у самой точки вопрос
    /// выскакивал бы прямо в момент проезда, когда смотреть надо на дорогу.
    static let departedMeters: CLLocationDistance = 180

    /// Состояние наблюдения за одной точкой.
    struct Track: Equatable {
        var cameraID: Int
        /// Ближе всего, насколько подходили.
        var closestMeters: CLLocationDistance
        /// Уже спрашивали — второй раз не спросим за всю сессию.
        var asked = false
    }

    /// Обновить наблюдение и решить, пора ли спрашивать.
    ///
    /// Возвращает id точки, о которой уместен вопрос, или nil. Состояние
    /// передаётся и возвращается целиком: держать его должен вызывающий,
    /// а движок остаётся чистым.
    /// `excluded` — свои отметки водителя: отметивший сам видел, что там, а
    /// его «да» сервер всё равно не засчитает (тот же телефон — не
    /// независимое подтверждение). Вопрос был бы пустым тапом за рулём.
    static func update(tracks: inout [Int: Track],
                       mobileCameras: [Camera],
                       from coordinate: CLLocationCoordinate2D,
                       excluded: Set<Int> = []) -> Int? {
        var askAbout: Int?
        for camera in mobileCameras where !excluded.contains(camera.id) {
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                camera.lat, camera.lon)
            // Далеко и не наблюдали — не заводим запись: сотни точек по стране
            // не должны жить в памяти ради одной, мимо которой мы проедем.
            guard distance <= departedMeters * 2 || tracks[camera.id] != nil else { continue }

            var track = tracks[camera.id] ?? Track(cameraID: camera.id,
                                                   closestMeters: .greatestFiniteMagnitude)
            track.closestMeters = min(track.closestMeters, distance)
            if !track.asked, track.closestMeters <= approachMeters, distance >= departedMeters {
                track.asked = true
                // Один вопрос за тик: две плашки подряд за рулём — это шум.
                if askAbout == nil { askAbout = camera.id }
            }
            tracks[camera.id] = track
        }
        // Точки, которых больше нет в списке (истекли, удалены), забываем —
        // иначе словарь растёт всю поездку.
        let alive = Set(mobileCameras.map(\.id))
        tracks = tracks.filter { alive.contains($0.key) }
        return askAbout
    }
}
