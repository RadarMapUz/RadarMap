//
//  ControlBridge.swift
//  RadarMap
//
//  Кнопки Пункта управления ↔ приложение. Где выполнится намерение кнопки,
//  решает система: `LiveActivityIntent` обычно идёт в процесс приложения, а
//  если система запустит его в расширении, логики отметки там нет. Тогда
//  команда уходит через App Group и уведомление Darwin: в поездке приложение
//  живо в фоне и выполнит её, а вне поездки отметка всё равно не нужна.
//  В другую сторону — зеркало «идёт поездка» и «звук выключен» для значения
//  переключателей. Чистое решение о свежести — ControlBridgeTests.
//

#if os(iOS)
import Foundation

nonisolated enum ControlBridge {
    static let tripKind = "uz.radarmap.ios.start-trip"
    static let soundKind = "uz.radarmap.ios.sound"

    enum Command: String, Equatable, Sendable {
        case report, soundOn, soundOff

        var action: ActivityAction {
            switch self {
            case .report: return .report
            case .soundOn: return .setSound(on: true)
            case .soundOff: return .setSound(on: false)
            }
        }
    }

    static let darwinName = "uz.radarmap.ios.control"
    static let commandKey = "control.command"
    static let commandAtKey = "control.commandAt"
    static let tripActiveKey = "control.tripActive"
    static let mutedKey = "control.muted"
    /// Старше — нажатие уже не про это место: «Радар!» встал бы не там.
    static let maxAge: TimeInterval = 10

    /// Команда из контейнера, только свежая.
    static func fresh(raw: String?, at: Date?, now: Date) -> Command? {
        guard let raw, let at, now >= at, now.timeIntervalSince(at) <= maxAge else { return nil }
        return Command(rawValue: raw)
    }

    static var tripActive: Bool { SharedDefaults.store?.bool(forKey: tripActiveKey) ?? false }
    static var muted: Bool { SharedDefaults.store?.bool(forKey: mutedKey) ?? false }

    /// Записать значение; true — оно сменилось и кнопку надо перерисовать.
    static func mirror(_ value: Bool, key: String) -> Bool {
        guard let store = SharedDefaults.store else { return false }
        guard store.object(forKey: key) == nil || store.bool(forKey: key) != value else { return false }
        store.set(value, forKey: key)
        return true
    }

    static func send(_ command: Command) {
        guard let store = SharedDefaults.store else { return }
        store.set(command.rawValue, forKey: commandKey)
        store.set(Date(), forKey: commandAtKey)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(darwinName as CFString), nil, nil, true)
    }

    /// Забрать команду; следующий сигнал её не повторит.
    static func take(now: Date = Date()) -> Command? {
        guard let store = SharedDefaults.store else { return nil }
        let command = fresh(raw: store.string(forKey: commandKey),
                            at: store.object(forKey: commandAtKey) as? Date, now: now)
        store.removeObject(forKey: commandKey)
        store.removeObject(forKey: commandAtKey)
        return command
    }

    /// Приложение слушает нажатия, выполненные в расширении.
    static func listen() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            guard let command = ControlBridge.take() else { return }
            Task { @MainActor in await ActivityActions.run(command.action) }
        }, darwinName as CFString, nil, .deliverImmediately)
    }

    /// Выполнить здесь (мы в приложении) или передать приложению (мы в расширении).
    @MainActor
    static func run(_ command: Command) async {
        if ActivityActions.perform != nil {
            await ActivityActions.run(command.action)
        } else {
            send(command)
        }
    }
}
#endif
