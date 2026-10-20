//
//  TileDigestIndex.swift
//  RadarMap
//
//  Подписанный индекс тайлов в компактном виде — вместо словаря на 165 тысяч
//  строк.
//
//  Зачем. Телеметрия с боевого телефона показала 73 отстрела приложения по
//  памяти за 40 суток и пик 755 МБ (`crash_carplay_memory.md`). Один из
//  крупных постояльцев — этот индекс: `mvt_index.json` весит **23,5 МБ и
//  содержит 165 054 записи**, и `EngineTileGuard` держал его разобранным в
//  `[String: Meta]` всё время работы приложения.
//
//  Что стоил прежний вид:
//
//    • резидентно — словарь на 165 тыс. ключей-строк, в каждом значении
//      64-символьный hex. Порядка 30–40 МБ, и выгрузки не было нигде;
//    • на КАЖДОМ запуске — транзиентный пик разбора: 23,5 МБ ответа, из него
//      base64-строка того же размера, из неё ещё 17,6 МБ данных, и только
//      потом словарь. Около сотни мегабайт, и так каждый холодный старт —
//      в том числе тот, который делает подключение CarPlay;
//    • на КАЖДЫЙ тайл — 32 вызова `String(format:)` с последующей склейкой,
//      чтобы получить hex и сравнить его со строкой из словаря.
//
//  Что здесь вместо этого:
//
//    • ключ тайла «15/22686/12247» пакуется в одно `UInt64`. Строк нет вовсе;
//    • дайджест хранится 32 сырыми байтами в одном непрерывном буфере, а не
//      64-символьной строкой в куче;
//    • ключи отсортированы, поиск — двоичный;
//    • поле `bytes` из JSON выброшено: оно декодировалось и не читалось нигде.
//
//  Резидентно выходит 165 054 × (8 + 32) ≈ **6,6 МБ** вместо 30–40.
//
//  Сравнение с дайджестом идёт по БАЙТАМ, без перевода в hex: на тайл это
//  экономит тридцать две аллокации, а на экране их сотни.
//
//  Чистая структура без сети и файловой системы — покрыта TileDigestIndexTests.
//

import Foundation

