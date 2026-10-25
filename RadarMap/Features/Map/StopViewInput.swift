//
//  StopViewInput.swift
//  RadarMap
//
//  Что нужно кадру остановки (StopView, 29.D) от сервисов: одно место для
//  телефона и машины. Зовётся из тела карты — вью-изолятора тика (правило
//  13), как DrivingDeclutter. Конец пробки ищется только стоя и только с
//  маршрутом: ≤ 18 шагов по пути вперёд, каждый — запрос в сетку пробок.
//

import CoreLocation
import Foundation

@MainActor
enum StopViewInput {

    #if DEBUG
    private static let disabled = ProcessInfo.processInfo.arguments.contains("-noStopView")
    #endif

    struct Input {
        var state: StopView.State
        var jamEnd: Double?
    }

    static func read(_ tracker: inout StopView.Tracker, env: AppEnvironment, maneuverDistance: Double?,
                     active: Bool, at now: Date = Date()) -> Input {
        #if DEBUG
        // `-noStopView` — кадр «до 29.D» на той же сборке: снимки и замер CPU.
        let active = active && !disabled
        #endif
        let state = tracker.update(speedKmh: env.location.speedKmh, maneuverDistance: maneuverDistance,
                                   active: active, at: now)
        guard state.standing, env.route.isActive, env.traffic.isShown,
              let snapshot = env.traffic.snapshot,
              let here = env.location.displayCoordinate ?? env.location.currentCoordinate,
              let path = env.route.pathAhead(from: here, meters: AppConfig.stopViewJamMaxMeters
                                                + AppConfig.stopViewJamGapMeters)
        else { return Input(state: state, jamEnd: nil) }
        let end = StopView.jamEnd(path: path) { point, course in
            snapshot.matchingEdge(at: point, course: course)?.level
        }
        return Input(state: state, jamEnd: end)
    }
}
