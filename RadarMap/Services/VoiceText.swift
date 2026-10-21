//
//  VoiceText.swift
//  RadarMap
//
//  Текст события голоса — теми же строками каталога и тем же форматированием,
//  что у кода, который говорит (этап 16).
//
//  Зачем рендер, если у вызывающего уже есть текст. Это сверка: записанный
//  голос звучит, только если событие говорит РОВНО то, что написано
//  (`RecordedVoice.plan`). Кто-то поправит фразу о камере и забудет событие —
//  запись не скажет устаревшее, фраза уйдёт синтезатору, а в журнале будет
//  строка. И второе назначение — `index`: фразы, которые код говорит готовой
//  строкой («Принято, спасибо», «Тренога», «Здесь часто ставят треногу»),
//  находятся по тексту, без правки двадцати мест вызова.
//
//  Покрыт VoiceTextTests: рендер против настоящих построителей фраз.
//

import Foundation

enum VoiceText {

    static func render(_ event: VoiceEvent) -> String {
        switch event {
        case .camera(let call):
            return camera(call)
        case .cameraName(let kind):
            return kind.cameraType.displayName
        case .maneuver(let call):
            return maneuver(call)
        case .limitAhead(let limit, let meters):
            return String(format: String(localized: "Ограничение %1$lld через %2$@"),
                          limit, Formatting.distance(Double(meters)))
        case .jam(let meters, let delay):
            return String(format: String(localized: "Впереди пробка: около %1$@, плюс %2$@"),
                          Formatting.distance(Double(meters)), Formatting.duration(Double(delay)))
        case .detour(let saving):
            return String(format: String(localized: "Впереди пробка. Есть путь быстрее на %@"),
                          Formatting.duration(Double(saving)))
        case .hotspot(let peak):
            guard let peak else { return String(localized: "Здесь часто ставят треногу") }
            return String(format: String(localized: "Здесь часто ставят треногу, %@"), title(peak))
        case .phrase(let phrase):
            return text(phrase)
        }
    }

    /// Как `LocationService.announcement(for:…)`.
    static func camera(_ call: VoiceEvent.CameraCall) -> String {
        let type = call.kind.cameraType
        var phrase: String
        switch call.form {
        case .group:
            phrase = String(format: String(localized: "Камеры впереди, %lld метров"), call.meters)
        case .brief:
            phrase = String(format: String(localized: "%@, %lld метров"), type.shortName, call.meters)
        case .onRoute:
            phrase = String(format: String(localized: "По маршруту %@ через %lld метров"),
                            type.displayName.lowercased(), call.meters)
        case .full(let side):
            phrase = String(format: String(localized: "%@ %@, %lld метров"),
                            type.displayName, text(side), call.meters)
        }
        if call.fromDrivers, call.form != .group {
            phrase = String(format: String(localized: "Отметка водителей: %@"),
                            phrase.prefix(1).lowercased() + phrase.dropFirst())
        }
        switch call.tail {
        case .none:
            break
        case .speedAndLimit(let speed, let limit):
            phrase += String(format: String(localized: ". Ваша скорость %lld, лимит %lld"), speed, limit)
        case .speed(let speed):
            phrase += String(format: String(localized: ". Ваша скорость %lld"), speed)
        case .limit(let limit):
            phrase += String(format: String(localized: ", здесь %lld"), limit)
        }
        return phrase
    }

    /// Как `LocationService.directionPhrase`.
    static func text(_ side: VoiceEvent.Side) -> String {
        switch side {
        case .aheadRight: return String(localized: "впереди справа")
        case .aheadLeft:  return String(localized: "впереди слева")
        case .ahead:      return String(localized: "впереди")
        }
    }

    /// Как `RouteService.updateManeuvers` + `maneuverStep` (без улицы).
    static func maneuver(_ call: VoiceEvent.ManeuverCall) -> String {
        let command = text(call.action)
        guard let meters = call.meters else { return command }
        let line = String(format: String(localized: "Через %lld метров — %@"), meters, command)
        let advice: LaneAdvice.Advice? = call.lanes.map { .lanes($0) } ?? call.edge.map { .edge($0) }
        return RouteService.withAdvice(line, advice)
    }

