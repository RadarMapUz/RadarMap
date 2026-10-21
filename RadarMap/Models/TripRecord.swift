//
//  TripRecord.swift
//  RadarMap
//
//  Данные поездки: проезд камеры, запись завершённой поездки, точка трека.
//  Чистые Codable-структуры без логики — формат хранения trips.json.
//

import Foundation
import CoreLocation

/// Факт прохождения камеры: скорость зафиксирована в точке максимального сближения.
nonisolated struct PassedCamera: Codable, Identifiable {
    let id: UUID
    let cameraID: Int
    let typeRaw: String
    /// var — разовая чистка снимает с отметок водителей подпись «исчезнет
    /// ~14:05», бессмысленную после проезда (S30).
    var location: String
    let speedKmh: Double
    let date: Date
    // Координаты камеры и лимит дороги в момент проезда (у старых записей отсутствуют).
    var lat: Double?
    var lon: Double?
    /// Лимит, по которому судят ДЕНЬГИ и БАЛЛ: лимит дороги, поднятый до пола
    /// фиксации (см. EnforcedLimit). Именно он идёт во все суммы и рейтинги —
    /// поэтому пол применён один раз здесь, а не в сорока местах, где считают
    /// `speedKmh - limitKmh`.
    var limitKmh: Int?
    /// Лимит дороги как он есть — сырой матч OSM до пола. nil у записей старше
    /// этого поля и там, где знак и пол совпали. Нужен ровно для честности на
    /// экране проезда: «на дороге знак 50, считаем по 60».
    var roadLimitKmh: Int?
    /// Лимит не из OSM, а предположен по классу дороги (`RoadClass.assumedLimitKmh`).
    /// Опциональное поле: у записей, сделанных до появления фолбэка, его нет,
    /// и трактуем как «лимит настоящий» — раньше других и не было.
    var limitAssumed: Bool?
    /// Курс в точке траверса, градусы. nil — курсу верить было нельзя либо
    /// запись старше поля. Отличает проезд «туда» от «обратно»: на этом стоит
    /// догадка о направлении камеры (CameraAim).
    var courseDegrees: Double?
    /// Максимум скорости на отходе от камеры (60…200 м после траверса).
    /// Вместе со `speedKmh` (минимум на подходе) даёт провал скорости у камеры.
    var speedAfterKmh: Double?
    /// «Штраф не пришёл» — пометка владельца на экране возможных штрафов.
    /// Убирает проезд из ДЕНЕГ (fineRisk во всех сводках), но не из поведения:
    /// превышение было, рейтинг и зона риска его видят. nil у старых записей
    /// и у непомеченных — считается в сумму.
    var fineDismissed: Bool?
    /// «Штраф пришёл» — риск стал фактом: из «возможных» сумма уходит,
    /// в «пришло» (finesPaid) приходит. Взаимоисключимо с fineDismissed —
    /// следит TripHistory.settingFineOutcome.
    var finePaid: Bool?
    /// Пришедший штраф, сверенный с этим проездом (ReceivedFine.id, этап 17).
    /// Есть — «пришёл» поставил не кнопкой, а внесённым постановлением, и
    /// снять его можно только там же, на экране «Штрафы»: иначе штраф в
    /// списке и проезд разошлись бы. nil у старых записей и без постановления.
    var fineReceiptID: UUID?
    /// Сумма из постановления, сум. Пришедшие деньги — эта сумма, а не наша
    /// оценка по ступени: штраф пришёл, гадать больше не о чем. nil — сумму
    /// не внесли (тогда — оценка, как у кнопки «Пришёл»).
    var fineAmount: Double?
    /// Приложение промолчало об этой камере до проезда (true). nil — сказало,
    /// или запись старше 19.10, когда этого не записывали: тогда жалоба
    /// «не предупредила» остаётся в «Подробнее», а не наверху.
    var silent: Bool?

    var kind: CameraType { CameraType(raw: typeRaw) }
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    /// Реальное превышение относительно лимита дороги (если лимит известен).
    var overLimitKmh: Double? {
        guard let limitKmh else { return nil }
        return speedKmh - Double(limitKmh)
    }

    /// Можно ли называть по этому проезду КОНКРЕТНУЮ сумму штрафа.
    ///
    /// Нельзя, если лимит предположен: «возможный штраф 1 БРВ» — это заявление
    /// о деньгах, и оно требует уверенности, которой у догадки по классу дороги
    /// нет. Для рейтинга и голоса предположения достаточно (там цена ошибки —
    /// лишний совет), для суммы — нет.
    var limitIsCertain: Bool { limitKmh != nil && limitAssumed != true }

    /// Пол фиксации сработал: знак на дороге ниже того, по чему судим.
    /// Экран проезда обязан сказать об этом вслух — иначе поднятый лимит
    /// выглядит как «приложение перепутало знак».
    var limitWasFloored: Bool {
        guard let roadLimitKmh, let limitKmh else { return false }
        return roadLimitKmh < limitKmh
    }

    /// Провал скорости у камеры: насколько быстрее ехали ПОСЛЕ неё, чем в
    /// самой зоне измерения. nil — фиксов на отходе не было. Сырое наблюдение,
    /// выводы из него делает CameraAim.
    var brakeDepthKmh: Double? {
        guard let speedAfterKmh else { return nil }
        return speedAfterKmh - speedKmh
    }

    /// Судьба штрафа за проезд — что с ним стало по словам владельца.
    /// «Ожидается» — считаем в возможные; «пришёл» — риск стал фактом;
    /// «не пришёл» — камера не сработала, суммы нет нигде.
    enum FineOutcome: String {
        case pending, paid, dismissed
    }

    var fineOutcome: FineOutcome {
        if finePaid == true { return .paid }
        if fineDismissed == true { return .dismissed }
        return .pending
    }

    /// Идёт ли проезд в сумму ВОЗМОЖНЫХ штрафов (не отменён и не пришёл).
    var countsTowardFines: Bool { fineOutcome == .pending }

    /// Сколько денег «пришло» по проезду. Сумма постановления, если его
    /// внесли (этап 17) — она факт и не зависит от того, знали ли мы лимит;
    /// иначе — оценка по ступени, и только по достоверному лимиту, как
    /// везде, где говорим о деньгах. nil — не пришло или сказать нечего.
    /// Одно правило на запись, день и период: разные условия в folded и
    /// unfolded развалили бы хирургическую починку дня.
    var paidAmount: Double? {
        guard finePaid == true else { return nil }
        if let fineAmount { return fineAmount }
        guard limitIsCertain, let limitKmh else { return nil }
        let fine = FineSchedule.fine(overKmh: speedKmh - Double(limitKmh))
        return fine > 0 ? fine : nil
    }
}

