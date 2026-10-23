//
//  VoiceComposer.swift
//  RadarMap
//
//  Событие голоса → список записанных отрывков (этап 16.1).
//
//  Порядок слов у языков разный («через 300 метров» против «300 metrdan
//  soʻng»), поэтому сборка своя у каждого языка, а имена отрывков общие там,
//  где совпадает смысл: `dist.300.after` по-русски «через триста метров»,
//  по-узбекски «uch yuz metrdan soʻng» — предлог и послелог живут ВНУТРИ
//  записи, а не приклеиваются. Падежные окончания не склеиваются из кусков
//  никогда: «metr» + «dan» на стыке звучит как два человека, поэтому
//  суффиксная форма — отдельный отрывок.
//
//  nil означает «целиком собрать нельзя» (расстояние вне записанных ступеней,
//  скорость за 299, секунды без минут) — тогда фраза идёт синтезатором вся.
//  Половины фразы записью не бывает.
//
//  Самодостаточен (Foundation), как и VoiceEvent: его собирает экспорт
//  сценария для диктора. Покрыт VoiceComposerTests.
//

import Foundation

nonisolated enum VoiceComposer {

    static func segments(for event: VoiceEvent, in language: VoiceLanguage) -> [SegmentID]? {
        switch language {
        case .uz: return Uzbek.compose(event)
        case .ru: return Russian.compose(event)
        }
    }

    // MARK: - Общие имена отрывков

    static func kind(_ kind: VoiceEvent.Kind) -> SegmentID {
        switch kind {
        case .stationaryCamera: return "kind.stationary_camera"
        case .stationaryRadar:  return "kind.stationary_radar"
        case .intelligentRadar: return "kind.intelligent_radar"
        case .mobileRadar:      return "kind.mobile_radar"
        case .tripod:           return "kind.tripod"
        case .dpsPost:          return "kind.dps_post"
        case .accident:         return "kind.accident"
        }
    }

    /// Короткое городское название: «Камера» / «Радар», у внезапных точек —
    /// полное (как `CameraType.shortName`).
    static func shortKind(_ kind: VoiceEvent.Kind) -> SegmentID {
        switch kind {
        case .stationaryCamera, .intelligentRadar: return "kind.camera"
        case .stationaryRadar:                     return "kind.radar"
        default:                                   return Self.kind(kind)
        }
    }

    static func side(_ side: VoiceEvent.Side) -> SegmentID {
        switch side {
        case .ahead:      return "side.ahead"
        case .aheadLeft:  return "side.ahead_left"
        case .aheadRight: return "side.ahead_right"
        }
    }

    /// Команда манёвра; у кольца — два отрывка («на кольце» + «второй съезд»).
    static func action(_ action: VoiceEvent.Action) -> [SegmentID]? {
        switch action {
        case .turnLeft:    return ["man.turn_left"]
        case .turnRight:   return ["man.turn_right"]
        case .slightLeft:  return ["man.slight_left"]
        case .slightRight: return ["man.slight_right"]
        case .sharpLeft:   return ["man.sharp_left"]
        case .sharpRight:  return ["man.sharp_right"]
        case .uturn:       return ["man.uturn"]
        case .keepLeft:    return ["man.keep_left"]
        case .keepRight:   return ["man.keep_right"]
        case .merge:       return ["man.merge"]
        case .onRamp:      return ["man.on_ramp"]
        case .offRamp:     return ["man.off_ramp"]
        case .arrived:     return ["man.arrived"]
        case .roundabout(let exit):
            guard (1...VoiceScript.maxRoundaboutExit).contains(exit) else { return nil }
            return ["man.roundabout", SegmentID("man.exit.\(exit)")]
        }
    }

    static func lane(_ run: VoiceEvent.LaneRun) -> SegmentID {
        switch run {
        case .leftOne:     return "lane.left_one"
        case .leftTwo:     return "lane.left_two"
        case .leftThree:   return "lane.left_three"
        case .leftMany:    return "lane.left_many"
        case .rightOne:    return "lane.right_one"
        case .rightTwo:    return "lane.right_two"
        case .rightThree:  return "lane.right_three"
        case .rightMany:   return "lane.right_many"
        case .allButRight: return "lane.all_but_right"
        case .allButLeft:  return "lane.all_but_left"
        case .middleOne:   return "lane.middle_one"
        case .middleMany:  return "lane.middle_many"
        }
    }

    /// Край без данных о полосах. «Держитесь левее» — та же запись, что у
    /// команды развилки: слова одни, второй отрывок диктору не нужен.
    static func edge(_ edge: VoiceEvent.LaneEdge) -> SegmentID {
        switch edge {
        case .left:      return "lane.edge_left"
        case .farLeft:   return "lane.edge_far_left"
        case .right:     return "lane.edge_right"
        case .keepLeft:  return "man.keep_left"
        case .keepRight: return "man.keep_right"
        }
    }

    static func peak(_ peak: VoiceEvent.Peak) -> SegmentID {
        SegmentID("peak.\(peak.rawValue)")
    }

    /// Фраза без подстановок. Составные («Нет связи, отправлю позже»)
    /// собираются из целых записей; `closureMark` — то, что язык говорит
    /// после «Отметка водителей:» о перекрытии (у русского своя краткая форма).
    static func phrase(_ phrase: VoiceEvent.Phrase, closureMark: SegmentID) -> [SegmentID]? {
        switch phrase {
        case .overspeed:              return ["p.overspeed"]
        case .rerouted:               return ["p.rerouted"]
        case .arrived:                return ["p.arrived"]
        case .roadClosure:            return ["p.road_closure"]
        case .roadClosureFromDrivers: return ["w.drivers_mark", .comma, closureMark]
        case .roadwork:               return ["p.roadwork"]
        case .reportAccepted:         return ["p.report_accepted"]
        case .reportConfirmed:        return ["p.report_confirmed"]
        case .reportAmended:          return ["p.report_amended"]
        case .reportDuplicate:        return ["p.report_duplicate"]
        case .reportNoPosition:       return ["p.report_no_position"]
        case .reportNotDriving:       return ["p.report_not_driving"]
        case .reportQueuedOffline:    return ["p.offline", .comma, "w.send_later"]
        case .reportQueuedServer:     return ["p.server_down", .comma, "w.send_later"]
        case .offline:                return ["p.offline"]
        case .tooOften:               return ["p.too_often"]
        case .reportRefused:          return ["p.report_refused"]
        case .serverDown:             return ["p.server_down"]
        case .reportsDisabled:        return ["p.reports_disabled"]
        case .badAnswer:              return ["p.bad_answer"]
        case .thanks:                 return ["p.thanks"]
        case .reportRemoved:          return ["p.report_removed"]
        case .notSent:                return ["w.not_sent", .comma, "p.offline"]
        case .closure:                return ["p.closure"]
        case .roadworkShort:          return ["p.roadwork_short"]
        case .routeNoPosition:        return ["p.route_no_position"]
        case .routeFailed:            return ["p.route_failed"]
        case .tripStarted:            return ["p.trip_started"]
        case .tripEnded:              return ["p.trip_ended"]
        case .routeFinished:          return ["p.route_finished"]
        case .sample:
            guard let distance = VoiceDistance.segment(meters: 300, form: .plain) else { return nil }
            return ["kind.camera", .comma, distance]
        }
    }

    // MARK: - Общие рецепты (порядок слов у двух языков совпадает)

    /// Фраза о камере. Порядок слов у русского и узбекского одинаков; всё
    /// различие — внутри отрывков («через пятьсот метров» против «besh yuz
    /// metrdan soʻng») и в числительных (`number`).
    /// `kind`/`short` — как язык называет тип (`CameraType.spokenName` /
    /// `spokenShortName`): по-узбекски стационарные типы — одним словом.
    static func camera(_ call: VoiceEvent.CameraCall,
                       number: (Int) -> [SegmentID]?,
                       kind: (VoiceEvent.Kind) -> SegmentID = { VoiceComposer.kind($0) },
                       short: (VoiceEvent.Kind) -> SegmentID = { VoiceComposer.shortKind($0) }) -> [SegmentID]? {
        var out: [SegmentID] = []
        if call.fromDrivers, call.form != .group { out += ["w.drivers_mark", .comma] }
        switch call.form {
        case .group:
            guard let d = VoiceDistance.segment(meters: call.meters, form: .plain) else { return nil }
            out += ["w.cameras_ahead", .comma, d]
        case .brief:
            guard let d = VoiceDistance.segment(meters: call.meters, form: .plain) else { return nil }
            out += [short(call.kind), .comma, d]
        case .onRoute:
            // «Marshrutda radar besh yuz metrdan soʻng»
            guard let d = VoiceDistance.segment(meters: call.meters, form: .after) else { return nil }
            out += ["w.on_route", kind(call.kind), d]
        case .full(let place):
            guard let d = VoiceDistance.segment(meters: call.meters, form: .plain) else { return nil }
            out += [kind(call.kind), side(place), .comma, d]
        }
        switch call.tail {
        case .none:
            break
        case .limit(let limit):
            guard let value = number(limit) else { return nil }
            out += [.comma, "w.here"] + value
        case .speed(let speed):
            guard let value = number(speed) else { return nil }
            out += [.stop, "w.your_speed"] + value
        case .speedAndLimit(let speed, let limit):
            guard let s = number(speed), let l = number(limit) else { return nil }
            out += [.stop, "w.your_speed"] + s + [.comma, "w.limit"] + l
        }
        return out
    }

    /// Манёвр: «через 300 метров, поверните направо. Из левого ряда» или
    /// «…поверните налево. Перестройтесь в левый ряд».
    static func maneuver(_ call: VoiceEvent.ManeuverCall) -> [SegmentID]? {
        guard let command = action(call.action) else { return nil }
        var out: [SegmentID] = []
        if let meters = call.meters {
            guard let d = VoiceDistance.segment(meters: meters, form: .after) else { return nil }
            out += [d, .comma]
        }
        out += command
        if let run = call.lanes {
            out += [.stop, lane(run)]
        } else if let side = call.edge {
            out += [.stop, edge(side)]
        }
        return out
    }
}

