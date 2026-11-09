//
//  RoadEventPassWatch.swift
//  RadarMap
//
//  «Ещё перекрыто?» / «Ремонт ещё идёт?» — когда спрашивать водителя о
//  событии дороги (12б.5, вторая половина петли).
//
//  До этого закончившийся ремонт или открытую дорогу снимали только срок и
//  модератор: ремонт на испытании живёт сутки, подтверждённый — неделю, и всю
//  эту неделю маршрут честно объезжал асфальт, на котором уже никого нет.
//  Знает правду тот, кто ТОЛЬКО ЧТО там был, — как и с треногой
//  (MobilePassWatch), и спрашиваем так же: один раз и только тогда, когда
//  ответ достоверен.
//
//  Отличия от вопроса о радаре — от самой дороги:
//    * ближе — 60 м, а не 90: ремонт занимает полосу, и видно его только с
//      неё самой, а не через перекрёсток;
//    * в ту же сторону: отмеченное перекрытие одной половины проспекта со
//      встречки не разглядеть, и «нет» оттуда сняло бы настоящее. Сторона —
//      курс отметившего, как у маршрута и голоса (RoadEventRules); курс
//      отметки неизвестен — перекрыто, считаем, всё, и подходит любой;
//    * наш курс обязан быть известен: стоя у окна дома в пятидесяти метрах
//      от ремонта, водитель на дорогу не смотрел;
//    * свои отметки не спрашиваем: отметивший только что видел своими
//      глазами и отъехал — вопрос «ещё перекрыто?» через минуту был бы шумом.
//
//  Проезжать насквозь не обязательно: перед перекрытием разворачиваются, и
//  подошедший вплотную по ходу, а потом отъехавший — ровно тот, кто видел.
//
//  Молчание — не ответ: не нажал ничего — не шлём ничего. Камер это не
//  касается никак: вопрос живёт в своём слоте, оповещения не трогает
//  (ARCHITECTURE.md, правило 20).
//
//  Чистая логика, покрыта RoadEventPassWatchTests.
//

import CoreLocation
import Foundation

nonisolated enum RoadEventPassWatch {

    /// Насколько близко надо пройти по ходу события: полоса ремонта видна
    /// с неё самой и с соседней, а не с параллельной улицы.
    static let approachMeters: CLLocationDistance = 60

    /// На сколько отъехать, чтобы проезд состоялся. С запасом над подходом —
    /// иначе дрожание GPS у самой точки задавало бы вопрос в момент проезда,
    /// когда смотреть надо на дорогу.
    static let departedMeters: CLLocationDistance = 150

    /// Наблюдение за одним событием.
    struct Track: Equatable {
        var eventID: Int
        /// Ближе всего, насколько подходили ПО ХОДУ события.
        var closestMeters: CLLocationDistance
        /// Уже спрашивали — второй раз не спросим за всю сессию.
        var asked = false
    }

    /// Обновить наблюдение и решить, пора ли спрашивать.
    ///
    /// - Parameters:
    ///   - course: наш курс, 0…360; < 0 — неизвестен (такой фикс подходом
    ///     не считается).
    ///   - excluded: id своих отметок — о них не спрашиваем.
    /// - Returns: id события, о котором уместен вопрос, или nil.
    static func update(tracks: inout [Int: Track],
                       events: [RoadEvent],
                       from coordinate: CLLocationCoordinate2D,
                       course: CLLocationDegrees,
                       excluded: Set<Int>,
                       now: Date) -> Int? {
        var askAbout: Int?
        for event in events where event.expires > now && !excluded.contains(event.id) {
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                event.lat, event.lon)
            // Далеко и не наблюдали — записи не заводим: ремонты по всей
            // стране не должны жить в памяти ради одного на нашем пути.
            guard distance <= departedMeters * 2 || tracks[event.id] != nil else { continue }

            var track = tracks[event.id] ?? Track(eventID: event.id,
                                                  closestMeters: .greatestFiniteMagnitude)
            if sameDirection(course: course, event: event) {
                track.closestMeters = min(track.closestMeters, distance)
            }
            if !track.asked, track.closestMeters <= approachMeters, distance >= departedMeters {
                track.asked = true
                // Один вопрос за тик: две плашки подряд за рулём — это шум.
                if askAbout == nil { askAbout = event.id }
            }
            tracks[event.id] = track
        }
        // Пропавшие из списка (истекли, сняты) забываем — иначе словарь
        // растёт всю поездку.
        let alive = Set(events.lazy.filter { $0.expires > now }.map(\.id))
        tracks = tracks.filter { alive.contains($0.key) }
        return askAbout
    }

    /// Едем ли мы так, чтобы видеть событие: курс известен и, если сторона
    /// события известна, — в ту же сторону.
    static func sameDirection(course: CLLocationDegrees, event: RoadEvent) -> Bool {
        guard course >= 0 else { return false }
        guard event.course >= 0 else { return true }
        return GeoMath.angleDifference(course, event.course) <= AppConfig.roadEventSameSideDegrees
    }

    /// Вопрос водителю — короткий, на «да/нет».
    static func question(for kind: RoadEvent.Kind) -> String {
        switch kind {
        case .closure:  return String(localized: "Дорога ещё перекрыта?")
        case .roadwork: return String(localized: "Ремонт ещё идёт?")
        }
    }
}
