//
//  LaneAdvice.swift
//  RadarMap
//
//  «Из двух левых рядов» и «Перестройтесь в левый ряд» — в какой ряд встать.
//
//  Ряд стрелок отвечает на вопрос «куда можно с каждой полосы», но водителю
//  нужен ответ «в какой ряд встать», и считать стрелки на ходу — лишний
//  взгляд. Китайские навигаторы (Amap, Baidu) пишут это словами над рядом;
//  здесь то же, и только там, где ответ однозначен: подходящие полосы идут
//  подряд от края или посередине. Разрозненные подходящие полосы словами не
//  описать коротко — тогда говорит только ряд стрелок.
//
//  Полосы OSRM приезжают редко: `turn:lanes` в OSM стоит у малой доли
//  перекрёстков, и на двенадцати маршрутах по Ташкенту (21.10) ряд пришёл у
//  7 манёвров из 97, у левых поворотов — у одного из 26. Остальным край
//  (этап 20.2, поездка владельца 21.10: «налево — нужно перестроиться налево,
//  с левого края») говорит ПДД, а не догадка: поворот налево и разворот — из
//  крайнего левого положения, направо — из крайнего правого. Неизвестно
//  только, есть ли куда перестраиваться, и это знает своя сеть дорог: полос
//  в нашу сторону на подъезде (`approachLanes`). Одна полоса — молчим: ряд
//  на однополосной улице не выбирают.
//
//  С 20.8 ряд может прийти и из нашего слоя полос (LaneOverlay) — там, где
//  OSRM молчит; для совета он тот же, что ряд OSRM (`RouteStep.laneSource`
//  различает их только для журнала).
//
//  Чистая логика — LaneAdviceTests.
//

import CoreLocation
import Foundation