// MARK: - Расстояние

/// Записанные ступени расстояния. Это контракт с записью, а не настройка:
/// новая ступень значит новый отрывок у диктора, поэтому список живёт здесь,
/// рядом со сценарием, а не в AppConfig.
///
/// Ступени — то, что приложение произносит на самом деле: камера округляет
/// до 50 м ближе 400 м и до 100 м дальше (радиус не больше 1,5 км), манёвр —
/// до 50/100 м в пределах 900 м, лимит впереди — до 50 м в 100–400 м,
/// пробка — до 100 м в пределах 1,5 км. Километры говорят так, как говорят
/// навигаторы: «километр», «полтора километра»; 1,2 км звучит как километр
/// (ошибка округления ≤ 25 %, иначе фраза идёт синтезатором).
nonisolated enum VoiceDistance {

    enum Form: Sendable {
        /// «триста метров» / «uch yuz metr».
        case plain
        /// «через триста метров» / «uch yuz metrdan soʻng».
        case after
        /// «около трёхсот метров» — у русского родительный падеж; узбекский
        /// говорит «taxminan» отдельным отрывком перед обычной формой.
        case about
    }

    static let steps = [50, 100, 150, 200, 250, 300, 350, 400, 500, 600, 700, 800, 900, 1000, 1500]

    /// Наибольшая допустимая ошибка ступени относительно расстояния.
    static let maxRelativeError = 0.25

    /// Ближайшая записанная ступень или nil (дальше 25 % от любой).
    static func step(for meters: Int) -> Int? {
        guard meters > 0, let best = steps.min(by: { abs($0 - meters) < abs($1 - meters) }) else {
            return nil
        }
        guard Double(abs(best - meters)) <= Double(meters) * maxRelativeError else { return nil }
        return best
    }

    static func segment(meters: Int, form: Form) -> SegmentID? {
        guard let step = step(for: meters) else { return nil }
        switch form {
        case .plain: return SegmentID("dist.\(step)")
        case .after: return SegmentID("dist.\(step).after")
        case .about: return SegmentID("dist.\(step).about")
        }
    }
}

