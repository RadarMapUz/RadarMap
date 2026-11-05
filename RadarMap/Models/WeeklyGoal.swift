//
//  WeeklyGoal.swift
//  RadarMap
//
//  «Цель недели: без превышений у камер» (31E, п. 5) с серией недель.
//
//  Цель одна и не выбирается: та, что прямо влияет на штрафы и рейтинг.
//  Считается по дневным итогам (`TripDay`) — они живут вечно, поэтому серия
//  переживает чистку записей. Неделя календарная, как везде в «Итогах».
//
//  Правила серии:
//    * неделя засчитана, если у камер были проезды с известным лимитом и ни
//      одного штрафуемого превышения;
//    * неделя без таких проездов (отпуск, машина в сервисе) серию не рвёт и
//      не удлиняет — нечем было ни заслужить, ни сорвать;
//    * идущая неделя в серию не входит, пока не кончилась: «уже 4» в среду —
//      обещание, а не факт.
//
//  Чистая логика — WeeklyGoalTests.
//

import Foundation

nonisolated struct WeeklyGoal: Equatable, Sendable {

    enum State: Equatable, Sendable {
        /// На этой неделе у камер ещё не судили ни одного проезда.
        case waiting
        /// Пока ни одного превышения; `passes` — судимых проездов.
        case onTrack(passes: Int)
        /// Сорвана: столько штрафуемых превышений.
        case missed(over: Int)
    }

    /// День недели на полосе из семи точек.
    enum Mark: Equatable, Sendable {
        case none       // у камер не проезжали
        case clean
        /// «На грани» (PassVerdict): штрафа нет, балл снят — цель не сорвана,
        /// но день не «чистый» зелёный.
        case edge
        case over
        case future
    }

    let state: State
    /// Завершённых недель подряд без превышений (до этой).
    let streak: Int
    /// Семь дней текущей недели — по порядку календаря пользователя.
    let marks: [Mark]

    /// nil — у камер не судили ни одного проезда за весь просмотр: цель не о
    /// чем ставить (нет лимитов, нет камер на пути).
    static func build(days: [TripDay], now: Date, calendar: Calendar = .current,
                      lookback: Int = AppConfig.weeklyGoalLookbackWeeks) -> WeeklyGoal? {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let current = TripDayBook.days(days, in: week)
        let judged = current.reduce(0) { $0 + $1.cleanPasses + $1.overPasses }
        let over = current.reduce(0) { $0 + $1.overPasses }
        let state: State = over > 0 ? .missed(over: over) : judged > 0 ? .onTrack(passes: judged) : .waiting

        var streak = 0
        var anyJudged = judged > 0
        var cursor = week
        for _ in 0..<lookback {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor.start),
                  let previous = calendar.dateInterval(of: .weekOfYear, for: start) else { break }
            cursor = previous
            let window = TripDayBook.days(days, in: previous)
            let weekJudged = window.reduce(0) { $0 + $1.cleanPasses + $1.overPasses }
            guard weekJudged > 0 else { continue }
            anyJudged = true
            if window.contains(where: { $0.overPasses > 0 }) { break }
            streak += 1
        }
        guard anyJudged else { return nil }

        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(current.map { (calendar.startOfDay(for: $0.day), $0) },
                               uniquingKeysWith: { a, _ in a })
        var marks: [Mark] = []
        var day = week.start
        for _ in 0..<7 {
            let key = calendar.startOfDay(for: day)
            if key > today {
                marks.append(.future)
            } else if let item = byDay[key], item.cleanPasses + item.overPasses > 0 {
                marks.append(item.overPasses > 0 ? .over : (item.edgePasses ?? 0) > 0 ? .edge : .clean)
            } else {
                marks.append(.none)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return WeeklyGoal(state: state, streak: streak, marks: marks)
    }
}