nonisolated enum LaneAdvice {

    /// Край проезжей части без данных о полосах. Тип — в VoiceEvent: его
    /// же собирает экспорт сценария диктора, где этого файла нет.
    typealias Edge = VoiceEvent.LaneEdge

    /// Что посоветовать водителю перед манёвром.
    enum Advice: Equatable, Sendable {
        /// Точный ряд по полосам OSRM («Из двух левых рядов»).
        case lanes(VoiceEvent.LaneRun)
        /// Край по типу поворота и числу полос своей дороги.
        case edge(Edge)

        /// Имя для журнала: «edge.left», «lanes.leftTwo».
        var logName: String {
            switch self {
            case .lanes(let run): return "lanes." + run.rawValue
            case .edge(let edge): return "edge." + edge.rawValue
            }
        }
    }

    // MARK: - Полосы OSRM

    /// Подсказка словами или nil (подходят все, не подходит ни одна, или
    /// подходящие разрознены).
    static func phrase(_ lanes: [LaneHint]) -> String? {
        run(lanes).map(text(for:))
    }

    /// Какой ряд назвать — типом: записанный голос (этап 16) говорит его
    /// отрывком, а не текстом.
    static func run(_ lanes: [LaneHint]) -> VoiceEvent.LaneRun? {
        let count = lanes.count
        let valid = lanes.indices.filter { lanes[$0].isValid }
        guard count >= 2, !valid.isEmpty, valid.count < count,
              let first = valid.first, let last = valid.last,
              last - first + 1 == valid.count else { return nil }
        let run = valid.count
        if first == 0 {
            // Все, кроме крайнего правого, — короче сказать «кроме правого».
            if run == count - 1, count >= 3 { return .allButRight }
            switch run {
            case 1:  return .leftOne
            case 2:  return .leftTwo
            case 3:  return .leftThree
            default: return .leftMany
            }
        }
        if last == count - 1 {
            if run == count - 1, count >= 3 { return .allButLeft }
            switch run {
            case 1:  return .rightOne
            case 2:  return .rightTwo
            case 3:  return .rightThree
            default: return .rightMany
            }
        }
        return run == 1 ? .middleOne : .middleMany
    }

    static func text(for run: VoiceEvent.LaneRun) -> String {
        switch run {
        case .leftOne:     return String(localized: "Из левого ряда")
        case .leftTwo:     return String(localized: "Из двух левых рядов")
        case .leftThree:   return String(localized: "Из трёх левых рядов")
        case .leftMany:    return String(localized: "Из левых рядов")
        case .rightOne:    return String(localized: "Из правого ряда")
        case .rightTwo:    return String(localized: "Из двух правых рядов")
        case .rightThree:  return String(localized: "Из трёх правых рядов")
        case .rightMany:   return String(localized: "Из правых рядов")
        case .allButRight: return String(localized: "Из любого ряда, кроме правого")
        case .allButLeft:  return String(localized: "Из любого ряда, кроме левого")
        case .middleOne:   return String(localized: "Из среднего ряда")
        case .middleMany:  return String(localized: "Из средних рядов")
        }
    }

    /// С какого расстояния показывать ряд полос. На трассе — раньше: на
    /// 90 км/ч шестьсот метров — это 24 секунды, а перестроиться через три
    /// полосы в потоке за них успевает не каждый.
    static func showDistance(speedKmh: Double) -> Double {
        speedKmh >= AppConfig.laneHighwaySpeedKmh ? AppConfig.laneRowHighwayMeters
                                                   : AppConfig.engineManeuverApproachMeters
    }

    // MARK: - Край без полос

    /// Какой край нужен манёвру по его типу OSRM — ещё без числа полос.
    ///
    /// Развилка и плавный поворот края не получают: их команда сама и есть
    /// подсказка («держитесь левее», «плавно левее»), и повторять её вторым
    /// предложением — шум. Съезд с трассы стороны не называет («сверните на
    /// съезд»), ему край нужен. Кольцо — ряд зависит от съезда и разметки,
    /// догадка там чаще ошибается, чем помогает; въезд на трассу и слияние —
    /// там ряд выбирать уже не из чего.
    static func edge(osrmType type: String, modifier: String?) -> Edge? {
        switch type {
        case "turn", "end of road":
            switch modifier {
            case "left", "sharp left":   return .left
            case "right", "sharp right": return .right
            case "uturn":                return .farLeft
            default:                     return nil
            }
        case "continue":
            return modifier == "uturn" ? .farLeft : nil
        case "off ramp":
            switch modifier {
            case "left", "slight left", "sharp left":    return .keepLeft
            case "right", "slight right", "sharp right": return .keepRight
            default:                                     return nil
            }
        default:
            return nil
        }
    }

    /// Совет перед манёвром.
    ///
    /// Полосы OSRM, если они есть, решают целиком: они знают число полос
    /// точнее любой догадки, и «подходят все» значит «встаньте в любой», а не
    /// «перестройтесь влево». Без них край звучит, только если перестраиваться
    /// есть куда: в нашу сторону две полосы и больше. Неизвестно — молчим:
    /// ряд на однополосной улице на каждом повороте — шум, а не помощь.
    static func advice(lanes: [LaneHint], edge: Edge?, lanesPerDirection: Int?) -> Advice? {
        if !lanes.isEmpty { return run(lanes).map(Advice.lanes) }
        guard let edge, let count = lanesPerDirection,
              count >= AppConfig.laneAdviceMinLanes else { return nil }
        return .edge(edge)
    }

    /// Фраза голоса после команды: «Перестройтесь в левый ряд».
    static func spoken(_ advice: Advice) -> String {
        switch advice {
        case .lanes(let run): return text(for: run)
        case .edge(let edge): return spoken(edge)
        }
    }

    static func spoken(_ edge: Edge) -> String {
        switch edge {
        case .left:      return String(localized: "Перестройтесь в левый ряд")
        case .farLeft:   return String(localized: "Перестройтесь в крайний левый ряд")
        case .right:     return String(localized: "Перестройтесь в правый ряд")
        case .keepLeft:  return String(localized: "Держитесь левее")
        case .keepRight: return String(localized: "Держитесь правее")
        }
    }

    /// Короткая подпись края в карточке манёвра: «…на улицу Лабзак, левый ряд».
    static func title(_ edge: Edge) -> String {
        switch edge {
        case .left:      return String(localized: "левый ряд")
        case .farLeft:   return String(localized: "крайний левый ряд")
        case .right:     return String(localized: "правый ряд")
        case .keepLeft:  return String(localized: "левее")
        case .keepRight: return String(localized: "правее")
        }
    }

    /// Значок края: к какой кромке прижаться. Не ряд полос — нарисовать
    /// полосы по догадке нельзя, а «к левому краю» — можно.
    static func symbol(_ edge: Edge) -> String {
        switch edge {
        case .left, .farLeft: return "arrow.left.to.line"
        case .right:          return "arrow.right.to.line"
        case .keepLeft:       return "arrow.up.left"
        case .keepRight:      return "arrow.up.right"
        }
    }

    /// Фраза карточки с краем: «Поверните налево на улицу Лабзак, левый ряд».
    /// Полосы OSRM в текст не идут — их показывает ряд стрелок.
    static func instruction(_ text: String, advice: Advice?) -> String {
        guard case .edge(let edge)? = advice else { return text }
        return text + ", " + title(edge)
    }

    // MARK: - Полосы своей дороги на подъезде

    /// Полос в нашу сторону на подъезде к манёвру по своей сети дорог.
    ///
    /// Берётся ближайшая к точке подъезда линия, которая идёт вдоль курса
    /// (в любую сторону: ось дороги в сети не обязана смотреть по ходу), —
    /// иначе поперечная улица самого перекрёстка подсунула бы свои полосы.
    /// Линии без класса и без тега полос (индекс лимитов) не знают ничего:
    /// их «две полосы» — дефолт незнания, и по ним совета нет. nil —
    /// подходящей линии рядом нет.
    static func approachLanes(at point: CLLocationCoordinate2D, course: Double,
                              roads: [RoadLine]) -> Int? {
        var best: (distance: Double, lanes: Int)?
        let tolerance = AppConfig.laneApproachCourseDegrees
        for road in roads where road.isDetailed || road.lanes > 0 {
            guard road.kind != .pedestrian, road.points.count >= 2 else { continue }
            for index in 1..<road.points.count {
                let a = road.points[index - 1], b = road.points[index]
                let bearing = GeoMath.bearing(from: a, to: b)
                let delta = GeoMath.angleDifference(bearing, course)
                guard delta <= tolerance || 180 - delta <= tolerance else { continue }
                let distance = RoadEventRules.distanceToSegment(point, a, b)
                guard distance <= AppConfig.laneApproachMatchMeters,
                      best.map({ distance < $0.distance }) ?? true else { continue }
                best = (distance, lanesPerDirection(road))
            }
        }
        return best?.lanes
    }

    /// Полос в одну сторону: у односторонней — все, у двусторонней — половина
    /// (тег OSM `lanes` — сумма обоих направлений).
    static func lanesPerDirection(_ road: RoadLine) -> Int {
        road.isOneWay ? road.laneCount : road.laneCount / 2
    }

    // MARK: - Когда сказать

    /// С какого расстояния называть ряд: чтобы успеть перестроиться в потоке.
    /// В городе — не меньше 300 м и 20 секунд пути, на трассе — 600 м и 30 с:
    /// там ряды шире и поток плотнее, а за 280 м до съезда на 100 км/ч
    /// остаётся десять секунд.
    static func adviceDistance(speedKmh: Double) -> Double {
        let metersPerSecond = max(0, speedKmh) / 3.6
        if speedKmh >= AppConfig.laneHighwaySpeedKmh {
            return max(AppConfig.laneAdviceHighwayMinMeters, metersPerSecond * AppConfig.laneAdviceHighwaySeconds)
        }
        return max(AppConfig.laneAdviceTownMinMeters, metersPerSecond * AppConfig.laneAdviceTownSeconds)
    }

    /// Ступени голоса манёвра с учётом ряда.
    struct Calls: Equatable, Sendable {
        /// Дальняя фраза, метры; nil — её нет.
        var far: Double?
        /// Ближняя фраза, метры.
        var near: Double
        /// Ряд называется в дальней фразе (иначе — в ближней).
        var adviceOnFar: Bool

        /// Обычные ступени — без совета о ряде.
        static func standard(earlyCall: Bool) -> Calls {
            Calls(far: earlyCall ? AppConfig.maneuverFarCallMeters : nil,
                  near: AppConfig.maneuverNearCallMeters, adviceOnFar: false)
        }
    }

    /// Где сказать ряд, не добавляя отдельной фразы.
    ///
    /// Ряд вливается в фразу манёвра, которая звучит и так: «Через 350 метров
    /// — поверните налево. Перестройтесь в левый ряд». Окно чуть дальше
    /// ближней фразы (город: 300–390 м против 280) — ближняя переезжает к
    /// окну. Окно далеко (трасса) — ряд в дальней фразе; у съезда, которому
    /// дальняя не положена, дальняя появляется на краю окна, а ближняя
    /// остаётся напоминанием.
    ///
    /// `cameraHolds` — камера впереди держит голос (в радиусе оповещения или
    /// войдёт в него за секунды): ступени, которые ряд ДОБАВИЛ, ждут, и ряд
    /// едет на обычной ближней фразе. Камера — первой, как у событий дороги.
    static func calls(earlyCall: Bool, hasAdvice: Bool, speedKmh: Double,
                      cameraHolds: Bool) -> Calls {
        var calls = Calls.standard(earlyCall: earlyCall)
        guard hasAdvice else { return calls }
        let window = adviceDistance(speedKmh: speedKmh)
        if window <= calls.near + AppConfig.laneAdviceMergeGapMeters {
            if !cameraHolds { calls.near = max(calls.near, window) }
            return calls
        }
        calls.adviceOnFar = true
        if !earlyCall {
            calls.far = cameraHolds ? nil : min(window, AppConfig.maneuverFarCallMeters)
        }
        return calls
    }

    /// Назвать ли ряд в этой ступени: один раз на манёвр, никогда в самой
    /// команде («сейчас» перестраиваться поздно), в дальней — только если
    /// так решили `calls`. Пропущенная дальняя (въехали в маршрут ближе)
    /// отдаёт ряд ближней.
    static func attaches(stage: Int, calls: Calls, alreadySaid: Bool) -> Bool {
        guard !alreadySaid else { return false }
        switch stage {
        case 2:  return calls.adviceOnFar
        case 1:  return true
        default: return false
        }
    }
}