/// Длительность так, как её режет `Formatting.duration`: часы и минуты;
/// одни секунды не говорим записью (у пробки и объезда их не бывает).
nonisolated enum VoiceDuration {
    static func split(seconds: Int) -> (hours: Int, minutes: Int)? {
        guard seconds >= 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        guard hours > 0 || minutes > 0 else { return nil }
        return (hours, minutes)
    }
}

// MARK: - Узбекский

extension VoiceComposer {

    nonisolated enum Uzbek {

        static func compose(_ event: VoiceEvent) -> [SegmentID]? {
            switch event {
            case .camera(let call):
                return VoiceComposer.camera(call, number: { number($0) }, kind: { Self.kind($0) },
                                            short: { Self.kind($0) })
            case .cameraName(let kind):     return [Self.kind(kind)]
            case .maneuver(let call):       return VoiceComposer.maneuver(call)
            case .limitAhead(let limit, let meters):
                // «ikki yuz metrdan soʻng tezlik cheklovi qirq»
                guard let distance = VoiceDistance.segment(meters: meters, form: .after),
                      let value = number(limit) else { return nil }
                return [distance, "w.speed_limit"] + value
            case .jam(let meters, let delay):
                // «Oldinda tirbandlik: taxminan bir kilometr, qoʻshimcha besh daqiqa»
                guard let distance = VoiceDistance.segment(meters: meters, form: .plain),
                      let time = duration(delay) else { return nil }
                return ["w.jam_ahead", .comma, "w.about", distance, .comma, "w.plus"] + time
            case .detour(let saving):
                // «Oldinda tirbandlik. Sakkiz daqiqa tezroq yoʻl bor»
                guard let time = duration(saving) else { return nil }
                return ["w.jam_ahead", .stop] + time + ["w.faster_way"]
            case .hotspot(let peak):
                guard let peak else { return ["p.tripod_often"] }
                return ["p.tripod_often", .comma, VoiceComposer.peak(peak)]
            case .phrase(let phrase):
                return VoiceComposer.phrase(phrase, closureMark: "p.road_closure")
            }
        }

        /// Тип камеры — как `CameraType.spokenName` / `spokenShortName` (uz):
        /// без «Statsionar» и «Intellektual …», одним словом и в полной, и в
        /// короткой фразе (решение владельца 23.10, 28.M).
        static func kind(_ kind: VoiceEvent.Kind) -> SegmentID {
            switch kind {
            case .stationaryCamera:                   return "kind.camera"
            case .stationaryRadar, .intelligentRadar: return "kind.radar"
            default:                                  return VoiceComposer.kind(kind)
            }
        }

        /// Число 1…299 из записанных единиц, десятков и сотен: 65 =
        /// «oltmish» + «besh». Узбекские числительные складываются без
        /// изменений на стыках, поэтому склейка честная.
        static func number(_ value: Int) -> [SegmentID]? {
            guard (1...VoiceScript.maxNumber).contains(value) else { return nil }
            var out: [SegmentID] = []
            var rest = value
            if rest >= 100 {
                out.append(SegmentID("num.\(rest / 100 * 100)"))
                rest %= 100
            }
            if rest >= 10 {
                out.append(SegmentID("num.\(rest / 10 * 10)"))
                rest %= 10
            }
            if rest > 0 { out.append(SegmentID("num.\(rest)")) }
            return out
        }

        /// «bir soat besh daqiqa»: числительное перед существительным не
        /// склоняется, единица — одна форма.
        static func duration(_ seconds: Int) -> [SegmentID]? {
            guard let (hours, minutes) = VoiceDuration.split(seconds: seconds) else { return nil }
            var out: [SegmentID] = []
            if hours > 0 {
                guard let h = number(hours) else { return nil }
                out += h + ["unit.hour"]
            }
            if minutes > 0 {
                guard let m = number(minutes) else { return nil }
                out += m + ["unit.minute"]
            }
            return out
        }
    }
}

