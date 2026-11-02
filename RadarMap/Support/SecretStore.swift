//
//  SecretStore.swift
//  RadarMap
//
//  Секреты телефона — в связке ключей, не в UserDefaults: plist настроек
//  лежит в резервной копии открытым, а запись связки там зашифрована ключом
//  устройства (аудит 38B, L-9). Протокол — ради подмены в тесте миграции
//  (ARCHITECTURE, правило 2): тест проверяет, что сбой связки не теряет ключ.
//

import Foundation
import Security

nonisolated protocol SecretStore: Sendable {
    /// nil — записи нет; ошибка — связка недоступна (это НЕ «записи нет»).
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

nonisolated struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "OSStatus \(status)" }
}

nonisolated struct KeychainSecretStore: SecretStore {
    let service: String

    func read(account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return secret
    }

    func write(_ secret: String, account: String) throws {
        // После первой разблокировки: близкие получают «в пути» из фона, при
        // погашенном экране. «ThisDeviceOnly» не ставим: зашифрованная копия
        // при переезде на новый телефон должна унести ссылки близких с собой.
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = base(account).merging(attributes) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // В iCloud-связку не уходит: ключи ссылок живут только на телефоне.
            kSecAttrSynchronizable as String: false,
        ]
    }
}
