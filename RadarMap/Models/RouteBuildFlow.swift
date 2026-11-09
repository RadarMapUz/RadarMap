//
//  RouteBuildFlow.swift
//  RadarMap
//
//  Что сейчас с построением маршрута — одно состояние на телефон и машину.
//
//  Владелец, 09.11: «постройка нормально, loading должен быть, сейчас лагает,
//  некрасиво, непонятно нажал ли». От касания до готового маршрута проходило
//  до 6 с ожидания GPS (без всякого отклика) и до 12 с сети (крошечная плашка,
//  и только без маршрута на экране). Второе касание уходило вторым запросом, а
//  первый, вернувшись, гасил индикатор второго.
//
//  Здесь: одна попытка за раз, у неё номер. Касание той же цели — не второе
//  построение; другая цель заменяет попытку; опоздавший ответ старой попытки
//  ничего не меняет. Время — снаружи (`markSlow`), поэтому логика чистая.
//  RouteBuildFlowTests.
//

import Foundation

nonisolated struct RouteBuildFlow: Equatable, Sendable {

    struct Target: Equatable, Sendable {
        enum Purpose: Equatable, Sendable { case route, addStop, removeStop }

        let name: String
        let latitude: Double
        let longitude: Double
        var purpose: Purpose = .route

        func isSame(as other: Target) -> Bool {
            purpose == other.purpose
                && GeoMath.fastDistance(latitude, longitude, other.latitude, other.longitude)
                    < AppConfig.routeBuildSameTargetMeters
        }
    }

    enum Stage: Int, Comparable, CaseIterable, Sendable {
        case locating, calculating, comparing

        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    enum Failure: Equatable, Sendable {
        case noFix
        case network
        case noRoute
        case unavailable
        /// Заезд по пути не добавлен или не убран: маршрут остался прежним.
        case stopUnchanged
    }

    enum State: Equatable, Sendable {
        case idle
        case working(Target, Stage, slow: Bool)
        case failed(Target, Failure)
    }

    /// Чем кончилось построение для того, кто его начал.
    enum Outcome: Equatable, Sendable {
        case built
        case failed
        /// Водитель отменил.
        case cancelled
        /// Пока строилось, выбрали другую цель.
        case superseded
        /// К этой цели уже строится.
        case duplicate
    }

    enum Begin: Equatable, Sendable {
        case started(Int)
        /// Шла попытка к другой цели — её результат больше не нужен.
        case replaced(Int)
        case duplicate
    }

    private(set) var state: State = .idle
    private(set) var attempt = 0

    /// Идёт любая стадия, включая ожидание GPS.
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Идёт расчёт: прогресс по маршруту заморожен. Ожидание GPS — не расчёт,
    /// линия прежнего маршрута это время живёт.
    var isCalculating: Bool {
        if case .working(_, let stage, _) = state { return stage >= .calculating }
        return false
    }

    /// Можно ли предложить «Повторить»: нет смысла при отсутствии дороги,
    /// при выключенных маршрутах и для заезда (маршрут остался прежним).
    static func canRetry(_ target: Target, _ failure: Failure) -> Bool {
        guard target.purpose == .route else { return false }
        return failure == .network || failure == .noFix
    }

    func isCurrent(_ attempt: Int) -> Bool { isWorking && attempt == self.attempt }

    mutating func begin(_ target: Target) -> Begin {
        if case .working(let current, _, _) = state {
            if current.isSame(as: target) { return .duplicate }
            attempt += 1
            state = .working(target, .locating, slow: false)
            return .replaced(attempt)
        }
        attempt += 1
        state = .working(target, .locating, slow: false)
        return .started(attempt)
    }

    /// Стадии идут только вперёд.
    mutating func advance(_ attempt: Int, to stage: Stage) {
        guard isCurrent(attempt), case .working(let target, let now, let slow) = state, stage > now else { return }
        state = .working(target, stage, slow: slow)
    }

    mutating func markSlow(_ attempt: Int) {
        guard isCurrent(attempt), case .working(let target, let stage, false) = state else { return }
        state = .working(target, stage, slow: true)
    }

    /// true — попытка ещё была текущей.
    @discardableResult
    mutating func finish(_ attempt: Int) -> Bool {
        guard isCurrent(attempt) else { return false }
        state = .idle
        return true
    }

    /// true — ошибка принята; ответ старой попытки экран не трогает.
    @discardableResult
    mutating func fail(_ attempt: Int, _ failure: Failure) -> Bool {
        guard isCurrent(attempt), case .working(let target, _, _) = state else { return false }
        state = .failed(target, failure)
        return true
    }

    /// Стадия, на которой отменили; nil — отменять было нечего.
    @discardableResult
    mutating func cancel() -> Stage? {
        guard case .working(_, let stage, _) = state else { return nil }
        attempt += 1
        state = .idle
        return stage
    }

    /// Закрыть сообщение об ошибке. Идущую попытку не трогает.
    mutating func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    /// Маршрут сняли: ни попытки, ни её ошибки больше нет.
    mutating func reset() {
        if case .working = state { attempt += 1 }
        state = .idle
    }
}

/// Слова — на главном потоке: Formatting и каталог знают язык приложения.
extension RouteBuildFlow.Stage {
    var title: String {
        switch self {
        case .locating:    return String(localized: "Определяю положение…")
        case .calculating: return String(localized: "Строим маршрут…")
        case .comparing:   return String(localized: "Сравниваю варианты…")
        }
    }
}

extension RouteBuildFlow.Failure {
    /// Что случилось; nil — сказать может только сервис (`errorMessage`).
    var title: String? {
        switch self {
        case .noFix:         return String(localized: "Не видим ваше положение")
        case .network:       return String(localized: "Нет связи с сервером маршрутов")
        case .noRoute:       return String(localized: "Маршрут не найден")
        case .unavailable:   return String(localized: "Маршруты временно недоступны")
        case .stopUnchanged: return nil
        }
    }

    /// Что делать дальше.
    var hint: String? {
        switch self {
        case .noFix:         return String(localized: "Подождите пару секунд и повторите")
        case .network:       return String(localized: "Проверьте интернет и повторите")
        case .noRoute:       return String(localized: "Попробуйте точку рядом")
        case .unavailable:   return String(localized: "Мы уже чиним")
        case .stopUnchanged: return nil
        }
    }
}
