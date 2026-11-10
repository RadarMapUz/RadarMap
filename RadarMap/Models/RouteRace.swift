//
//  RouteRace.swift
//  RadarMap
//
//  Apple или свой OSRM (76): оба запроса идут одновременно, Apple главнее.
//  До 76 готовый ответ OSRM ждал Apple без срока — внутри Узбекистана Apple
//  не строит, и его отказ (или молчание) прибавлялся к каждому построению.
//  Теперь Apple ждём до срока от начала: после него берём свой ответ. Свой
//  ответ без сети (граф трасс) и отказ своего — не повод бросать Apple, пока
//  тот ещё в пути. Чистая логика, RouteRaceTests.
//

import Foundation

nonisolated struct RouteRace<Value> {

    enum Event {
        /// Ответ Apple; nil — отказ или пусто.
        case apple(Value?)
        /// Ответ своего сервера; `weak` — приблизительный (граф трасс без сети).
        case own(Result<Value, Error>, weak: Bool)
        /// Срок ожидания Apple вышел.
        case deadline
    }

    enum Decision {
        case wait
        case take(Value)
        case fail(Error)
    }

    private var appleFailed = false
    private var deadlinePassed = false
    private var own: (result: Result<Value, Error>, weak: Bool)?

    mutating func note(_ event: Event) -> Decision {
        switch event {
        case .apple(let value?):
            return .take(value)
        case .apple(nil):
            appleFailed = true
        case .own(let result, let weak):
            own = (result, weak)
        case .deadline:
            deadlinePassed = true
        }
        guard let own else { return .wait }
        if appleFailed { return Self.settle(own.result) }
        if deadlinePassed, !own.weak, case .success(let value) = own.result { return .take(value) }
        return .wait
    }

    /// Все ответы пришли, решения не было (не бывает при честных событиях).
    func fallback() -> Decision {
        guard let own else { return .fail(CancellationError()) }
        return Self.settle(own.result)
    }

    private static func settle(_ result: Result<Value, Error>) -> Decision {
        switch result {
        case .success(let value): .take(value)
        case .failure(let error): .fail(error)
        }
    }
}