nonisolated struct TileDigestIndex: Sendable {

    /// Длина sha256 в байтах.
    static let digestLength = 32

    /// Версия индекса, как её подписал владелец.
    let version: Int
    /// Упакованные ключи тайлов, ОТСОРТИРОВАНЫ по возрастанию.
    private let keys: [UInt64]
    /// Дайджесты подряд: `digests[i * 32 ..< (i + 1) * 32]` принадлежит `keys[i]`.
    private let digests: [UInt8]

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    // MARK: - Ключ тайла

    /// «15/22686/12247» → одно число.
    ///
    /// Восемь бит на зум и по двадцать четыре на координату: этого хватает до
    /// зума 24, а собираем мы 11-й и 15-й. Всё, что не укладывается, честно
    /// возвращает nil — молча свернуть чужой ключ в чужое число здесь нельзя,
    /// на этих числах стоит допуск геометрии на экран.
    static func packed(_ tileKey: String) -> UInt64? {
        var z = 0, x = 0, y = 0, field = 0, digits = 0
        for byte in tileKey.utf8 {
            if byte == UInt8(ascii: "/") {
                guard digits > 0 else { return nil }
                field += 1
                digits = 0
                if field > 2 { return nil }
                continue
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let value = Int(byte - UInt8(ascii: "0"))
            digits += 1
            guard digits <= 8 else { return nil }
            switch field {
            case 0:  z = z * 10 + value
            case 1:  x = x * 10 + value
            default: y = y * 10 + value
            }
        }
        guard field == 2, digits > 0 else { return nil }
        return packed(z: z, x: x, y: y)
    }

    static func packed(z: Int, x: Int, y: Int) -> UInt64? {
        guard (0...24).contains(z), (0..<(1 << 24)).contains(x), (0..<(1 << 24)).contains(y)
        else { return nil }
        return (UInt64(z) << 48) | (UInt64(x) << 24) | UInt64(y)
    }

    // MARK: - Сборка из подписанного JSON

    /// `tiles` — то, что пришло в подписанном индексе: ключ тайла → hex sha256.
    /// Записи с непонятным ключом или неверной длиной дайджеста пропускаются:
    /// такой тайл просто не найдётся, и сторож его не пропустит. Это ровно та
    /// сторона отказа, которая нужна.
    init(version: Int, tiles: [String: String]) {
        var pairs: [(UInt64, [UInt8])] = []
        pairs.reserveCapacity(tiles.count)
        for (key, hex) in tiles {
            guard let packed = Self.packed(key), let bytes = Self.bytes(fromHex: hex) else { continue }
            pairs.append((packed, bytes))
        }
        pairs.sort { $0.0 < $1.0 }
        var keys = [UInt64](); keys.reserveCapacity(pairs.count)
        var digests = [UInt8](); digests.reserveCapacity(pairs.count * Self.digestLength)
        for (key, bytes) in pairs {
            keys.append(key)
            digests.append(contentsOf: bytes)
        }
        self.version = version
        self.keys = keys
        self.digests = digests
    }

    private init(version: Int, keys: [UInt64], digests: [UInt8]) {
        self.version = version
        self.keys = keys
        self.digests = digests
    }

    /// 64 hex-символа → 32 байта. nil на любой неправильности.
    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.utf8.count == digestLength * 2 else { return nil }
        var out = [UInt8](); out.reserveCapacity(digestLength)
        var high: UInt8?
        for character in hex.utf8 {
            let nibble: UInt8
            switch character {
            case 0x30...0x39: nibble = character - 0x30           // 0–9
            case 0x61...0x66: nibble = character - 0x61 + 10      // a–f
            case 0x41...0x46: nibble = character - 0x41 + 10      // A–F
            default: return nil
            }
            if let value = high {
                out.append(value << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? out : nil
    }

    // MARK: - Поиск

    /// Совпадает ли дайджест тайла с подписанным. Сравнение по байтам: перевод
    /// в hex ради сравнения — тридцать две аллокации на тайл, а тайлов на
    /// экране сотни.
    func matches<Digest: Collection>(tileKey: String, digest: Digest) -> Bool
    where Digest.Element == UInt8 {
        guard digest.count == Self.digestLength,
              let packed = Self.packed(tileKey),
              let index = slot(of: packed) else { return false }
        let start = index * Self.digestLength
        var offset = start
        for byte in digest {
            if digests[offset] != byte { return false }
            offset += 1
        }
        return true
    }

    /// Есть ли такой тайл в подписанном индексе. Тайл вне индекса — отказ:
    /// либо индекс не тот, либо сервер отдаёт то, чего владелец не подписывал.
    func contains(tileKey: String) -> Bool {
        guard let packed = Self.packed(tileKey) else { return false }
        return slot(of: packed) != nil
    }

    private func slot(of key: UInt64) -> Int? {
        var low = 0, high = keys.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let value = keys[middle]
            if value == key { return middle }
            if value < key { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    // MARK: - Хранение на диске

    /// Магия файла: четыре байта «RMTI» и номер формата. Чужой или устаревший
    /// файл отбрасывается целиком, а не разбирается «как получится».
    private static let magic: [UInt8] = [0x52, 0x4D, 0x54, 0x49]   // RMTI
    private static let format: UInt8 = 1
    /// magic(4) + format(1) + version(8) + count(4)
    private static let headerLength = 17

    func serialized() -> Data {
        var out = Data(capacity: Self.headerLength + keys.count * (8 + Self.digestLength))
        out.append(contentsOf: Self.magic)
        out.append(Self.format)
        withUnsafeBytes(of: Int64(version).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(keys.count).littleEndian) { out.append(contentsOf: $0) }
        for key in keys {
            withUnsafeBytes(of: key.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: digests)
        return out
    }

    /// Разбор с диска. nil на любой неисправности — обрезанный файл, чужая
    /// магия, несошедшаяся длина: тогда индекс качается заново, а не
    /// используется наполовину.
    init?(serialized data: Data) {
        guard data.count >= Self.headerLength else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == Self.magic, bytes[4] == Self.format else { return nil }
        let version = bytes[5..<13].withUnsafeBytes { Int(Int64(littleEndian: $0.loadUnaligned(as: Int64.self))) }
        let count = Int(bytes[13..<17].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        let expected = Self.headerLength + count * (8 + Self.digestLength)
        guard count >= 0, bytes.count == expected else { return nil }

        var keys = [UInt64](); keys.reserveCapacity(count)
        var offset = Self.headerLength
        for _ in 0..<count {
            let key = bytes[offset..<(offset + 8)].withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
            }
            keys.append(key)
            offset += 8
        }
        // Порядок — часть контракта: на нём стоит двоичный поиск. Файл с
        // переставленными ключами не «немного неправильный», он нерабочий.
        guard keys.isSortedAscending else { return nil }
        self.init(version: version, keys: keys, digests: Array(bytes[offset...]))
    }
}

private extension Array where Element == UInt64 {
    // nonisolated: проверяет разбор индекса, а он идёт вне main (@concurrent prepare).
    nonisolated var isSortedAscending: Bool {
        guard count > 1 else { return true }
        for index in 1..<count where self[index - 1] >= self[index] { return false }
        return true
    }
}
