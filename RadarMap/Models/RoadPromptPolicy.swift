//
//  RoadPromptPolicy.swift
//  RadarMap
//
//  Очередь «вопросов на ходу» телефона — одна на семь плашек (этап 45,
//  вариант B дизайнера, выбор владельца 05.11).
//
//  До 45 каждая плашка решала сама, когда встать: объезд — сверху под
//  манёвром, вопрос о проезде, выбор типа, «опаздываю» и «карта по пути» —
//  над панелью поездки, погода — снова сверху. Друг друга исключали только
//  два вопроса о проезде: объезд и вопрос, «опаздываю» и выбор отметки могли
//  стоять разом, а под оповещением о камере у половины срок сгорал невидимым.
//
//  Правило то же, что у баннеров машины (CarPlayBannerPolicy): на экране —
//  один вопрос, старший. Камера выше всего и в очередь не входит: под ней
//  ждут все, и отсчёт стоит. Вытесненный возвращается по своему правилу —
//  или молча снимается, как если бы промолчали.
//
//  Сроки и решения вопросов здесь не живут: что уходит на сервер и когда,
//  решают их владельцы (MobileCameraService, ReportFlow, RouteService,
//  RoadWeatherService, CommuteLiveService, RouteCorridorService). Очередь
//  решает только «кого показать» и «вернуть ли вытесненного».
//
//  Чистая логика — RoadPromptPolicyTests.
//

import Foundation

nonisolated enum RoadPromptPolicy {

    /// Вид вопроса — по возрастанию важности.
    enum Kind: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
        /// «Карта по пути без интернета» — стоя, ждёт ответа сколько угодно.
        case corridor
        /// «Опаздываю — предупредить?» — стоя, раз за поездку.
        case late
        /// Погода на перевале впереди — сообщение без решения.
        case roadWeather
        /// «Ещё стоит?» / «Ещё перекрыто?» после проезда.
        case passQuestion
        /// Объезд пробки — решение про маршрут.
        case detour
        /// Ответ на своё касание «Отметить»: выбор типа, затем «Отменить».
        /// Перебивает его только камера: пропавший выбор читался бы как
        /// «касание не сработало».
        case ownTouch

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var description: String {
            switch self {
            case .corridor:     return "карта по пути"
            case .late:         return "опаздываю"
            case .roadWeather:  return "погода на перевале"
            case .passQuestion: return "вопрос о проезде"
            case .detour:       return "объезд"
            case .ownTouch:     return "своё касание"
            }
        }

        /// Как возвращается вытесненный.
        var comeback: Comeback {
            switch self {
            case .ownTouch:                          return .never
            case .detour, .passQuestion, .roadWeather: return .ifTimeLeft
            case .late:                              return .nextStop
            case .corridor:                          return .always
            }
        }
    }

    enum Comeback: Equatable, Sendable {
        /// Не возвращается: решение за ним доводит его владелец (выбор
        /// отметки уходит треногой по сроку ReportFlow).
        case never
        /// Возвращается, если по его часам осталось не меньше
        /// `AppConfig.roadPromptMinReturnSeconds`; иначе снимается молча.
        case ifTimeLeft
        /// Возвращается на следующей остановке и тоже только с остатком срока.
        case nextStop
        /// Ждёт, сколько нужно (срока нет).
        case always
    }

    /// Вопрос, который хочет на экран.
    struct Candidate: Equatable, Sendable {
        let kind: Kind
        /// Свой у каждого экземпляра: другая отметка — другой вопрос.
        let id: String
        /// Сколько осталось по его часам; nil — без срока.
        var remaining: TimeInterval? = nil
        /// Уже стоял на экране и был вытеснен (камерой или старшим вопросом).
        var preempted = false
    }

    struct Outcome: Equatable, Sendable {
        /// Кого показать; nil — никого (камера, пусто, все ждут).
        var shown: Candidate?
        /// Вытесненные, которым не вернуться: снять так же, как по сроку
        /// без ответа (молчание — ничего не уходит).
        var expired: [String] = []
    }

    /// - `covered`: экран занят камерой (или своим действием водителя —
    ///   точкой на карте, прицелом камеры): никого не показываем, отсчёт стоит.
    /// - `standing`: машина стоит — для «опаздываю», вытесненного на ходу.
    static func decide(_ candidates: [Candidate], covered: Bool, standing: Bool,
                       minReturn: TimeInterval = AppConfig.roadPromptMinReturnSeconds) -> Outcome {
        var outcome = Outcome()
        var eligible: [Candidate] = []
        for candidate in candidates {
            switch verdict(candidate, standing: standing, minReturn: minReturn) {
            case .show:   eligible.append(candidate)
            case .wait:   break
            case .expire: outcome.expired.append(candidate.id)
            }
        }
        guard !covered else { return outcome }
        // Старший. Равных не бывает: каждый вид спрашивает об одном за раз.
        outcome.shown = eligible.reduce(nil) { best, next in
            guard let best else { return next }
            return next.kind > best.kind ? next : best
        }
        return outcome
    }

    private enum Verdict { case show, wait, expire }

    private static func verdict(_ candidate: Candidate, standing: Bool,
                                minReturn: TimeInterval) -> Verdict {
        // Срок вышел целиком — не наш вопрос: его снимет владелец по своим
        // часам. Вытесненный с хвостом меньше порога — снять сейчас: секунда
        // на экране читается как сбой, а не как вопрос.
        if let remaining = candidate.remaining, remaining <= 0 { return .expire }
        guard candidate.preempted else { return .show }
        switch candidate.kind.comeback {
        case .never:
            return .wait
        case .always:
            return .show
        case .ifTimeLeft:
            return (candidate.remaining ?? .infinity) >= minReturn ? .show : .expire
        case .nextStop:
            if let remaining = candidate.remaining, remaining < minReturn { return .expire }
            return standing ? .show : .wait
        }
    }
}

/// Часы вопросов, чей срок отсчитывает экран, а не владелец: время копится,
/// только пока вопрос на экране. Под камерой и под старшим вопросом оно
/// стоит — вопрос возвращается с тем же остатком.
nonisolated struct RoadPromptClock: Equatable, Sendable {
    /// Сколько секунд вопрос уже простоял на экране до текущего показа.
    private(set) var shownBefore: TimeInterval = 0
    /// С какого момента он на экране сейчас; nil — не на экране.
    private(set) var visibleSince: Date?
    /// Стоял на экране и был убран, хотя ещё ждёт ответа.
    private(set) var preempted = false

    var wasShown: Bool { visibleSince != nil || shownBefore > 0 || preempted }

    mutating func show(at now: Date) {
        guard visibleSince == nil else { return }
        visibleSince = now
    }

    /// Убран с экрана, ответа нет.
    mutating func hide(at now: Date) {
        guard let since = visibleSince else { return }
        shownBefore += max(0, now.timeIntervalSince(since))
        visibleSince = nil
        preempted = true
    }

    func shown(at now: Date) -> TimeInterval {
        shownBefore + (visibleSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func remaining(total: TimeInterval, at now: Date) -> TimeInterval {
        max(0, total - shown(at: now))
    }

    /// Когда истечёт, если на экране сейчас; nil — не на экране.
    func deadline(total: TimeInterval) -> Date? {
        visibleSince.map { $0.addingTimeInterval(max(0, total - shownBefore)) }
    }
}
