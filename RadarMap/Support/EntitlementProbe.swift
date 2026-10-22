//
//  EntitlementProbe.swift
//  RadarMap
//
//  Какие права (entitlements) реально вшиты в подпись этой сборки (27.F).
//
//  Зачем. `CKContainer(identifier:)` с контейнером, которого нет в правах
//  приложения, не возвращает ошибку — он роняет процесс исключением
//  Objective-C, которое Swift не ловит. Права же зависят от того, с каким
//  профилем собрали: владелец ещё не включил iCloud в профиле, Xcode Cloud
//  подписал без него, кто-то вычистил ключ из .entitlements — и хранение в
//  iCloud обязано честно сказать «недоступно в этой сборке», а не уронить
//  приложение при открытии настроек.
//
//  Как. Права лежат в самом исполняемом файле: на устройстве — XML-блоб в
//  подписи (LC_CODE_SIGNATURE → SuperBlob → блоб 0xfade7171, то же читает
//  `codesign -d --entitlements`), в симуляторе — секция __TEXT,__entitlements.
//  Читаются заголовок и эти два куска, а не весь файл (в Release он
//  десятки мегабайт). Ничего приватного: свой файл, открытый формат Mach-O.
//

import Foundation
import os

nonisolated enum EntitlementProbe {
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"

    /// Контейнеры iCloud с CloudKit в подписи этой сборки; nil — подпись не
    /// прочитана (тогда CloudKit не трогаем).
    static func cloudKitContainers(executable: URL? = Bundle.main.executableURL) -> [String]? {
        guard let executable, let entitlements = entitlements(executable: executable) else { return nil }
        let services = entitlements[servicesKey] as? [String] ?? []
        guard services.contains("CloudKit") || services.contains("CloudKit-Anonymous") else { return [] }
        return entitlements[containersKey] as? [String] ?? []
    }

    /// Права исполняемого файла.
    static func entitlements(executable: URL) -> [String: Any]? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: executable)
        } catch {
            Log.cloud.error("права сборки: файл не открылся — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        defer {
            do { try handle.close() } catch {
                Log.cloud.error("права сборки: файл не закрылся — \(error.localizedDescription, privacy: .public)")
            }
        }
        return parse { offset, length in
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: length)
            } catch {
                Log.cloud.error("права сборки: чтение \(length, privacy: .public) байт — \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: - Разбор Mach-O

    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let machMagic64: UInt32 = 0xfeed_facf
    private static let cpuARM64: UInt32 = 0x0100_000c
    private static let segment64: UInt32 = 0x19
    private static let codeSignature: UInt32 = 0x1d
    private static let superBlobMagic: UInt32 = 0xfade_0cc0
    private static let entitlementsMagic: UInt32 = 0xfade_7171
    /// Потолок на размер куска — от битого файла с огромной длиной.
    private static let maxChunk = 4 << 20

    /// Разбор по функции чтения (смещение, длина) → байты: тест подаёт
    /// собранный в памяти файл.
    static func parse(read: (Int, Int) -> Data?) -> [String: Any]? {
        guard let head = read(0, 8), let magic = head.uint32(at: 0, bigEndian: true) else { return nil }
        var base = 0
        if magic == fatMagic {
            // Универсальный файл: берём срез arm64.
            guard let count = head.uint32(at: 4, bigEndian: true), count < 32,
                  let archs = read(8, Int(count) * 20) else { return nil }
            var found: Int?
            for index in 0..<Int(count) {
                let at = index * 20
                if archs.uint32(at: at, bigEndian: true) == cpuARM64,
                   let offset = archs.uint32(at: at + 8, bigEndian: true) {
                    found = Int(offset)
                }
            }
            guard let found else { return nil }
            base = found
        }
        guard let header = read(base, 32), header.uint32(at: 0) == machMagic64,
              let commands = header.uint32(at: 16), let size = header.uint32(at: 20),
              Int(size) <= maxChunk, let loads = read(base + 32, Int(size)) else { return nil }
        var offset = 0
        var section: (Int, Int)?
        var signature: (Int, Int)?
        for _ in 0..<commands {
            guard let cmd = loads.uint32(at: offset), let cmdSize = loads.uint32(at: offset + 4),
                  cmdSize >= 8 else { return nil }
            if cmd == segment64, let sections = loads.uint32(at: offset + 64) {
                for index in 0..<Int(sections) {
                    let at = offset + 72 + index * 80
                    if loads.cString(at: at, length: 16) == "__entitlements",
                       loads.cString(at: at + 16, length: 16) == "__TEXT",
                       let length = loads.uint64(at: at + 40), let fileOffset = loads.uint32(at: at + 48) {
                        section = (Int(fileOffset), Int(length))
                    }
                }
            } else if cmd == codeSignature, let dataOffset = loads.uint32(at: offset + 8),
                      let dataSize = loads.uint32(at: offset + 12) {
                signature = (Int(dataOffset), Int(dataSize))
            }
            offset += Int(cmdSize)
        }
        // Симулятор: права в секции (подпись там пустая, ad hoc).
        if let (at, length) = section, length > 0, length <= maxChunk,
           let data = read(base + at, length), let plist = plist(data), !plist.isEmpty {
            return plist
        }
        guard let (at, length) = signature, length <= maxChunk,
              let blob = read(base + at, length) else { return section == nil ? nil : [:] }
        return entitlements(superBlob: blob) ?? [:]
    }

    /// XML-права из SuperBlob подписи (поля — big-endian).
    static func entitlements(superBlob blob: Data) -> [String: Any]? {
        guard blob.uint32(at: 0, bigEndian: true) == superBlobMagic,
              let count = blob.uint32(at: 8, bigEndian: true), count < 64 else { return nil }
        for index in 0..<Int(count) {
            guard let offset = blob.uint32(at: 12 + index * 8 + 4, bigEndian: true) else { return nil }
            let at = Int(offset)
            guard blob.uint32(at: at, bigEndian: true) == entitlementsMagic,
                  let length = blob.uint32(at: at + 4, bigEndian: true),
                  Int(length) >= 8, at + Int(length) <= blob.count else { continue }
            let start = blob.startIndex + at + 8
            return plist(blob.subdata(in: start..<(blob.startIndex + at + Int(length))))
        }
        return nil
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        do {
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        } catch {
            Log.cloud.error("права сборки не разобрались: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private extension Data {
    nonisolated func uint32(at offset: Int, bigEndian: Bool = false) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            let byte = UInt32(self[startIndex + offset + index])
            value |= bigEndian ? byte << (8 * (3 - index)) : byte << (8 * index)
        }
        return value
    }

    nonisolated func uint64(at offset: Int) -> UInt64? {
        guard let low = uint32(at: offset), let high = uint32(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    nonisolated func cString(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let bytes = self[(startIndex + offset)..<(startIndex + offset + length)].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .ascii)
    }
}
