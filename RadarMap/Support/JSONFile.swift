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

    /// Запись вне вызывающего потока, строго по порядку вызовов.
    ///
    /// История поездок (до полусотни записей с треками, сотни килобайт JSON)
    /// кодировалась и писалась синхронно на главном — в конце поездки ровно в
    /// момент появления карточки «Поездка сохранена», и на каждом «штраф
    /// пришёл», удалении, склейке (аудит 11.10). Последовательная очередь
    /// сохраняет порядок: более старая запись не может лечь поверх новой.
    /// `wait` — дождаться и этой записи, и всех прежних в очереди: так пишет
    /// приложение в фоне, где его могут приостановить с недописанной очередью.
    static func saveOrdered<T: Encodable & Sendable>(_ value: T, to url: URL, log: Logger,
                                                     wait: Bool) {
        let work: @Sendable () -> Void = { _ = save(value, to: url, log: log) }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    private static let writer = DispatchQueue(label: "uz.radarmap.json-writer", qos: .utility)

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
