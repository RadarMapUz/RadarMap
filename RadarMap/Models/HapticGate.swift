//
//  HapticGate.swift
//  RadarMap
//
//  Чем трясти сейчас: тактильный движок или системный отклик. Чистое
//  решение для AlertPlayer — покрыто HapticGateTests.
//
//  Раньше `haptic(level:)` синхронно звал `CHHapticEngine.start()` на
//  первом оповещении после простоя: 88–94 мс главного потока ровно в момент
//  оповещения, и голос о камере ждал вибрацию (отчёт качества 22.10, п. 1,
//  правило 21). Теперь движок запускается только асинхронно — заранее, на
//  подъезде, — а сигнал, пришедший раньше готовности, уходит системным
//  откликом немедленно. Вибрация не задерживает ни звук, ни голос ни при
//  каких условиях: худший исход — отклик попроще.
//

import Foundation

nonisolated struct HapticGate: Equatable, Sendable {

    /// Состояние движка, как его видит приложение.
    enum Engine: Equatable, Sendable {
        /// Железо без CoreHaptics (симулятор) или движок не создался.
        case absent
        /// Создан, но не запущен (или остановлен системой).
        case stopped
        /// Асинхронный запуск в пути.
        case starting
        /// Запущен — узор играется сразу.
        case running
    }

    /// Чем ответить на сигнал прямо сейчас.
    enum Feel: Equatable, Sendable {
        /// Вибрация выключена в настройках.
        case none
        /// Узор тактильного движка (мягкий → резкий по уровню).
        case engine
        /// Системный отклик (UIImpactFeedbackGenerator) — немедленно.
        case system
    }

    private(set) var engine: Engine
    /// Когда последний раз просили запуск: не повторять его каждый фикс.
    private(set) var lastStartRequest: Date?

    init(engine: Engine) {
        self.engine = engine
    }

    /// Ответ на сигнал. Никогда не ждёт движок: не запущен — системный
    /// отклик сразу (запуск, если нужен, — отдельно, через `shouldStart`).
    func feel(enabled: Bool) -> Feel {
        guard enabled else { return .none }
        return engine == .running ? .engine : .system
    }

    /// Просить ли асинхронный запуск сейчас: движок есть, стоит, и прошлый
    /// запрос был не позже `AppConfig.hapticEngineRetrySeconds` назад.
    func shouldStart(now: Date) -> Bool {
        guard engine == .stopped else { return false }
        guard let last = lastStartRequest else { return true }
        return now.timeIntervalSince(last) >= AppConfig.hapticEngineRetrySeconds
    }

    mutating func startRequested(at now: Date) {
        guard engine != .absent else { return }
        engine = .starting
        lastStartRequest = now
    }

    /// Чем кончился асинхронный запуск.
    mutating func startFinished(ok: Bool) {
        guard engine != .absent else { return }
        engine = ok ? .running : .stopped
    }

    /// Система остановила движок. Простой под `isAutoShutdownEnabled`
    /// (`idleTimeout`) — не остановка для нас: такой движок сам поднимет
    /// железо на следующем узоре (CHHapticEngine.h). Не поднимет — узор
    /// бросит ошибку, и `playFailed` вернёт нас к запуску.
    mutating func stopped(idleTimeout: Bool) {
        guard engine != .absent else { return }
        engine = idleTimeout ? .running : .stopped
    }

    /// Сброс сервера движка: запускать заново, не дожидаясь паузы повтора.
    mutating func reset() {
        guard engine != .absent else { return }
        engine = .stopped
        lastStartRequest = nil
    }

    /// Узор на «запущенном» движке не сыграл: считать движок стоящим.
    mutating func playFailed() {
        guard engine != .absent else { return }
        engine = .stopped
    }

    /// Прогревать ли движок: камера уже близко к радиусу оповещения.
    static func shouldWarm(distance: Double, radius: Double) -> Bool {
        distance <= radius * AppConfig.hapticWarmRadiusFactor
    }
}
