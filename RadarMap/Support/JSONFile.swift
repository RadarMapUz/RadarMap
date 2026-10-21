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

    /// Чтение с честным ответом: «файла нет» (первый запуск — норма) и «файл
    /// есть, но прочесть нельзя» — РАЗНЫЕ вещи. Второе было тем же nil, и
    /// следующая запись затирала данные человека пустым списком (сценарий S9,
    /// 20.10): например, процесс подняли в фоне до первой разблокировки после
    /// перезагрузки, файл защищён, — и история за месяцы уходила молча.
    enum LoadResult<T> {
        case missing
        case loaded(T)
        /// Файл есть, но не читается (защита до разблокировки, ввод-вывод) —
        /// ничего не писать, попробовать позже.
        case unreadable(Error)
        /// Прочитан, но не разбирается — отложить в сторону, не затирать.
        case corrupt(Error)
    }

    static func loadChecked<T: Decodable>(_ type: T.Type, from url: URL, log: Logger) -> LoadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("чтение \(url.lastPathComponent, privacy: .public): файл есть, но не читается — \(error.localizedDescription, privacy: .public)")
            return .unreadable(error)
        }
        do {
            return .loaded(try JSONDecoder().decode(T.self, from: data))
        } catch {
            log.fault("чтение \(url.lastPathComponent, privacy: .public): не разбирается — \(error.localizedDescription, privacy: .public)")
            return .corrupt(error)
        }
    }

    /// Отложить файл в сторону рядом: `trips.corrupt-1800000000.json`. Данные
    /// человека не перезаписываются — их можно вернуть или разобрать. `copy` —
    /// оставить и сам файл (часть записей прочиталась, файл ещё живой).
    @discardableResult
    static func setAside(_ url: URL, copy: Bool = false, log: Logger) -> Bool {
        let aside = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension(url.pathExtension)
        do {
            if copy {
                try FileManager.default.copyItem(at: url, to: aside)
            } else {
                try FileManager.default.moveItem(at: url, to: aside)
            }
            log.notice("\(url.lastPathComponent, privacy: .public) отложен в \(aside.lastPathComponent, privacy: .public)")
            return true
        } catch {
            log.error("\(url.lastPathComponent, privacy: .public) не отложен: \(error.localizedDescription, privacy: .public)")
            return false
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

    /// Произвольная работа с файлами в той же очереди — ПОСЛЕ всех записей,
    /// поставленных раньше. История по месяцам (TripStore) пишет несколько
    /// файлов одним шагом (месяцы, потом индекс) и читает месяц, который
    /// мог только что уйти в запись: чтение мимо очереди увидело бы старый
    /// файл, и следующая запись вернула бы стёртое.
    static func enqueue(wait: Bool, _ work: @escaping @Sendable () -> Void) {
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    /// То же с ответом — из async-кода, не занимая поток пула ожиданием.
    static func ordered<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume(returning: work()) }
        }
    }

    /// Синхронно, с главного потока — только для редкого пути, где ответ
    /// нужен прямо сейчас (подхват месяца перед записью, TripStats.persist).
    /// Из самой очереди не звать: это взаимная блокировка.
    static func orderedSync<T>(_ work: () -> T) -> T {
        writer.sync(execute: work)
    }

    /// Удалить файл в той же очереди, что и saveOrdered, — ПОСЛЕ всех записей,
    /// поставленных раньше: «сначала записать то, во что файл вошёл, потом его
    /// удалить» без ожидания записи на главном потоке (ревью S9).
    static func removeOrdered(at url: URL, log: Logger) {
        writer.async { remove(at: url, log: log) }
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

/// Массив, который читается поэлементно: одна битая запись не уносит с
/// собой весь файл (сценарий S9, 20.10). Сколько выброшено — в `dropped`.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let dropped: Int
    /// Первая причина отказа — в журнал (сколько и почему).
    let firstError: String?

    /// Принимает любое значение, ничего не читая: так разбор переходит к
    /// следующему элементу после битого.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        var firstError: String?
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                if firstError == nil { firstError = String(describing: error) }
                // Битый элемент — пропустить, не останавливая разбор. Не
                // пропускается — дальше не прочесть (и не зациклиться).
                guard (try? container.decode(Skip.self)) != nil else { break }
                dropped += 1
            }
        }
        self.elements = elements
        self.dropped = dropped
        self.firstError = firstError
    }
}
