//
//  EngineFrames.swift
//  RadarMap
//
//  Частота кадров движка карты по ситуации (36A, docs/perf_engine_2026-10-28.md).
//
//  В поездке движок держал 30 к/с всегда — главный расход и приложения, и
//  композитора (аудит 26.10: ~21 % ядра и ~14 % у backboardd). Между фиксами
//  (≈ 1 Гц) ровная карта на прямой только скользит вперёд: 1,5 pt за кадр при
//  20 к/с на 50 км/ч — глаз этого не отличает от 30. Отличает он поворот
//  карты, смену масштаба и наклона и подход к развилке: там картинка
//  меняется вся, и «рывками» замечают (поле 12.10). Поэтому частота — не
//  константа, а решение по тому, что происходит:
//
//  - жест пальцем — полная частота экрана (как было);
//  - покой (карта дорисована и стоит) — редкий такт (аудит 26.10);
//  - под полноэкранным оповещением и на приборке — 15, горячий телефон — 15/20;
//  - в поездке ровный ход — `engineSteadyFPS` (20), но только после
//    нескольких секунд подтверждённого спокойствия (гистерезис вниз);
//  - всё остальное — 30, и вверх мгновенно: поворот карты, масштаб, наклон
//    (DriveCamera.Smoother ещё догоняет цель), окно подхода к манёвру, первые
//    секунды после смены режима.
//
//  Голос и оповещения от частоты кадров не зависят вовсе: это только картинка.
//

import Foundation

nonisolated enum EngineFrames {

    /// Что происходит с картой сейчас.
    struct Situation: Equatable, Sendable {
        /// Человек сам двигает карту (жест, панорама в машине).
        var browsing = false
        /// Карта дорисована и стоит (mapViewDidBecomeIdle).
        var settled = false
        /// Накрыта полноэкранным оповещением или это приборка.
        var covered = false
        var performance: PerformanceMode = .full
        var lowPower = false
        /// Ведение в поездке: только в нём частота опускается на ровном ходу.
        var driving = false
        /// Ровный ход подтверждён (Pace): камера не доворачивает, манёвр
        /// далеко, режим давно не менялся.
        var steady = false
    }

    /// 0 — частота по умолчанию (движок сам выбирает, плавно для жестов).
    static func framesPerSecond(_ s: Situation) -> Int {
        // Карта стоит и дорисована — рисовать нечего, таймеру хватит
        // редкого такта: первое же движение вернёт полную частоту.
        if s.settled { return AppConfig.engineSettledFPS }
        if s.browsing { return s.performance == .full && !s.lowPower ? 0 : AppConfig.engineWarmFPS }
        // Под предупреждением о камере — как у горячего телефона: видна
        // лишь верхняя полоска карты сквозь окно.
        if s.covered { return AppConfig.engineHotFPS }
        switch s.performance {
        case .minimal: return AppConfig.engineHotFPS
        case .reduced: return AppConfig.engineWarmFPS
        case .full:
            if s.lowPower { return AppConfig.engineWarmFPS }
            return s.driving && s.steady ? AppConfig.engineSteadyFPS : AppConfig.engineFollowFPS
        }
    }

    // MARK: - Что считается «картинка меняется»

    /// Ход следящей камеры между двумя её шагами (обычно — фикс).
    struct CameraStep: Equatable, Sendable {
        /// Изменение масштаба, ступеней.
        var zoom: Double
        /// Изменение наклона, градусы.
        var pitch: Double
        /// Поворот карты, градусы (по модулю, кратчайший).
        var heading: Double
        /// Сколько прошло с прошлого шага, с.
        var seconds: Double
    }

    /// Камера заметно меняет картинку: доворачивает, приближает или
    /// наклоняет быстрее порогов. Скорость берётся не короче
    /// `engineSteadyStepFloorSeconds`: два шага в один кадр SwiftUI — не
    /// «поворот 40°/с», а один фикс.
    static func cameraBusy(_ step: CameraStep) -> Bool {
        let t = max(step.seconds, AppConfig.engineSteadyStepFloorSeconds)
        return abs(step.zoom) / t > AppConfig.engineSteadyZoomRate
            || abs(step.pitch) / t > AppConfig.engineSteadyPitchRate
            || abs(step.heading) / t > AppConfig.engineSteadyHeadingRate
    }

    /// Окно подхода к манёвру — то же, что у DriveCamera (скорость × 15 с,
    /// 150–450 м): там камера и так меняет масштаб и наклон, а у развилки
    /// водитель смотрит на карту внимательнее всего.
    static func nearManeuver(meters: Double?, speedMps: Double) -> Bool {
        guard let meters, meters.isFinite, meters >= 0 else { return false }
        let window = min(DriveCamera.maneuverWindowMax,
                         max(DriveCamera.maneuverWindowMin, max(0, speedMps) * DriveCamera.maneuverLeadSeconds))
        return meters <= window
    }

    /// Что из происходящего требует полной частоты прямо сейчас.
    struct Signals: Equatable, Sendable {
        var cameraBusy = false
        var maneuverMeters: Double?
        var speedMps: Double = 0
        /// Сколько секунд назад сменился режим карты (поездка, маршрут,
        /// окно оповещения, север/курс, возврат к машине); nil — давно.
        var sinceModeChange: Double?
        /// Идёт вход в ведение (одна дуга от обзора к машине).
        var entering = false
    }

    static func busy(_ s: Signals) -> Bool {
        if s.cameraBusy || s.entering { return true }
        if let since = s.sinceModeChange, since < AppConfig.engineSteadyModeSeconds { return true }
        return nearManeuver(meters: s.maneuverMeters, speedMps: s.speedMps)
    }

    /// Гистерезис вниз: ровный ход признаётся после `engineSteadyCalmSeconds`
    /// подряд без единого «занято»; любое «занято» — сразу назад к полной
    /// частоте. На пороге частота не мигает от одного шумного фикса.
    struct Pace: Sendable {
        private(set) var calmSince: Double?

        /// Ровный ли ход сейчас. `now` — секунды на любых монотонных часах.
        mutating func steady(busy: Bool, now: Double) -> Bool {
            if busy {
                calmSince = nil
                return false
            }
            let since = calmSince ?? now
            calmSince = since
            return now - since >= AppConfig.engineSteadyCalmSeconds
        }

        mutating func reset() { calmSince = nil }
    }
}
