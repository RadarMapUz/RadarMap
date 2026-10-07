//
//  TileRelease.swift
//  RadarMap
//
//  Выпуск тайлов по версии: подписанный корень и его корзины.
//
//  Индекс страны одним файлом — `mvt_index.json` 23,5 МБ, а с основой карты
//  ещё 27 — телефон разбирал целиком, около сотни мегабайт транзиентно, и
//  телеметрия показала отстрелы по памяти. Выпуск (server/publish_tileset.sh)
//  режет тот же индекс на корзины по клетке z10: телефону нужна корзина
//  своего района — 6–40 КБ, — а не страна.
//
//  Цепочка доверия: подпись корня (тот же ключ, что у базы камер) → sha256
//  корзины в корне → sha256 тайла в корзине. Подменить тайл нельзя, не
//  подменив корзину, а корзину — не подделав подпись.
//
//  Адрес тайла несёт номер выпуска (/v/<N>/…), и по такому адресу содержимое
//  не меняется никогда — поэтому сервер отдаёт его с кэшем на год, а новая
//  публикация не встречает старый тайл с новым индексом.
//
//  Чистая структура: без сети и диска — покрыта TileReleaseTests. Контракт —
//  docs/plan_map_offline.md §2.6, формат корзины — TileDigestIndex.
//

import Foundation

nonisolated struct TileRelease: Decodable, Sendable, Equatable {

    /// Набор тайлов выпуска: наш MVT («mvt») или основа OpenMapTiles («omt»).
    struct TileSet: Decodable, Sendable, Equatable {
        /// Каталог в выпуске: /v/<N>/<path>/<z>/<x>/<y>.<ext>.
        let path: String
        /// Расширение тайла без точки: «mvt», «pbf».
        let ext: String
        /// sha256 (hex) каждой корзины: «<bx>_<by>» или «low».
        let buckets: [String: String]
    }

    let version: Int
    /// Зум клетки, по которой режутся корзины (сейчас 10).
    let bucketZoom: Int
    let sets: [String: TileSet]

    /// Корзина тайлов мельче клетки — одна на набор.
    static let lowBucket = "low"

    /// Имя корзины тайла: предок на `bucketZoom` либо `low`.
    /// Ровно как `bucket_of` в server/tile_buckets.py.
    static func bucket(z: Int, x: Int, y: Int, bucketZoom: Int) -> String {
        guard z >= bucketZoom else { return lowBucket }
        let shift = z - bucketZoom
        return "\(x >> shift)_\(y >> shift)"
    }

    /// Тайл выпуска, узнанный по адресу.
    struct Tile: Equatable, Sendable {
        let version: Int
        let set: String
        let z: Int
        let x: Int
        let y: Int

        /// Ключ в корзине — тот же «z/x/y», что в TileDigestIndex.
        var key: String { "\(z)/\(x)/\(y)" }
    }

    /// Разбор адреса «…/v/<N>/<path>/<z>/<x>/<y>.<ext>». nil — это не тайл
    /// выпуска (или набор, которого в этом выпуске нет).
    func tile(at url: URL) -> Tile? {
        guard let tile = Self.parse(url) else { return nil }
        guard let spec = sets[tile.set], tile.version == version,
              url.pathExtension == spec.ext else { return nil }
        return tile
    }

    /// Разбор адреса без сверки с корнем — по нему сторож решает, его ли это
    /// запрос, ещё до того, как корень загружен.
    static func parse(_ url: URL) -> Tile? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let v = parts.lastIndex(of: "v"), parts.count - v == 6,
              let version = Int(parts[v + 1]),
              let z = Int(parts[v + 3]), let x = Int(parts[v + 4]) else { return nil }
        let last = parts[v + 5]
        guard let dot = last.firstIndex(of: "."), let y = Int(last[..<dot]),
              (0...24).contains(z), x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        return Tile(version: version, set: parts[v + 2], z: z, x: x, y: y)
    }

    /// sha256 корзины тайла по подписанному корню; nil — корзины нет, а
    /// значит, нет и самого тайла (пустая клетка, чужая страна).
    func bucketDigest(for tile: Tile) -> (name: String, sha256: String)? {
        guard let spec = sets[tile.set] else { return nil }
        let name = Self.bucket(z: tile.z, x: tile.x, y: tile.y, bucketZoom: bucketZoom)
        guard let digest = spec.buckets[name] else { return nil }
        return (name, digest)
    }

    /// Адрес корзины на сервере.
    func bucketURL(base: URL, set: String, name: String) -> URL {
        URL(string: "\(Self.root(base))/v/\(version)/idx/\(set)/\(name).bin")!
    }

    /// Шаблон адреса тайлов набора для стиля движка.
    func tilesTemplate(base: URL, set: String) -> String? {
        guard let spec = sets[set] else { return nil }
        return "\(Self.root(base))/v/\(version)/\(spec.path)/{z}/{x}/{y}.\(spec.ext)"
    }

    /// Адрес сервера без хвостового «/». Строкой, а не appendingPathComponent:
    /// тот кодирует фигурные скобки шаблона (см. EngineMapStyle).
    static func root(_ base: URL) -> String {
        let text = base.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