/// Остановка внутри склеенной поездки: заехал в магазин, на заправку, за человеком.
/// Из «в пути» и средней скорости исключается — иначе сорок минут в «Корзинке»
/// обнуляют цифры всей поездки.
nonisolated struct TripStop: Codable, Identifiable {
    let id: UUID
    let lat: Double
    let lon: Double
    let from: Date
    let to: Date
    /// Название места: подтягивается ленивым геокодингом при открытии деталки.
    var title: String?

    var duration: TimeInterval { max(0, to.timeIntervalSince(from)) }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Одна завершённая поездка.
/// `nonisolated` — чистая арифметика над историей (`TripHistory`, `PeriodSummary`,
/// `DrivingScore`) считается вне main.
nonisolated struct TripRecord: Codable, Identifiable {
    let id: Double
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: CLLocationDistance
    let maxSpeedKmh: Double
    /// var — «штраф не пришёл» правит пометку прямо в записи (см. TripHistory
    /// .settingFineOutcome); значимость value-семантики это не ослабляет.
    var passed: [PassedCamera]
    // Точка финиша — чтобы повторить маршрут из истории (у старых записей отсутствует).
    var endLat: Double?
    var endLon: Double?
    /// Упрощённый трек: плоский массив [lat, lon, speed, lat, lon, speed, …].
    var track: [Double]?
    /// Рейтинг поездки 0–100 (у старых записей отсутствует).
    var score: Double?
    /// Остановки склеенной поездки (у одноногих и старых записей отсутствуют).
    var stops: [TripStop]?
    /// Поездку завершил пользователь кнопкой, а не автостоп. Хранится в записи,
    /// а не в памяти сервиса: приложение могло вылететь на стоянке, а намерение
    /// «я закончил» переигрывать нельзя (см. TripMerge).
    var endedManually: Bool?
    /// Сколько процентов заряда съела поездка (снимок на старте минус на
    /// финише). Приборка строилась ради батареи — экономия должна быть цифрой,
    /// а не верой. nil — заряд не читался (симулятор) или заряжались в пути:
    /// фиктивную дельту честнее не хранить вовсе. У старых записей отсутствует.
    var batteryDropPercent: Int? = nil
    /// Точка старта. Трек — единственный другой источник старта — вырезают
    /// через неделю, а дорога на работу («вышел из дома в 8:22») нужна и
    /// через месяц (Commute). У старых записей отсутствует.
    var startLat: Double? = nil
    var startLon: Double? = nil
    /// Записана в режиме «Работаю водителем» (12б.9): входит в смены, не
    /// входит в дорогу на работу и в выученные Дом/Работу. nil — личная;
    /// у старых записей отсутствует, и выключение режима их не трогает.
    var work: Bool? = nil

    var camerasPassed: Int { passed.count }
    /// Общее время от старта до финиша — включая стоянки: столько поездка заняла.
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    /// Сумма стоянок склеенной поездки.
    var stoppedDuration: TimeInterval {
        (stops ?? []).reduce(0) { $0 + $1.duration }
    }
    /// Время в движении — база для средней скорости.
    var movingDuration: TimeInterval { max(0, duration - stoppedDuration) }
    /// «Чистая» поездка: ни одного проезда со штрафуемым превышением
    /// (проезды без известного лимита не считаем нарушением — как в month30).
    var isClean: Bool {
        passed.allSatisfy { pass in
            guard let limit = pass.limitKmh else { return true }
            return FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) == 0
        }
    }
    /// Вердикт поездки одной строкой — карточка «Поездка сохранена» и
    /// карточка «поделиться». Деньги — только ждущие ответа по достоверному
    /// лимиту (`fineRisk`), но «все в лимите» — только если превышений не было
    /// вовсе и хоть один лимит известен. Предположенный лимит, «штраф пришёл» и
    /// «не пришёл» снимают сумму риска, но не поведение (как FineDismissTests):
    /// раньше риск 0 читался как «Все камеры в лимите», и такую карточку можно
    /// было отправить друзьям после превышения. Камеры без лимита — нехватка
    /// данных, а не заслуга водителя.
    enum Verdict: Equatable {
        case risk(Double)
        case overspeed(Int)
        case clean
        case unknownLimits
        case noCameras
    }

    var verdict: Verdict {
        let risk = TripHistory.fineRisk(of: passed)
        if risk > 0 { return .risk(risk) }
        var limited = 0
        var over = 0
        for pass in passed {
            guard let limit = pass.limitKmh else { continue }
            limited += 1
            if FineSchedule.fine(overKmh: pass.speedKmh - Double(limit)) > 0 { over += 1 }
        }
        if over > 0 { return .overspeed(over) }
        if limited > 0 { return .clean }
        return passed.isEmpty ? .noCameras : .unknownLimits
    }

    /// Средняя — по времени В ДВИЖЕНИИ: стоянка в поездке не «средняя скорость 12».
    var averageSpeedKmh: Double {
        movingDuration > 0 ? distanceMeters / movingDuration * 3.6 : 0
    }
    /// Откуда выехали: сохранённая точка старта, иначе первая точка трека.
    var startCoordinate: CLLocationCoordinate2D? {
        if let startLat, let startLon {
            return CLLocationCoordinate2D(latitude: startLat, longitude: startLon)
        }
        guard let first = trackPoints.first else { return nil }
        return CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)
    }

    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLat, let endLon else { return nil }
        return CLLocationCoordinate2D(latitude: endLat, longitude: endLon)
    }

    /// Есть ли что рисовать на карте. Проверка по плоскому массиву — без разбора
    /// трека в структуры: строки списка спрашивают это на каждый пересчёт.
    var hasTrack: Bool { (track?.count ?? 0) >= 6 }

    /// Точки трека (lat, lon, speed) из плоского хранения.
    var trackPoints: [TrackPoint] {
        guard let track, track.count >= 6 else { return [] }
        return stride(from: 0, to: track.count - 2, by: 3).map {
            TrackPoint(lat: track[$0], lon: track[$0 + 1], speedKmh: track[$0 + 2])
        }
    }
}

nonisolated struct TrackPoint {
    let lat: Double
    let lon: Double
    let speedKmh: Double
}
