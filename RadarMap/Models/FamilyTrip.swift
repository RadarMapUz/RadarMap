//
//  FamilyTrip.swift
//  RadarMap
//
//  Поездка глазами близких (22.1, 22.4) — чистый автомат: что отправить и
//  кому закрыть на старте, на каждом фиксе, на паузе и в конце поездки.
//  Сервис (FamilyShareService) только исполняет его действия — сеть, ключи,
//  очередь — и сообщает, что доставлено. Так сценарии «пассажир», «магазин
//  по пути», «приехал сам у цели», «таксист после смены» проверяются тестом
//  целиком (FamilyScenarioTests), без CLLocationManager и сети.
//

import Foundation

nonisolated struct FamilyTrip: Equatable, Sendable {
    /// Что сделать с близким.
    enum Action: Hashable, Sendable {
        /// «В пути» (время или nil — «едет домой»).
        case drive(UUID, arrival: Date?, home: Bool)
        /// «Дома» или «сейчас не в пути».
        case close(UUID, EtaShare.Status, home: Bool)
    }

    /// Пауза на эту поездку (один тап).
    private(set) var pausedThisTrip = false
    /// «Еду домой» в этой поездке.
    private(set) var driverSaidHome = false
    /// Поездка сейчас — домой (по любому из признаков).
    private(set) var headingHome = false
    /// Автостоп не у дома: до этого момента ждём склейки.
    private(set) var holdUntil: Date?
    /// Поездка началась; склеил ли её TripMerge — узнаем на первом update.
    private(set) var pendingStart = false
    /// Доставленное «в пути» — по близкому.
    private(set) var sent: [UUID: FamilyShare.Sent] = [:]
    /// «В пути», ответ на которое ещё не пришёл.
    private(set) var inFlight: Set<UUID> = []
    /// Не дошло: подряд неудач и когда пробовать снова — по близкому.
    private(set) var failures: [UUID: Int] = [:]
    private(set) var retryAt: [UUID: Date] = [:]

    /// Кому ссылка сейчас открыта: доставлено или в пути.
    var open: Set<UUID> { Set(sent.keys).union(inFlight) }
    /// Кто видит сейчас (доставлено).
    var live: Set<UUID> { Set(sent.keys) }

    mutating func tripStarted() {
        pendingStart = true
    }

    /// Фикс или любое изменение, которое может поменять, кому видно.
    mutating func update(_ circle: FamilyCircle, context: FamilyShare.Context, now: Date) -> [Action] {
        guard context.isTripActive else {
            // Между поездками ждём склейки; срок вышел — «не в пути».
            if let holdUntil, now > holdUntil { return finishHold() }
            return []
        }
        var actions: [Action] = []
        if pendingStart { actions += resolveStart(context, now: now) }
        headingHome = FamilyShare.headingHome(context, driverSaidHome: driverSaidHome)
        let visible = FamilyShare.live(circle, isTripActive: true, isPassenger: context.isPassenger,
                                       pausedThisTrip: pausedThisTrip, headingHome: headingHome, now: now)
        let ids = Set(visible.map(\.id))
        for id in Self.ordered(open) where !ids.contains(id) {
            actions.append(close(id, .ended))
        }
        guard !visible.isEmpty else { return actions }
        let arrival = FamilyShare.arrival(context, headingHome: headingHome, now: now)
        for recipient in visible where !inFlight.contains(recipient.id)
            && retryAt[recipient.id].map({ now >= $0 }) ?? true
            && FamilyShare.shouldSend(last: sent[recipient.id], arrival: arrival, home: headingHome, now: now) {
            inFlight.insert(recipient.id)
            actions.append(.drive(recipient.id, arrival: arrival, home: headingHome))
        }
        return actions
    }

    /// «В пути» доставлено.
    mutating func delivered(_ id: UUID, arrival: Date?, home: Bool, at: Date) {
        guard inFlight.remove(id) != nil else { return }   // закрыли, пока шёл ответ
        sent[id] = FamilyShare.Sent(arrival: arrival, home: home, at: at)
        failures[id] = nil
        retryAt[id] = nil
    }

    /// «В пути» не дошло — update попробует снова после паузы
    /// (`familyRetrySeconds`, вдвое за каждую неудачу подряд).
    mutating func failed(_ id: UUID, now: Date) {
        guard inFlight.remove(id) != nil else { return }   // закрыли, пока шёл ответ
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        retryAt[id] = now.addingTimeInterval(Self.retryDelay(afterFailures: count))
    }

    /// Пауза перед повтором после `count` неудач подряд.
    static func retryDelay(afterFailures count: Int) -> TimeInterval {
        let doubled = AppConfig.familyRetrySeconds * pow(2, Double(max(0, min(count, 8) - 1)))
        return min(doubled, AppConfig.familyRetryMaxSeconds)
    }

    /// Пауза в один тап — на эту поездку, для всех.
    mutating func pause() -> [Action] {
        pausedThisTrip = true
        return closeAll(.ended)
    }

    mutating func goingHome() {
        driverSaidHome = true
    }

    /// Закрыть всех, у кого открыто («пауза до завтра», пульт).
    mutating func closeAll(_ status: EtaShare.Status) -> [Action] {
        Self.ordered(open).map { close($0, status) }
    }

    /// Близкого убирают или меняют ему ссылку: забыть, что ему слали; что ушло
    /// последним — «домой» или нет (для прощального «не в пути»).
    mutating func forget(_ id: UUID) -> Bool {
        let home = sent[id]?.home ?? true
        sent[id] = nil
        inFlight.remove(id)
        failures[id] = nil
        retryAt[id] = nil
        return home
    }

    /// Конец поездки: дома — «дома», «Стоп» и пассажир — «не в пути»,
    /// автостоп в другом месте — ждём склейки (FamilyShare.endAction).
    mutating func tripEnded(_ end: NavigationFlow.TripEnd, arrivedHome: Bool, now: Date) -> [Action] {
        pendingStart = false
        switch FamilyShare.endAction(end, arrivedHome: arrivedHome) {
        case .close(let status):
            holdUntil = nil
            let actions = closeAll(status)
            reset()
            return actions
        case .hold:
            guard !open.isEmpty || pausedThisTrip || driverSaidHome else {
                reset()
                return []
            }
            holdUntil = now.addingTimeInterval(AppConfig.familyHoldSeconds)
            return []
        }
    }

    /// Ожидание склейки вышло (таймер сервиса или update вне поездки).
    mutating func finishHold() -> [Action] {
        holdUntil = nil
        let actions = closeAll(.ended)
        reset()
        return actions
    }

    // MARK: - Внутреннее

    /// Первый update новой поездки: склеил TripMerge и ожидание не вышло —
    /// та же поездка (пауза, «Еду домой», открытые ссылки остаются); иначе
    /// прошлую — «не в пути», и всё с чистого листа.
    private mutating func resolveStart(_ context: FamilyShare.Context, now: Date) -> [Action] {
        pendingStart = false
        var actions: [Action] = []
        if holdUntil != nil {
            let resumed = FamilyShare.resumesHeld(holdUntil: holdUntil, isContinuation: context.isContinuation,
                                                  now: now)
            holdUntil = nil
            if resumed { return [] }
            actions = closeAll(.ended)
        }
        reset()
        return actions
    }

    private mutating func close(_ id: UUID, _ status: EtaShare.Status) -> Action {
        let home = forget(id)
        return .close(id, status, home: home)
    }

    private mutating func reset() {
        pausedThisTrip = false
        driverSaidHome = false
        headingHome = false
    }

    /// Порядок действий — стабильный: тест и очередь не зависят от хэша Set.
    private static func ordered(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.uuidString < $1.uuidString }
    }
}