// MARK: - Русский

extension VoiceComposer {

    nonisolated enum Russian {

        static func compose(_ event: VoiceEvent) -> [SegmentID]? {
            switch event {
            case .camera(let call):         return VoiceComposer.camera(call, number: { number($0) })
            case .cameraName(let kind):     return [VoiceComposer.kind(kind)]
            case .maneuver(let call):       return VoiceComposer.maneuver(call)
            case .limitAhead(let limit, let meters):
                // «Ограничение сорок через двести метров»
                guard let distance = VoiceDistance.segment(meters: meters, form: .after),
                      let value = number(limit) else { return nil }
                return ["w.speed_limit"] + value + [distance]
            case .jam(let meters, let delay):
                // «Впереди пробка: около километра, плюс четыре минуты»
                guard let distance = VoiceDistance.segment(meters: meters, form: .about),
                      let time = duration(delay, accusative: false) else { return nil }
                return ["w.jam_ahead", .comma, distance, .comma, "w.plus"] + time
            case .detour(let saving):
                // «Впереди пробка. Есть путь быстрее на восемь минут»
                guard let time = duration(saving, accusative: true) else { return nil }
                return ["w.jam_ahead", .stop, "w.faster_way"] + time
            case .hotspot(let peak):
                guard let peak else { return ["p.tripod_often"] }
                return ["p.tripod_often", .comma, VoiceComposer.peak(peak)]
            case .phrase(let phrase):
                // «Отметка водителей: впереди перекрытие» — у русского своя
                // краткая форма, «Впереди перекрытие дороги» сюда не ложится.
                return VoiceComposer.phrase(phrase, closureMark: "p.road_closure_mark")
            }
        }

        enum Gender { case masculine, feminine }

        /// Число 1…299. Русские 11–19 — свои слова, у «один/два» женский род
        /// («одна минута», винительный «одну минуту»), поэтому эти три формы
        /// записываются отдельно.
        static func number(_ value: Int, gender: Gender = .masculine,
                           accusative: Bool = false) -> [SegmentID]? {
            guard (1...VoiceScript.maxNumber).contains(value) else { return nil }
            var out: [SegmentID] = []
            var rest = value
            if rest >= 100 {
                out.append(SegmentID("num.\(rest / 100 * 100)"))
                rest %= 100
            }
            if rest >= 20 {
                out.append(SegmentID("num.\(rest / 10 * 10)"))
                rest %= 10
            }
            if rest >= 10 {
                out.append(SegmentID("num.\(rest)"))
                rest = 0
            }
            if rest > 0 {
                switch (rest, gender, accusative) {
                case (1, .feminine, true):  out.append("num.1.f.acc")
                case (1, .feminine, false): out.append("num.1.f")
                case (2, .feminine, _):     out.append("num.2.f")
                default:                    out.append(SegmentID("num.\(rest)"))
                }
            }
            return out
        }

        enum Plural { case one, few, many }

        static func plural(_ value: Int) -> Plural {
            let mod10 = value % 10, mod100 = value % 100
            if mod10 == 1, mod100 != 11 { return .one }
            if (2...4).contains(mod10), !(12...14).contains(mod100) { return .few }
            return .many
        }

        /// «плюс одна минута» / «быстрее на одну минуту»; «час» — мужского
        /// рода и в винительном не меняется.
        static func duration(_ seconds: Int, accusative: Bool) -> [SegmentID]? {
            guard let (hours, minutes) = VoiceDuration.split(seconds: seconds) else { return nil }
            var out: [SegmentID] = []
            if hours > 0 {
                guard let h = number(hours) else { return nil }
                let unit: SegmentID = switch plural(hours) {
                case .one: "unit.hour.one"
                case .few: "unit.hour.few"
                case .many: "unit.hour.many"
                }
                out += h + [unit]
            }
            if minutes > 0 {
                guard let m = number(minutes, gender: .feminine, accusative: accusative) else { return nil }
                let unit: SegmentID = switch plural(minutes) {
                case .one: accusative ? "unit.minute.one.acc" : "unit.minute.one"
                case .few: "unit.minute.few"
                case .many: "unit.minute.many"
                }
                out += m + [unit]
            }
            return out
        }
    }
}
