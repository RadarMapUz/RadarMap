//
//  VoiceEvent+Sources.swift
//  RadarMap
//
//  Откуда берутся события голоса: камера, манёвр, пробка, лимит, объезд.
//
//  Каждое событие строится из ТЕХ ЖЕ величин, что и фраза рядом с ним
//  (`announcement`, `Jam.spoken`, `Notice.spoken`, `DetourOffer.spoken`,
//  `maneuverStep`), — и всё равно перед звуком сверяется с текстом
//  (`RecordedVoice.plan`): разошлись — фраза идёт синтезатором. Тесты
//  VoiceTextTests держат обе стороны вместе.
//

import Foundation

extension VoiceEvent.Kind {
    /// nil — `CameraType.other`: название из реестра есть только текстом.
    init?(_ type: CameraType) {
        switch type {
        case .stationaryCamera: self = .stationaryCamera
        case .stationaryRadar:  self = .stationaryRadar
        case .intelligentRadar: self = .intelligentRadar
        case .mobileRadar:      self = .mobileRadar
        case .tripod:           self = .tripod
        case .dpsPost:          self = .dpsPost
        case .accident:         self = .accident
        case .other:            return nil
        }
    }

    var cameraType: CameraType {
        switch self {
        case .stationaryCamera: return .stationaryCamera
        case .stationaryRadar:  return .stationaryRadar
        case .intelligentRadar: return .intelligentRadar
        case .mobileRadar:      return .mobileRadar
        case .tripod:           return .tripod
        case .dpsPost:          return .dpsPost
        case .accident:         return .accident
        }
    }
}

extension VoiceEvent.Side {
    /// Как `LocationService.directionPhrase`: сбоку и сзади-сбоку — «впереди
    /// справа/слева», остальное и неизвестное — «впереди».
    init(_ direction: CameraDirection?) {
        switch direction {
        case .right?, .behindRight?: self = .aheadRight
        case .left?, .behindLeft?:   self = .aheadLeft
        default:                     self = .ahead
        }
    }
}

extension VoiceEvent.Peak {
    /// `TripodHotspots.Spot.peak`: 0 ночь, 1 утро, 2 день, 3 вечер.
    init?(hotspotPeak: Int) {
        switch hotspotPeak {
        case 0: self = .night
        case 1: self = .morning
        case 2: self = .day
        case 3: self = .evening
        default: return nil
        }
    }
}

extension VoiceEvent {

    /// Фраза о камере событием — те же решения, что у
    /// `LocationService.announcement(for:…)`: округление, форма, хвост.
    /// `onRoute` спрашивается, только когда до него доходит очередь (как и в
    /// тексте), чтобы событие не зависело от того, чего фраза не читала.
    static func cameraAnnouncement(type: CameraType, distance: Double, urgent: Bool,
                                   speaksLimit: Bool, brief: Bool, groupCount: Int,
                                   onRoute: () -> Bool, direction: CameraDirection?,
                                   unconfirmed: Bool, currentLimit: Int?,
                                   speedKmh: Double, speakSpeedThreshold: Double) -> VoiceEvent? {
        let step: Double = distance >= 400 ? 100 : 50
        let rounded = Int((distance / step).rounded() * step)
        let form: CameraCall.Form
        if groupCount > 0 {
            form = .group
        } else if brief {
            form = .brief
        } else if onRoute() {
            form = .onRoute
        } else {
            form = .full(Side(direction))
        }
        // Групповая фраза типа не называет — «другой» тип ей не помеха.
        guard let kind = Kind(type) ?? (form == .group ? .stationaryCamera : nil) else { return nil }
        let tail: CameraCall.Tail
        if urgent {
            if let limit = currentLimit {
                tail = .speedAndLimit(speed: Int(speedKmh.rounded()), limit: limit)
            } else if speedKmh >= speakSpeedThreshold {
                tail = .speed(Int(speedKmh.rounded()))
            } else {
                tail = .none
            }
        } else if speaksLimit, let limit = currentLimit {
            tail = .limit(limit)
        } else {
            tail = .none
        }
        return .camera(CameraCall(kind: kind, form: form, meters: rounded,
                                  fromDrivers: unconfirmed && groupCount == 0, tail: tail))
    }
}

/// Чистое сопоставление строк OSRM — без изоляции: его зовёт разбор
/// маршрута вне главного актора (`RouteService`, nonisolated).
nonisolated extension VoiceEvent.Action {
    /// То же решение, что `RouteService.maneuverStep`, — типом. nil — шаг,
    /// который не озвучивается (или озвучивается не этим словарём).
    init?(osrmType type: String, modifier: String?, exit: Int?) {
        func turn(_ modifier: String?) -> VoiceEvent.Action? {
            switch modifier {
            case "left":         return .turnLeft
            case "right":        return .turnRight
            case "slight left":  return .slightLeft
            case "slight right": return .slightRight
            case "sharp left":   return .sharpLeft
            case "sharp right":  return .sharpRight
            case "uturn":        return .uturn
            default:             return nil
            }
        }
        switch type {
        case "turn", "end of road":
            guard let action = turn(modifier) else { return nil }
            self = action
        case "continue":
            guard modifier == "uturn" else { return nil }
            self = .uturn
        case "fork":
            switch modifier {
            case "left", "slight left":   self = .keepLeft
            case "right", "slight right": self = .keepRight
            default: return nil
            }
        case "merge":               self = .merge
        case "on ramp":             self = .onRamp
        case "off ramp":            self = .offRamp
        case "roundabout", "rotary": self = .roundabout(exit: exit ?? 1)
        case "arrive":              self = .arrived
        default:                    return nil
        }
    }
}

extension RouteStep {
    /// Событие голоса для ступени объявления: `meters` nil — сама команда.
    /// Ряд — тот, что назвал текст (`withAdvice`): только заранее и только в
    /// той фразе, где его решили сказать (один раз на манёвр).
    func voiceEvent(meters: Int?, advice: LaneAdvice.Advice? = nil) -> VoiceEvent? {
        guard let voiceAction else { return nil }
        let said = meters == nil ? nil : advice
        var run: VoiceEvent.LaneRun?
        var edge: VoiceEvent.LaneEdge?
        switch said {
        case .lanes(let value)?: run = value
        case .edge(let value)?:  edge = value
        case nil:                break
        }
        return .maneuver(.init(action: voiceAction, meters: meters, lanes: run, edge: edge))
    }
}

extension JamAhead.Jam {
    /// То, что говорит `spoken`: длина до 100 м, задержка в секундах.
    var voiceEvent: VoiceEvent {
        .jam(meters: Int((length / 100).rounded() * 100), delaySeconds: Int(delay.rounded()))
    }
}

extension LimitAhead.Notice {
    var voiceEvent: VoiceEvent {
        .limitAhead(limit: limit, meters: Int((distance / 50).rounded() * 50))
    }
}

extension RouteService.DetourOffer {
    /// С названием улицы («, через Шота Руставели») — только синтезатором:
    /// улиц у диктора нет.
    var voiceEvent: VoiceEvent? {
        via == nil ? .detour(savingSeconds: Int(saving.rounded())) : nil
    }
}