    static func text(_ action: VoiceEvent.Action) -> String {
        switch action {
        case .turnLeft:    return String(localized: "поверните налево")
        case .turnRight:   return String(localized: "поверните направо")
        case .slightLeft:  return String(localized: "плавно левее")
        case .slightRight: return String(localized: "плавно правее")
        case .sharpLeft:   return String(localized: "круто налево")
        case .sharpRight:  return String(localized: "круто направо")
        case .uturn:       return String(localized: "разворот")
        case .keepLeft:    return String(localized: "держитесь левее")
        case .keepRight:   return String(localized: "держитесь правее")
        case .merge:       return String(localized: "перестройтесь в поток")
        case .onRamp:      return String(localized: "съезд на развязку")
        case .offRamp:     return String(localized: "сверните на съезд")
        case .arrived:     return String(localized: "вы прибыли")
        case .roundabout(let exit):
            return String(format: String(localized: "на кольце %lld-й съезд"), exit)
        }
    }

    /// Как `TripodHotspots.Spot.peakTitle`.
    static func title(_ peak: VoiceEvent.Peak) -> String {
        switch peak {
        case .night:   return String(localized: "обычно ночью")
        case .morning: return String(localized: "обычно утром")
        case .day:     return String(localized: "обычно днём")
        case .evening: return String(localized: "обычно вечером")
        }
    }

    static func text(_ phrase: VoiceEvent.Phrase) -> String {
        switch phrase {
        case .overspeed:              return String(localized: "Превышение скорости")
        case .rerouted:               return String(localized: "Маршрут перестроен")
        case .arrived:                return String(localized: "Вы прибыли")
        case .roadClosure:            return String(localized: "Впереди перекрытие дороги")
        case .roadClosureFromDrivers: return String(localized: "Отметка водителей: впереди перекрытие")
        case .roadwork:               return String(localized: "Впереди ремонт дороги")
        case .reportAccepted:         return String(localized: "Принято, спасибо")
        case .reportConfirmed:        return String(localized: "Подтвердили, спасибо")
        case .reportAmended:          return String(localized: "Тип уточнён")
        case .reportDuplicate:        return String(localized: "Уже отметили здесь")
        case .reportNoPosition:       return String(localized: "Ждём спутники")
        case .reportNotDriving:       return String(localized: "Отметка ставится в движении")
        case .reportQueuedOffline:    return String(localized: "Нет связи, отправлю позже")
        case .reportQueuedServer:     return String(localized: "Сервер не отвечает, отправлю позже")
        case .offline:                return String(localized: "Нет связи")
        case .tooOften:               return String(localized: "Слишком часто, подождите минуту")
        case .reportRefused:          return String(localized: "Сервер отклонил отметку")
        case .serverDown:             return String(localized: "Сервер не отвечает")
        case .reportsDisabled:        return String(localized: "Отметки сейчас выключены")
        case .badAnswer:              return String(localized: "Странный ответ сервера")
        case .thanks:                 return String(localized: "Спасибо!")
        case .reportRemoved:          return String(localized: "Отметка убрана")
        case .notSent:                return String(localized: "Не отправилось, нет связи")
        case .closure:                return String(localized: "Перекрыто")
        case .roadworkShort:          return String(localized: "Ремонт")
        case .routeNoPosition:        return String(localized: "Не вижу точного положения — маршрут пока не построить")
        case .routeFailed:            return String(localized: "Маршрут не построился")
        case .tripStarted:            return String(localized: "Поездка началась — слежу за камерами")
        case .tripEnded:              return String(localized: "Поездка завершена")
        case .routeFinished:          return String(localized: "Маршрут завершён")
        case .sample:                 return String(localized: "Камера, триста метров")
        }
    }

    /// События, у которых конечный набор текстов, — по тексту. Так фразы,
    /// которые код передаёт готовой строкой, звучат записью без правки мест
    /// вызова. Строится один раз на процесс: язык меняется только перезапуском.
    static func index() -> [String: VoiceEvent] {
        var events: [VoiceEvent] = VoiceEvent.Phrase.allCases.map { .phrase($0) }
        events += VoiceEvent.Kind.allCases.map { .cameraName($0) }
        events.append(.hotspot(nil))
        events += VoiceEvent.Peak.allCases.map { .hotspot($0) }
        let actions = VoiceEvent.Action.simple
            + (1...VoiceScript.maxRoundaboutExit).map { VoiceEvent.Action.roundabout(exit: $0) }
        events += actions.map { .maneuver(.init(action: $0, meters: nil, lanes: nil)) }
        return Dictionary(events.map { (render($0), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
