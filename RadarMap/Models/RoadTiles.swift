//
//  RoadTiles.swift
//  RadarMap
//
//  Собственная дорожная сеть для схемы приборки: тайлы по 0.5° с сервера
//  (server/build_roads.py), в отличие от индекса лимитов знающие класс
//  дороги, мост, тоннель и односторонность — то есть всё, чем схема
//  отличает развязку от перекрёстка.
//
//  Целостность устроена в два звена: подписан ИНДЕКС (Ed25519, через общий
//  SignedPayload — правило 19: молча применяемые данные только под подписью),
//  а каждый тайл сверяется с sha256 из этого индекса. Подменённый на сервере
//  или по дороге тайл не сойдётся по хэшу и будет отброшен — при этом сами
//  тайлы возятся без подписи, и подпись владельца нужна одна на весь набор.
//
//  Формат тайла — контракт с server/build_roads.py (см. его шапку):
//  {"version":1,"roads":[[cls, flags, [lat, lon, dlat, dlon, …]], …]},
//  координаты в целых 1e-5°, первая абсолютная, дальше дельты.
//
//  Чистая распаковка и сеточный индекс, покрыты RoadTilesTests.
//

import CoreLocation
import CryptoKit
import Foundation

nonisolated enum RoadTiles {

    static let formatVersion = 1
    /// Новый формат: мелкая сетка и три набора на тайл — костяк района,
    /// улицы, дворовые проезды. Разложен так не для красоты: дворы это
    /// половина всех дорог, а видны они только когда мы сами во дворе, и в
    /// отдельном файле телефон просто не качает их всю остальную дорогу.
    static let formatVersionV2 = 2

    /// Наборы нового формата. Ключ индекса составной: «тайл_набор» — так он
    /// ложится в тот же плоский словарь, что и раньше.
    enum Set: String, CaseIterable, Sendable {
        case far = "f", streets = "s", yards = "y"
        case water = "w", green = "g", rail = "r", blocks = "b"
        /// Тротуары. Своим набором по тому же закону, что вода и зелень: слой,
        /// невидимый на текущем охвате, не качается и не разбирается.
        case sidewalks = "t"
        /// Дома. Своим набором и по тому же закону, но повод здесь сильнее
        /// всех: их больше, чем всех остальных объектов схемы вместе.
        case houses = "h"
        /// Поверхность дороги: полотно, площадь перекрёстка, фаски подхода.
        ///
        /// Считается СБОРКОЙ раз в неделю, а не телефоном на каждый кадр.
        /// Штрихами реалистичную дорогу не нарисовать никакой толщиной: у
        /// штриха нет ни кромки, ни площади перекрёстка, ни расширения перед
        /// ним. Всё это — геометрия, одинаковая для всех и не зависящая от
        /// зума, и место ей в тайле.
        ///
        /// Только ближний охват: на охвате района полотно вырождается в линию,
        /// и возить туда контуры значит платить за то, чего не видно.
        case surface = "d"
        /// Названия населённых пунктов. Сервер считает их с самого перехода
        /// на формат 2, а приложение не забирало ни разу: случая в этом
        /// перечислении просто не завели. Весь набор — 0,7 МБ на страну и
        /// 0,2 КБ на тайл, и он единственное, что делает обзорный охват
        /// читаемым: без имён это сеть серых линий без ответа на «где я».
        case places = "n"
        /// Точечные объекты. Наборов ДВА: ближний посажен на детальную
        /// геометрию, дальний пересчитан по костяку района — там раздельные
        /// проезжие сведены в одну ось, и точка с детальной сети уехала бы от
        /// нарисованной линии на полширины проспекта.
        case points = "p"
        case pointsFar = "q"

        /// Наборы местности разбираются в SketchArea, дорожные — в RoadLine.
        var isArea: Bool {
            switch self {
            case .far, .streets, .yards, .points, .pointsFar, .places: return false
            case .water, .green, .rail, .blocks, .sidewalks, .houses,
                 .surface: return true
            }
        }

        /// Набор точечных объектов: у него своя распаковка — одна координата
        /// вместо ломаной.
        var isPoints: Bool { self == .points || self == .pointsFar }

        /// Набор названий: своя распаковка — одна координата и строка.
        var isPlaces: Bool { self == .places }

        /// Очередь закачки: кого тянем первым, когда тайлов больше, чем
        /// соединений.
        ///
        /// Раньше очереди не было вовсе — все недостающие файлы уходили в сеть
        /// одним залпом (в центре Ташкента это до девяноста девяти запросов и
        /// 13,86 МБ), и первым приезжал тот, кому повезло. А снимок сети
        /// собирался только когда приедут ВСЕ, то есть до последнего дома
        /// экран оставался пустой землёй.
        ///
        /// Порядок отвечает на вопрос «без чего схемы нет»: костяк, улицы,
        /// крупные ориентиры, потом форма города, и в самом конце асфальт и
        /// застройка — они украшают то, что уже нарисовано.
        var loadRank: Int {
            switch self {
            case .far:       return 0
            case .streets:   return 1
            case .water:     return 2
            case .green:     return 3
            case .rail:      return 4
            case .blocks:    return 5
            case .pointsFar: return 6
            case .places:    return 7
            case .points:    return 8
            case .yards:     return 9
            case .surface:   return 10
            case .sidewalks: return 11
            case .houses:    return 12
            }
        }

        /// Вид местности набора. nil — вид из набора НЕ следует.
        ///
        /// Так у дорожных наборов, и так же у поверхности: в наборе «d» лежат
        /// сразу три вида — полотно, площадь перекрёстка и разделительная, —
        /// и вид каждой записи берётся из неё самой, а не из буквы файла.
        /// Вернуть отсюда один вид значило бы соврать про две трети набора.
        ///
        /// Без этой ветки switch переставал быть исчерпывающим, и МОДУЛЬ НЕ
        /// СОБИРАЛСЯ вовсе: набор «d» завели, а сюда его не дописали.
        var areaKind: SketchArea.Kind? {
            switch self {
            case .water:  return .water
            case .green:  return .green
            case .rail:   return .rail
            case .blocks: return .block
            case .sidewalks: return .sidewalk
            case .houses: return .house
            case .surface: return nil
            case .far, .streets, .yards, .points, .pointsFar, .places: return nil
            }
        }
    }

    /// Наборы тайлов, нужные на этом охвате.
    ///
    /// Чистая функция и живёт в модели, а не во вью: это РЕШЕНИЕ про трафик,
    /// самое дорогое в схеме, и проверять его надо тестом, а не на глаз по
    /// счётчику мегабайт.
    ///
    /// Костяк — всегда: без него схемы нет. Улицы и дворы — пока охват их
    /// касается. Местность — вода, зелень, рельсы — тоже всегда: крупные
    /// ориентиры, дёшевы и читаются на любом охвате. Кварталы — до трёх
    /// километров, где они ещё различимы. Дома и тротуары — по согласию.
    static func wantedSets(span: Double, minors: Bool, far: Bool,
                           houses: Bool, sidewalks: Bool) -> Swift.Set<Set> {
        var sets: Swift.Set<Set> = [.far, .water, .green, .rail]
        // Улицы — пока охват их вообще касается. Дальше рисуется костяк
        // района, и возить набор улиц на восемьдесят один тайл окрестности
        // значит платить за линии, которых не будет на экране.
        if span < RoadSketch.streetsMaxSpan { sets.insert(.streets) }
        if minors, span < RoadSketch.streetsMaxSpan { sets.insert(.yards) }
        if span < SketchArea.Kind.block.maxSpanMeters { sets.insert(.blocks) }
        // Тротуаров больше, чем всех улиц вместе (3 439 против 8 455 дорог в
        // одном центре Ташкента), а видны они только вблизи. Слой, невидимый
        // на текущем охвате, не качается и не разбирается — тот же закон, что
        // у дворовых проездов и кварталов. И спрашивается СОГЛАСИЕ: слой
        // объясняет, где кончается асфальт, — вопрос пешехода, а не водителя.
        if sidewalks, span < SketchArea.Kind.sidewalk.maxSpanMeters {
            sets.insert(.sidewalks)
        }
        // Дома — тот же закон и самый сильный повод: их 54 094 в одном кадре
        // центра против семисот дорог, а по стране это 78 МБ из 347 и 6,72 МБ
        // из 13,86 МБ одной окрестности. Слой, отвечающий на вопрос последних
        // двухсот метров, по умолчанию ВЫКЛЮЧЕН: этот вопрос задают раз в
        // поездку, а платят за него всю дорогу.
        if houses, span < SketchArea.Kind.house.maxSpanMeters {
            sets.insert(.houses)
        }
        // Поверхность дороги — ближний охват и только он.
        //
        // Штрихами реалистичную дорогу не нарисовать никакой толщиной: у
        // штриха нет ни кромки, ни площади перекрёстка, ни расширения перед
        // ним. Всё это посчитано сборкой раз в неделю и лежит готовым; на
        // дальнем плане полотно вырождается в линию, и там штрих честнее.
        if span < SketchArea.Kind.road.maxSpanMeters { sets.insert(.surface) }
        // Названия — начиная с того охвата, где с карты уходят улицы.
        // Ближе них подписаны улицы, и второе имя поверх них — шум; дальше
        // них имя посёлка единственное, что отличает город от степи.
        if span >= RoadSketch.farNetworkSpan { sets.insert(.places) }
        // Точки — из того набора, что посчитан по РИСУЕМОЙ сети. Просить оба
        // разом значило бы возить вдвое больше ради слоя, из которого виден
        // ровно один.
        if far {
            sets.insert(.pointsFar)
        } else if SketchPoint.Kind.allCases.contains(where: { $0.maxSpanMeters >= span }) {
            sets.insert(.points)
        }
        return sets
    }

    static func setKey(_ tile: String, _ set: Set) -> String { "\(tile)_\(set.rawValue)" }

    /// Имя файла тайла на сервере и на диске.
    static func fileName(key: String, version: Int) -> String {
        version >= formatVersionV2 ? "road2_\(key).json" : "tile_\(key).json"
    }
    /// Масштаб координат в тайле: 1e-5° ≈ 1,1 м.
    static let scale = 1e5

    /// Подписанный индекс: какие тайлы существуют и их sha256.
    struct Index: Decodable, Sendable, Equatable {
        let version: Int
        let tileDegrees: Double
        let tiles: [String: TileMeta]

        struct TileMeta: Decodable, Sendable, Equatable {
            let sha256: String
            let bytes: Int
        }
    }

    /// Ключ тайла — ровно та же формула, что в build_roads.py: смещение в
    /// положительные, чтобы не спорить об округлении отрицательных.
    static func tileKey(latitude: Double, longitude: Double,
                        tileDegrees: Double) -> String {
        let latIndex = Int(floor((latitude + 90) / tileDegrees))
        let lonIndex = Int(floor((longitude + 180) / tileDegrees))
        return "\(latIndex)_\(lonIndex)"
    }

    /// Окрестность 3×3: свой тайл и все соседние — граница тайла не должна
    /// быть краем мира на схеме.
    static func neighborhood(of coordinate: CLLocationCoordinate2D,
                             tileDegrees: Double) -> [String] {
        coverage(of: coordinate, tileDegrees: tileDegrees, steps: 1)
    }

    /// Сколько тайлов в стороне нужно, чтобы накрыть круг такого радиуса.
    ///
    /// Тайл 0,05° — это 5,5 км по широте и 4,2 км по долготе на широте
    /// Ташкента; считаем по УЗКОЙ стороне, иначе на востоке и западе от
    /// машины окажется незакрытая полоса.
    /// Потолок — четыре тайла в сторону, то есть окрестность 9×9.
    ///
    /// Это ±18,8 км на широте Ташкента: как раз обзорный охват целиком.
    /// Выше потолка растёт не польза, а число запросов: тайлов в окрестности
    /// (2n+1)², и шестой шаг стоил бы вдвое больше пятого ради полосы, до
    /// которой взгляд не доходит.
    static func steps(forRadius meters: Double, tileDegrees: Double,
                      latitude: Double, limit: Int = 4) -> Int {
        let metresPerLon = 111_320.0 * max(0.2, cos(latitude * .pi / 180))
        let side = tileDegrees * min(111_320.0, metresPerLon)
        guard side > 0 else { return 1 }
        return max(1, min(limit, Int(ceil(meters / side))))
    }

    /// Окрестность (2·steps+1)² тайлов, БЛИЖНИМИ КОЛЬЦАМИ ВПЕРЁД.
    ///
    /// Порядок здесь не для красоты: он же порядок закачки. Тайлы приезжают по
    /// одному, и первым обязан приехать тот, на котором стоит машина, а не
    /// тот, чей ключ оказался раньше в переборе. Пока порядок был построчным,
    /// первым качался левый верхний угол окрестности — то есть угол экрана.
    static func coverage(of coordinate: CLLocationCoordinate2D,
                         tileDegrees: Double, steps: Int) -> [String] {
        var keys: [String] = []
        keys.reserveCapacity((2 * steps + 1) * (2 * steps + 1))
        for ring in 0...max(0, steps) {
            for latStep in -ring...ring {
                for lonStep in -ring...ring {
                    guard max(abs(latStep), abs(lonStep)) == ring else { continue }
                    keys.append(tileKey(
                        latitude: coordinate.latitude + Double(latStep) * tileDegrees,
                        longitude: coordinate.longitude + Double(lonStep) * tileDegrees,
                        tileDegrees: tileDegrees))
                }
            }
        }
        return keys
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Код класса из тайла → RoadClass. Неизвестный код будущего формата —
    /// «.unknown»: дорогу рисуем, но тонко и без обещаний.
    static func roadClass(code: Int) -> RoadClass {
        switch code {
        case 1: .motorway
        case 2: .trunk
        case 3: .primary
        case 4: .secondary
        case 5: .tertiary
        case 6: .residential
        case 7: .service
        default: .unknown
        }
    }

    /// Распаковать тайл местности.
    ///
    /// Формат тот же, что у дорог, и это не совпадение, а решение: одна
    /// распаковка дельт на оба слоя. Первое число — вид, второе — биты, из
    /// которых нам нужен один: замкнут контур или нет.
    static func decodeAreas(_ data: Data) -> [SketchArea]? {
        guard let raw = decodeEntries(data) else { return nil }
        var areas: [SketchArea] = []
        areas.reserveCapacity(raw.count)
        for entry in raw {
            guard let kind = SketchArea.Kind(rawValue: entry.code) else { continue }
            // Этажность дома лежит в БИТАХ записи, старше бита «замкнут».
            // Пятый элемент записи невозможен: decodeEntries принимает длину
            // 3 или 4, и пятый отправил бы в nil весь тайл у сборок, которые
            // о нём не знают. Биты старая сборка просто не видит.
            // И этажность дома, и класс полотна лежат в ОДНОМ И ТОМ ЖЕ поле
            // старших битов — у разных видов оно значит разное. Второго поля
            // не завести: пятый элемент записи возвращает nil на весь тайл у
            // сборок, которые о нём не знают.
            areas.append(SketchArea(points: entry.points, kind: kind,
                                    isClosed: entry.flags & 1 != 0,
                                    levels: kind == .house
                                            ? (entry.flags >> 1) & 0x3F : 0,
                                    roadClass: kind == .road
                                            ? (entry.flags >> 1) & 0x0F : 0))
        }
        return areas
    }

    /// Распаковать тайл. `nil` — формат не тот: sha уже сошёлся, значит это
    /// не порча по дороге, а дрейф формата, и правильный ответ — не рисовать
    /// ничего, а не рисовать наполовину разобранное.
    /// Одна запись тайла: код, биты и распакованные дельты.
    private struct Entry {
        let code: Int
        let flags: Int
        let points: [CLLocationCoordinate2D]
        /// Имя четвёртым элементом и только там, где оно есть: у одной дороги
        /// из семи. Писать пустую строку остальным значило бы платить за неё
        /// местом у всех.
        let name: String
    }

    /// Распаковка, общая для дорог и местности. Держать её в одном месте
    /// важнее краткости: формат дельт — контракт с сервером, и разойтись двум
    /// его читателям нельзя.
    /// Распаковать тайл точечных объектов.
    ///
    /// Вид, которого приложение не знает, пропускается, а не валит тайл:
    /// панель вправе завести новый раньше, чем выйдет сборка, и светофоры в
    /// том же файле водитель увидеть обязан.
    static func decodePoints(_ data: Data) -> [SketchPoint]? {
        guard let raw = decodeEntries(data, minimumCoordinates: 1) else { return nil }
        return raw.compactMap { entry in
            guard let kind = SketchPoint.Kind(rawValue: entry.code),
                  let point = entry.points.first else { return nil }
            // Биты записи точки: 0–6 — азимут дороги шагом 3°, 7–12 — ширина
            // проезжей части целыми метрами. Контракт с point_flags в
            // build_roads.py. Оба числа известны серверу в момент посадки
            // точки на ось и больше нигде: дальше по конвейеру дороги нет.
            // Направления полос лежат ВЫШЕ азимута и ширины, по четыре бита
            // на полосу, до восьми полос. Девять стрелок в ряд на схеме уже не
            // читаются, а место в записи не бесплатно.
            //
            // Сколько полос — считаем ПО САМИМ направлениям, а не по ширине:
            // ширина знает про метры, а не про разметку, и деление её на
            // среднюю полосу давало бы то восемь стрелок там, где их шесть, то
            // наоборот. Читаем все восемь слотов и отбрасываем пустой хвост.
            var turns: [LaneTurn] = []
            if kind == .laneArrows {
                turns = (0..<8).map {
                    LaneTurn(rawValue: (entry.flags >> (13 + $0 * 4)) & 0xF) ?? .none
                }
                while turns.last == LaneTurn.none { turns.removeLast() }
            }
            return SketchPoint(coordinate: point, kind: kind,
                               azimuthDegrees: Double(entry.flags & 0x7F) * 3,
                               widthMeters: Double((entry.flags >> 7) & 0x3F),
                               turns: turns)
        }
    }

    /// Распаковать тайл названий.
    ///
    /// Формат — тот же, что у точек, плюс имя четвёртым элементом записи:
    /// [ранг, биты, [lat, lon], "Имя"]. Ранг, которого приложение не знает,
    /// пропускается, а не валит тайл: сервер вправе завести новый раньше, чем
    /// выйдет сборка. Без имени запись бесполезна — подписывать нечем.
    static func decodePlaces(_ data: Data) -> [SketchPlace]? {
        guard let raw = decodeEntries(data, minimumCoordinates: 1) else { return nil }
        return raw.compactMap { entry in
            guard let rank = SketchPlace.Rank(rawValue: entry.code),
                  let point = entry.points.first,
                  !entry.name.isEmpty else { return nil }
            return SketchPlace(coordinate: point, rank: rank, name: entry.name)
        }
    }

    private static func decodeEntries(_ data: Data,
                                      minimumCoordinates: Int = 2) -> [Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              version == formatVersion || version == formatVersionV2,
              let rawEntries = root["roads"] as? [[Any]] else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(rawEntries.count)
        for entry in rawEntries {
            guard entry.count == 3 || entry.count == 4,
                  let code = (entry[0] as? NSNumber)?.intValue,
                  let flags = (entry[1] as? NSNumber)?.intValue,
                  let flat = entry[2] as? [NSNumber],
                  flat.count >= minimumCoordinates * 2,
                  flat.count % 2 == 0 else { return nil }

            var points: [CLLocationCoordinate2D] = []
            points.reserveCapacity(flat.count / 2)
            var lat = 0, lon = 0
            for i in stride(from: 0, to: flat.count - 1, by: 2) {
                if i == 0 {
                    lat = flat[0].intValue
                    lon = flat[1].intValue
                } else {
                    lat += flat[i].intValue
                    lon += flat[i + 1].intValue
                }
                points.append(CLLocationCoordinate2D(latitude: Double(lat) / scale,
                                                     longitude: Double(lon) / scale))
            }
            let name = entry.count > 3 ? (entry[3] as? String ?? "") : ""
            entries.append(Entry(code: code, flags: flags, points: points, name: name))
        }
        return entries
    }

    static func decodeTile(_ data: Data) -> [RoadLine]? {
        guard let entries = decodeEntries(data) else { return nil }
        // Биты flags: 1 = одностороннее, 2 = мост, 4 = тоннель, 8 = кольцо,
        // 16–128 — число полос.
        //
        // Полосы приехали СТАРШИМИ БИТАМИ, а не пятым элементом записи, и это
        // не экономия. Разбор выше принимает записи длиной 3 или 4; пятый
        // элемент вернул бы nil на ВЕСЬ тайл, то есть установленная сборка
        // потеряла бы не дорогу, а регион. Старшие биты сборка, не знающая о
        // полосах, просто не видит: она читает флаги масками.
        return entries.map { entry in
            RoadLine(points: entry.points,
                     kind: roadClass(code: entry.code),
                     level: entry.flags & 2 != 0 ? 1 : (entry.flags & 4 != 0 ? -1 : 0),
                     isOneWay: entry.flags & 1 != 0 && entry.flags & 8 == 0,
                     isDetailed: true,
                     isRing: entry.flags & 8 != 0,
                     name: entry.name,
                     lanes: (entry.flags >> 4) & 0b1111)
        }
    }
}

// MARK: - Сеточный индекс по загруженным тайлам

/// Иммутабельный снимок загруженных тайлов: строится в фоне, читается с
/// главного потока без блокировок — тот же приём, что LimitIndex.
nonisolated struct TileRoadNetwork: RoadNetworkSource {
    let lines: [RoadLine]
    let grid: [Int: [Int32]]   // ячейка 0.01° → индексы линий

    private static func cellKey(lat: Double, lon: Double) -> Int {
        Int((lat + 90) * 100) * 40_000 + Int((lon + 180) * 100)
    }

    /// Ключ схлопывания дублей на границе тайлов.
    ///
    /// Все шесть полей исходного ключа обязаны остаться: одни и те же концы
    /// бывают у РАЗНЫХ дорог — мостовой сегмент над одноимённым участком имеет
    /// те же крайние точки, но другой класс и другое число точек. Ужать ключ
    /// до пары чисел, выбросив класс и счётчик, значит молча стереть со схемы
    /// сотню настоящих дорог ради трёх мегабайт.
    private struct LineKey: Hashable {
        let cls: UInt8
        let count: Int32
        let ax, ay, bx, by: Int32

        init(line: RoadLine, first: CLLocationCoordinate2D, last: CLLocationCoordinate2D) {
            // truncatingIfNeeded, а не ловушечный Int32(): тайл сверен по
            // sha256 с подписанным индексом, но дельты в формате ничем не
            // ограничены, и накопленная координата в кривом-но-подписанном
            // тайле уронила бы приложение прямо в поездке.
            cls = UInt8(truncatingIfNeeded: line.kind.hashValue)
            count = Int32(truncatingIfNeeded: line.points.count)
            ax = Int32(truncatingIfNeeded: Int(first.latitude * RoadTiles.scale))
            ay = Int32(truncatingIfNeeded: Int(first.longitude * RoadTiles.scale))
            bx = Int32(truncatingIfNeeded: Int(last.latitude * RoadTiles.scale))
            by = Int32(truncatingIfNeeded: Int(last.longitude * RoadTiles.scale))
        }
    }

    /// Собрать индекс. Дорога на границе лежит в обоих тайлах целиком
    /// (так дешевле серверу и клиенту) — дубли схлопываются здесь, иначе
    /// граница съедала бы бюджет линий дважды.
    static func build(_ tileLines: [[RoadLine]]) -> TileRoadNetwork {
        var lines: [RoadLine] = []
        var grid: [Int: [Int32]] = [:]
        var seen = Set<LineKey>()
        // Окрестность 3×3 над Ташкентом — это больше ста тысяч линий, и на
        // каждую строился строковый ключ длиной под полсотни символов, то есть
        // отдельная аллокация в куче. Всплеск доходил до четырнадцати
        // мегабайт — ради схлопывания четырёх сотен дублей. Тот же урок в
        // проекте уже выучен: ключ ячейки в CameraMapContent пакуется в целое,
        // а не собирается интерполяцией.
        seen.reserveCapacity(tileLines.reduce(0) { $0 + $1.count })

        for tile in tileLines {
            for line in tile {
                guard let first = line.points.first, let last = line.points.last else { continue }
                let key = LineKey(line: line, first: first, last: last)
                guard seen.insert(key).inserted else { continue }

                let index = Int32(lines.count)
                var cells = Set<Int>()
                var previous: CLLocationCoordinate2D?
                for point in line.points {
                    cells.insert(cellKey(lat: point.latitude, lon: point.longitude))
                    // Длинные прямые перегоны: отмечаем и промежуточные ячейки,
                    // иначе трасса «пропадает» между своими редкими точками.
                    if let from = previous {
                        let steps = Int(max(abs(point.latitude - from.latitude),
                                            abs(point.longitude - from.longitude)) / 0.005)
                        if steps > 1 {
                            for step in 1..<steps {
                                let f = Double(step) / Double(steps)
                                cells.insert(cellKey(
                                    lat: from.latitude + (point.latitude - from.latitude) * f,
                                    lon: from.longitude + (point.longitude - from.longitude) * f))
                            }
                        }
                    }
                    previous = point
                }
                lines.append(line)
                for cell in cells { grid[cell, default: []].append(index) }
            }
        }
        return TileRoadNetwork(lines: lines, grid: grid)
    }

    func roads(near coordinate: CLLocationCoordinate2D,
               radius: CLLocationDistance) -> [RoadLine] {
        let span = max(1, Int((radius / 1100).rounded(.up)))
        let centerLat = Int((coordinate.latitude + 90) * 100)
        let centerLon = Int((coordinate.longitude + 180) * 100)

        var candidates = Set<Int32>()
        for latCell in (centerLat - span)...(centerLat + span) {
            for lonCell in (centerLon - span)...(centerLon + span) {
                if let found = grid[latCell * 40_000 + lonCell] {
                    candidates.formUnion(found)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        let metersPerLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
        func distance(_ point: CLLocationCoordinate2D) -> Double {
            hypot((point.latitude - coordinate.latitude) * 111_320.0,
                  (point.longitude - coordinate.longitude) * metersPerLon)
        }
        return candidates.compactMap { index -> RoadLine? in
            let line = lines[Int(index)]
            // Точки за радиусом отбрасываем, но линию не рвём: берём кусок от
            // первой до последней попавшей — иначе дорога рассыпалась бы на
            // обрывки там, где она просто длинная.
            guard let first = line.points.firstIndex(where: { distance($0) <= radius }),
                  let last = line.points.lastIndex(where: { distance($0) <= radius }),
                  last > first else { return nil }
            var trimmed = line
            trimmed.points = Array(line.points[first...last])
            return trimmed
        }
    }
}
