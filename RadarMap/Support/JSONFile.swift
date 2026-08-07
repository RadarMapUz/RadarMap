//
//  JSONFile.swift
//  RadarMap
//
//  JSON-файлы в Documents: отсутствие файла — норма (первый запуск), молчим;
//  битые данные при чтении и любая ошибка записи — в лог: запись, которая
//  молча не прошла, — это потеря данных пользователя.
//

import Foundation
import os

// nonisolated: чистые файловые операции без состояния — зовутся и из
// @concurrent-кода (декодирование базы камер вне главного потока).
nonisolated enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL, log: Logger) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            log.error("чтение \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL, log: Logger) -> Bool {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            log.error("запись \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Удалить кэш. Отсутствие файла — норма, а вот отказ в удалении значит,
    /// что данные, которым мы перестали верить, останутся лежать: это в лог.
    static func remove(at url: URL, log: Logger) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("удаление \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
