//
//  CloudSettingsSync.swift
//  RadarMap
//
//  Настройки через iCloud (27.F, NSUbiquitousKeyValueStore) — чистые
//  решения: что отправить, что применить, что делать при первом включении.
//
//  Хранилище настроек iCloud — «последний записавший прав» по ключу, и это
//  годится: настройка — одно значение, а не история. Уходят только
//  поведенческие настройки из белого списка (AppSettings.cloudSettingKinds);
//  то, что принадлежит этому телефону (Bluetooth машины, регистратор,
//  госномер, источник голоса), остаётся здесь. Места и машина — не здесь:
//  в них координаты и цены, они едут в CloudKit зашифрованными.
//

import Foundation

nonisolated enum CloudSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case double(Double)
    case string(String)
}

nonisolated enum CloudSettingsSync {
    enum Kind: Sendable { case bool, double, string }

    /// Ключ в хранилище iCloud: свой префикс, чтобы ключ системы или
    /// будущей функции не перепутался с настройкой.
    static let prefix = "settings."

    /// Свои значения, которые ещё не отправлены (или изменились после).
    static func toPush(local: [String: CloudSettingValue],
                       pushed: [String: CloudSettingValue]) -> [String: CloudSettingValue] {
        local.filter { pushed[$0.key] != $0.value }
    }

    /// Пришедшие значения, которых у себя нет.
    static func toApply(remote: [String: CloudSettingValue],
                        local: [String: CloudSettingValue]) -> [String: CloudSettingValue] {
        remote.filter { local[$0.key] != $0.value }
    }

    /// Первое включение на этом телефоне. В iCloud уже что-то есть — это
    /// прежний телефон: его настройки применяются (восстановление), а свои
    /// отправляются только там, где в iCloud пусто. Пусто совсем — этот
    /// телефон первый, его настройки и уезжают.
    static func initial(local: [String: CloudSettingValue], remote: [String: CloudSettingValue])
        -> (apply: [String: CloudSettingValue], push: [String: CloudSettingValue]) {
        guard !remote.isEmpty else { return ([:], local) }
        return (toApply(remote: remote, local: local), local.filter { remote[$0.key] == nil })
    }

    /// Значение из хранилища по ожидаемому виду; чужой вид — nil.
    static func value(from object: Any?, kind: Kind) -> CloudSettingValue? {
        switch kind {
        case .bool:
            guard let number = object as? NSNumber else { return nil }
            return .bool(number.boolValue)
        case .double:
            guard let number = object as? NSNumber else { return nil }
            return .double(number.doubleValue)
        case .string:
            return (object as? String).map { .string($0) }
        }
    }

    /// Значение для хранилища.
    static func object(_ value: CloudSettingValue) -> Any {
        switch value {
        case .bool(let flag): return flag
        case .double(let number): return number
        case .string(let text): return text
        }
    }
}
