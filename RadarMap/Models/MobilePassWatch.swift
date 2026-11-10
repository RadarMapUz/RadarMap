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
//  Вопрос — по типу отметки (12.7): «Тренога ещё стоит?», «Пост ещё
//  стоит?» с кнопками «Стоит» / «Уже нет» (у поста «Убрали») — то же одно касание и тот же
//  голос серверу (`kind=pass`), только вопрос о том, что водитель видел.
//  Обоим направлениям — треноги снимают и встречных (владелец, 02.11);
//  поперечной улице — нет.
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

    /// Текст вопроса и ответов — по типу отметки. `yes` — «на месте»
    /// (лайк, продлевает), `no` — «уже нет» (дизлайк, срезает срок).
    struct Question: Equatable {
        let title: String
        let yes: String
        let no: String
        /// Ответ целиком — для VoiceOver: «Нет» само по себе не говорит, о чём.
        let spokenYes: String
        let spokenNo: String
    }

    /// Вопрос и ответы — одни на телефоне и в машине (словарь маркетолога,
    /// 02.11): «Тренога ещё стоит?» — «Стоит» / «Убрали». Настоящее время,
    /// а не «стоял»: сервер понимает ответ как «стоит сейчас», и тренога —
    /// это «сейчас». Кнопки понятны и без вопроса: не дочитал — ответ всё
    /// равно верный.
    static func question(for kind: CameraType) -> Question {
        switch kind {
        case .dpsPost:
            return Question(title: String(localized: "Пост ещё стоит?"),
                            yes: String(localized: "Стоит"),
                            no: String(localized: "Убрали"),
                            spokenYes: String(localized: "Да, пост ещё стоит"),
                            spokenNo: String(localized: "Пост убрали"))
        case .accident:
            return Question(title: String(localized: "ДТП ещё на дороге?"),
                            yes: String(localized: "Да"),
                            no: String(localized: "Убрали"),
                            spokenYes: String(localized: "Да, ДТП ещё на дороге"),
                            spokenNo: String(localized: "ДТП уже убрали"))
        case .tripod:
            return Question(title: String(localized: "Тренога ещё стоит?"),
                            yes: String(localized: "Стоит"),
                            no: String(localized: "Уже нет"),
                            spokenYes: String(localized: "Да, тренога ещё стоит"),
                            spokenNo: String(localized: "Нет, треноги уже нет"))
        default:
            return Question(title: String(localized: "Радар ещё стоит?"),
                            yes: String(localized: "Стоит"),
                            no: String(localized: "Уже нет"),
                            spokenYes: String(localized: "Да, радар ещё стоит"),
                            spokenNo: String(localized: "Нет, радара уже нет"))
        }
    }

    /// Короткий вариант вопроса для узкого баннера машины.
    static var shortQuestion: String { String(localized: "Ещё стоит?") }

    /// Состояние наблюдения за одной точкой.
    struct Track: Equatable {
        var cameraID: Int
        /// Ближе всего, насколько подходили.
        var closestMeters: CLLocationDistance
        /// Уже спрашивали — второй раз не спросим за всю сессию.
        var asked = false
        /// Когда проезд состоялся (подошли и отъехали). Ответ уходит с этим
        /// возрастом: вопрос мог ждать занятого слота, голос — связи, а
        /// тренога — это «сейчас», и старое «стоит» сервер не продлевает.
        var departedAt: Date? = nil
    }

    /// Обновить наблюдение и решить, пора ли спрашивать.
    ///
    /// Возвращает id точки, о которой уместен вопрос, или nil. Состояние
    /// передаётся и возвращается целиком: держать его должен вызывающий,
    /// а движок остаётся чистым.
    /// `excluded` — свои отметки водителя: отметивший сам видел, что там, а
    /// его «да» сервер всё равно не засчитает (тот же телефон — не
    /// независимое подтверждение). Вопрос был бы пустым тапом за рулём.
    /// `canAsk` — слот вопроса свободен. Занят — проезд копится, но точку
    /// «спрошенной» не помечаем: раньше её id выбрасывался, пока висел
    /// прежний вопрос (до пяти минут с погашенным экраном), и о второй
    /// отметке не спрашивали уже никогда.
    ///
    /// Спрашиваем ОБА направления (владелец, 02.11: «некоторые треноги
    /// снимают обе стороны»): встречный видел треногу так же, и его «Стоит» —
    /// полноценное подтверждение. Вес «Убрали» от встречного решает сервер —
    /// по курсу, который уходит с голосом (через разделительную он мог её не
    /// видеть). Не засчитывается подход только с поперечной улицы, когда оба
    /// курса известны (`crosses`): на развязке водитель сверху треногу внизу
    /// не видел. Курс неизвестен — как раньше, спрашиваем.
    static func update(tracks: inout [Int: Track],
                       mobileCameras: [Camera],
                       from coordinate: CLLocationCoordinate2D,
                       course: CLLocationDegrees,
                       courses: [Int: Double],
                       excluded: Set<Int> = [],
                       canAsk: Bool = true,
                       now: Date = Date()) -> Int? {
        var askAbout: Int?
        for camera in mobileCameras where !excluded.contains(camera.id) {
            let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                camera.lat, camera.lon)
            // Далеко и не наблюдали — не заводим запись: сотни точек по стране
            // не должны жить в памяти ради одной, мимо которой мы проедем.
            guard distance <= departedMeters * 2 || tracks[camera.id] != nil else { continue }

            var track = tracks[camera.id] ?? Track(cameraID: camera.id,
                                                   closestMeters: .greatestFiniteMagnitude)
            if !crosses(course: course, reportCourse: courses[camera.id] ?? -1) {
                track.closestMeters = min(track.closestMeters, distance)
            }
            if track.departedAt == nil, track.closestMeters <= approachMeters, distance >= departedMeters {
                track.departedAt = now
            }
            if canAsk, !track.asked, track.closestMeters <= approachMeters, distance >= departedMeters {
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

    /// Проезжаем поперёк хода отметившего (поперечная улица, развязка).
    /// Попутный и встречный — не поперёк; неизвестный курс — тоже не повод
    /// молчать.
    static func crosses(course: CLLocationDegrees, reportCourse: Double) -> Bool {
        guard course >= 0, reportCourse >= 0 else { return false }
        return GeoMath.axisDifference(course: course, axis: reportCourse.truncatingRemainder(dividingBy: 180))
            > AppConfig.mobilePassSameAxisDegrees
    }

    /// Встречный ли проезд — для голоса серверу (вес «Убрали» решает он).
    static func oncoming(course: CLLocationDegrees, reportCourse: Double) -> Bool {
        guard course >= 0, reportCourse >= 0 else { return false }
        return GeoMath.angleDifference(course, reportCourse) > 90
    }
}
