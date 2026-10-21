//
//  LaneOverlay.swift
//  RadarMap
//
//  Слой полос (20.8): наш подписанный набор «какие полосы на подходе к
//  перекрёстку» — там, где OSRM молчит.
//
//  OSRM отдаёт полосы только там, где в OSM стоит `turn:lanes`: на двенадцати
//  маршрутах Ташкента (21.10) — у 7 поворотов из 97, у левых — у одного из 26.
//  Остальным край по ПДД (20.2) говорит «левый ряд», но не «из двух левых».
//  Слой закрывает разницу: файл собирает и проверяет владелец, подписывает
//  своим ключом (на сервере ключа нет), телефон сверяет подпись индекса и
//  sha файла. Контракт — docs/lanes_overlay_contract.md, образец данных —
//  server/fixtures/lanes_overlay_sample.json (его читает LaneOverlayTests:
//  телефон и сервер не разъедутся молча).
//
//  Правила применения, по важности:
//  1. Полосы OSRM главнее слоя — слой только там, где OSRM молчит.
//  2. Подход ищется в 25 м от точки манёвра и по курсу ВЪЕЗДА: встречный
//     подход того же перекрёстка — другие полосы, и чужой ряд хуже никакого.
//  3. Ряд без единой подходящей полосы не показывается: он противоречил бы
//     самому маршруту — значит, подход не наш или запись врёт. Тогда остаётся
//     край по ПДД, как без слоя.
//
//  Всё здесь чистое и nonisolated: LaneOverlayTests и PerformanceBudgetTests.
//

import CoreLocation
import Foundation

// MARK: - Подписанный индекс

/// Индекс слоя (`lanes/lanes_index.json`): тот же контракт, что у графа
/// трасс и лимитов — format, version, files[name, sha256, bytes].
nonisolated struct LanesManifest: Decodable, Sendable, Equatable {
    let format: Int
    let version: Int
    let files: [File]

    nonisolated struct File: Decodable, Sendable, Equatable {
        let format: Int
        let name: String
        let sha256: String
        let bytes: Int
    }

    static let indexFormat = 1
    static let dataFormat = 1
    /// Имена файлов данных: `lanes.<sha16>.json` (по содержимому — старый
    /// живёт, пока на него ссылается старый индекс). По префиксу же чистится
    /// каталог на телефоне.
    static let filePrefix = "lanes."

    /// Файл, который умеем читать, если индекс в порядке; nil — не верить.
    /// Имя — без каталогов: адрес собирается как `lanes/` + имя, и подписанный
    /// индекс с опечаткой в скрипте не уведёт запрос за пределы каталога.
    var usableFile: File? {
        guard format == Self.indexFormat, version > 0,
              let file = files.first(where: { $0.format == Self.dataFormat }),
              file.name.hasPrefix(Self.filePrefix),
              LimitsManifest.isSafeName(file.name), !file.name.contains("/"),
              file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              (1...AppConfig.laneOverlayMaxBytes).contains(file.bytes) else { return nil }
        return file
    }
}

// MARK: - Слой

nonisolated struct LaneOverlay: Sendable {

    /// Один подход к перекрёстку.
    nonisolated struct Junction: Equatable, Sendable {
        /// Устойчивый идентификатор подхода — для правок и журнала.
        let id: String
        let latitude: Double
        let longitude: Double
        /// Курс ВЪЕЗДА в перекрёсток, 0–359° (куда едет машина).
        let bearing: Double
        /// Допуск курса, °: не больше `laneOverlayMaxTolerance`.
        let tolerance: Double
        /// Полосы слева направо, в каждой — стрелки в порядке файла.
        let lanes: [[LaneArrow]]
    }

    /// Почему файл отвергнут целиком (отдельные записи отбрасываются молча,
    /// со счётом в `dropped`).
    nonisolated enum Failure: Error, Equatable, Sendable {
        /// Не JSON или не та верхняя структура.
        case json
        /// Чужой формат данных (`v`).
        case format(Int)
        /// Больше подходов, чем допускает контракт.
        case tooMany(Int)

        var logDescription: String {
            switch self {
            case .json: "файл не разбирается"
            case .format(let v): "формат данных \(v)"
            case .tooMany(let count): "подходов \(count) — больше контракта"
            }
        }
    }

    let junctions: [Junction]
    /// Записей отброшено при разборе (вне словаря, вне Узбекистана, …).
    let dropped: Int
    /// Когда файл собран (unix-время сервера); nil — не указано.
    let generated: Int?
    /// Сетка `laneOverlayGridDegrees`: ячейка → индексы подходов. Поиск в
    /// 25 м — девять ячеек вокруг точки, а не перебор пятидесяти тысяч.
    private let grid: [Int64: [Int32]]

    init(junctions: [Junction], dropped: Int = 0, generated: Int? = nil) {
        self.junctions = junctions
        self.dropped = dropped
        self.generated = generated
        var grid: [Int64: [Int32]] = [:]
        grid.reserveCapacity(junctions.count)
        for (index, junction) in junctions.enumerated() {
            grid[Self.cellKey(Self.cell(junction.latitude), Self.cell(junction.longitude)),
                 default: []].append(Int32(index))
        }
        self.grid = grid
    }

    var count: Int { junctions.count }

    // MARK: Разбор

    /// Файл данных → слой. Плохая запись отбрасывается одна (контракт:
    /// «сервер отвергает файл, телефон — запись»); файл целиком — только
    /// чужого формата, сверх лимита подходов или не JSON.
    static func decode(_ data: Data) -> Result<LaneOverlay, Failure> {
        let raw: RawFile
        do {
            raw = try JSONDecoder().decode(RawFile.self, from: data)
        } catch {
            return .failure(.json)
        }
        guard raw.v == LanesManifest.dataFormat else { return .failure(.format(raw.v)) }
        guard raw.junctions.count <= AppConfig.laneOverlayMaxJunctions else {
            return .failure(.tooMany(raw.junctions.count))
        }
        var junctions: [Junction] = []
        junctions.reserveCapacity(raw.junctions.count)
        for item in raw.junctions {
            if let junction = item.value.flatMap(Self.validated) { junctions.append(junction) }
        }
        return .success(LaneOverlay(junctions: junctions,
                                    dropped: raw.junctions.count - junctions.count,
                                    generated: raw.generated))
    }

    /// Запись по контракту или nil: 1–8 полос, стрелки только из словаря OSRM,
    /// координата в Узбекистане, курс 0–359, допуск (0; 45].
    static func validated(_ raw: RawJunction) -> Junction? {
        let tolerance = raw.tolerance ?? AppConfig.laneOverlayDefaultTolerance
        guard !raw.id.isEmpty,
              raw.lat.isFinite, raw.lon.isFinite,
              AppConfig.uzLatRange.contains(raw.lat), AppConfig.uzLonRange.contains(raw.lon),
              raw.bearing.isFinite, raw.bearing >= 0, raw.bearing < 360,
              tolerance.isFinite, tolerance > 0, tolerance <= AppConfig.laneOverlayMaxTolerance,
              (1...AppConfig.laneOverlayMaxLanes).contains(raw.lanes.count) else { return nil }
        var lanes: [[LaneArrow]] = []
        lanes.reserveCapacity(raw.lanes.count)
        for lane in raw.lanes {
            let tokens = lane.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let arrows = tokens.compactMap(LaneArrow.fromOSRM)
            // Неизвестная стрелка или пустая полоса — запись целиком: ряд, из
            // которого выпала полоса, врёт про их число (как у OSRM, `hints`).
            guard !tokens.isEmpty, arrows.count == tokens.count else { return nil }
            lanes.append(arrows)
        }
        return Junction(id: raw.id, latitude: raw.lat, longitude: raw.lon,
                        bearing: raw.bearing, tolerance: tolerance, lanes: lanes)
    }

    /// Верх файла. `junctions` — массив «мягких» записей: одна запись с полем
    /// не того типа не роняет весь файл.
    nonisolated struct RawFile: Decodable {
        let v: Int
        let generated: Int?
        let junctions: [Lenient<RawJunction>]
    }

    nonisolated struct RawJunction: Decodable, Equatable {
        let id: String
        let lat: Double
        let lon: Double
        let bearing: Double
        let tolerance: Double?
        let lanes: [String]
        let src: String?
        let checked: String?
    }

    /// Элемент массива, который не обязан разобраться: ошибка — nil, а не
    /// отказ всего массива.
    nonisolated struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            // Чужая запись — штатный случай контракта, не ошибка программы:
            // `decode` считает её в `dropped`.
            value = try? Value(from: decoder)
        }
    }

    // MARK: Поиск

    /// Ближайший подход в `laneOverlayMatchMeters` от точки, курс въезда
    /// которого отличается от `approachBearing` не больше его допуска.
    /// Отрицательный курс — «не знаем», и подхода нет: без курса встречный
    /// подход того же перекрёстка неотличим от нашего.
    func junction(at coordinate: CLLocationCoordinate2D, approachBearing: Double) -> Junction? {
        guard approachBearing >= 0, approachBearing.isFinite else { return nil }
        let row = Self.cell(coordinate.latitude), column = Self.cell(coordinate.longitude)
        var best: (index: Int32, distance: Double, delta: Double)?
        for dRow in -1...1 {
            for dColumn in -1...1 {
                guard let bucket = grid[Self.cellKey(row + dRow, column + dColumn)] else { continue }
                for index in bucket {
                    let junction = junctions[Int(index)]
                    let distance = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                                        junction.latitude, junction.longitude)
                    guard distance <= AppConfig.laneOverlayMatchMeters else { continue }
                    let delta = GeoMath.angleDifference(junction.bearing, approachBearing)
                    guard delta <= junction.tolerance else { continue }
                    if let current = best,
                       distance > current.distance
                        || (distance == current.distance && delta >= current.delta) { continue }
                    best = (index, distance, delta)
                }
            }
        }
        return best.map { junctions[Int($0.index)] }
    }

    /// Полосы подхода для манёвра или nil (подхода нет, или ни одна полоса не
    /// ведёт туда, куда маршрут). `maneuver` nil — проезд прямо.
    func lanes(at coordinate: CLLocationCoordinate2D, approachBearing: Double,
               maneuver: ManeuverKind?) -> [LaneHint]? {
        guard let junction = junction(at: coordinate, approachBearing: approachBearing) else { return nil }
        return Self.hints(junction.lanes, maneuver: maneuver)
    }

    /// Какие полосы «наши» для манёвра.
    ///
    /// Сторона по контракту: налево — `left`/`slight left`/`sharp left`,
    /// направо — зеркально, прямо — `straight` (`none` уже прочитан как
    /// прямо). Точная стрелка главнее стороны: при «круто налево | налево |
    /// прямо» обычный левый поворот — со второй полосы, а не с обеих левых;
    /// нет точной — годится любая стрелка в эту сторону. Разворот —
    /// `uturn`, а без неё — крайняя левая полоса со стрелкой налево (у нас
    /// разворачиваются из левого поворотного ряда). Кольцо и финиш — нет:
    /// ряд на кольце зависит от съезда, а не от стрелок подхода.
    static func hints(_ lanes: [[LaneArrow]], maneuver: ManeuverKind?) -> [LaneHint]? {
        guard !lanes.isEmpty else { return nil }
        let valid: [Bool]
        switch maneuver {
        case nil, .straight?:
            valid = lanes.map { $0.contains(.straight) }
        case .uturn?:
            if lanes.contains(where: { $0.contains(.uturn) }) {
                valid = lanes.map { $0.contains(.uturn) }
            } else {
                let leftmost = lanes[0].contains(.left) || lanes[0].contains(.sharpLeft)
                valid = lanes.indices.map { $0 == 0 && leftmost }
            }
        case .roundabout?, .arrive?:
            return nil
        case let kind?:
            let exact = exactArrow(kind)
            let side: Set<LaneArrow> = kind.side == .left ? [.left, .slightLeft, .sharpLeft]
                                                           : [.right, .slightRight, .sharpRight]
            if let exact, lanes.contains(where: { $0.contains(exact) }) {
                valid = lanes.map { $0.contains(exact) }
            } else {
                valid = lanes.map { lane in lane.contains { side.contains($0) } }
            }
        }
        guard valid.contains(true) else { return nil }
        return zip(lanes, valid).map { LaneHint(arrows: $0, isValid: $1) }
    }

    private static func exactArrow(_ kind: ManeuverKind) -> LaneArrow? {
        switch kind {
        case .left: .left
        case .slightLeft: .slightLeft
        case .sharpLeft: .sharpLeft
        case .right: .right
        case .slightRight: .slightRight
        case .sharpRight: .sharpRight
        case .straight: .straight
        case .uturn: .uturn
        case .roundabout, .arrive: nil
        }
    }

    // MARK: Сетка

    private static func cell(_ degrees: Double) -> Int {
        Int((degrees / AppConfig.laneOverlayGridDegrees).rounded(.down))
    }

    private static func cellKey(_ row: Int, _ column: Int) -> Int64 {
        (Int64(row) << 32) | (Int64(column) & 0xFFFF_FFFF)
    }
}

// MARK: - Где спросить слой на маршруте

/// Точка маршрута, у которой можно спросить слой: манёвр без полос OSRM или
/// перекрёсток, который маршрут проезжает прямо. Собирается при разборе
/// ответа OSRM (там известны точки манёвров и перекрёстков) и живёт в
/// варианте — слой, приехавший после построения, применяется без нового
/// запроса к серверу.
nonisolated struct LaneProbe: Equatable, Sendable {
    nonisolated enum Target: Equatable, Sendable {
        /// Манёвр: индекс в `steps` варианта.
        case step(Int)
        /// Проезд прямо: `distanceAlong` будущего `LaneNotice`.
        case passage(CLLocationDistance)
    }

    let target: Target
    let latitude: Double
    let longitude: Double
    /// Курс въезда по линии маршрута за последние ~30 м до точки.
    let approachBearing: Double
    /// Манёвр шага; nil — проезд прямо.
    let maneuver: ManeuverKind?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Курс въезда по самой линии маршрута: точки спрашиваются по порядку, и
/// поиск идёт только вперёд от прошлой найденной.
///
/// Расстояние «от старта» у OSRM — сумма длин шагов (гаверсинус), у нас —
/// своя мерка, и на сотне километров они расходятся на сотни метров. Поэтому
/// абсолютной оценке OSRM не верим: ожидаемое место — НАША прошлая точка плюс
/// разница оценок OSRM между соседними точками (на ней расхождение — метры).
/// Из отрезков у самой линии берётся ближайший к ожидаемому месту: на
/// развороте обратный проезд по той же дороге лежит на нуле метров от точки,
/// но на сотни метров дальше по маршруту — и не перепутается с прямым.
nonisolated struct RoutePathCursor {
    private let path: [CLLocationCoordinate2D]
    private let cumulative: [Double]
    private var segment = 0
    /// Прошлая найденная точка: наша мерка и оценка OSRM.
    private var lastAlong = 0.0
    private var lastEstimate = 0.0

    init(path: [CLLocationCoordinate2D]) {
        self.path = path
        var cumulative = [Double](repeating: 0, count: path.count)
        for i in path.indices.dropFirst() {
            cumulative[i] = cumulative[i - 1] + GeoMath.fastDistance(path[i - 1].latitude, path[i - 1].longitude,
                                                                     path[i].latitude, path[i].longitude)
        }
        self.cumulative = cumulative
    }

    /// Курс въезда в `point` (0–360°) или nil: точка не у линии, или до неё
    /// по маршруту меньше `laneApproachMinMeters` (старт — подъезда нет).
    /// `estimatedAlong` — оценка «от старта» по шагам OSRM.
    mutating func approachBearing(to point: CLLocationCoordinate2D,
                                  estimatedAlong: CLLocationDistance) -> Double? {
        let n = path.count
        guard n >= 2 else { return nil }
        let expected = lastAlong + max(0, estimatedAlong - lastEstimate)
        let limit = expected + AppConfig.laneProbeSearchMeters
        var best: (index: Int, along: Double, t: Double, miss: Double, distance: Double)?
        var i = segment
        while i < n - 1, cumulative[i] <= limit {
            let (t, distance) = Self.closest(point, path[i], path[i + 1])
            if distance <= AppConfig.laneProbeOnPathMeters {
                let along = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
                let miss = abs(along - expected)
                if best.map({ miss < $0.miss || (miss == $0.miss && distance < $0.distance) }) ?? true {
                    best = (i, along, t, miss, distance)
                }
            }
            i += 1
        }
        guard let best else { return nil }
        segment = best.index
        lastAlong = best.along
        lastEstimate = estimatedAlong
        guard best.along >= AppConfig.laneApproachMinMeters else { return nil }
        let at = Self.interpolate(path[best.index], path[best.index + 1], best.t)
        let back = self.point(at: max(0, best.along - AppConfig.laneApproachBearingMeters), upTo: best.index)
        return GeoMath.bearing(from: back, to: at)
    }

    /// Точка линии на расстоянии `along` от старта (сегменты до `last`).
    private func point(at along: Double, upTo last: Int) -> CLLocationCoordinate2D {
        var lo = 0, hi = last
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= along { lo = mid } else { hi = mid - 1 }
        }
        let length = cumulative[lo + 1] - cumulative[lo]
        let t = length > 0 ? min(1, max(0, (along - cumulative[lo]) / length)) : 0
        return Self.interpolate(path[lo], path[lo + 1], t)
    }

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                    _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Ближайшая точка отрезка AB к P: параметр 0…1 и расстояние, метры
    /// (локальная плоскость — отрезки маршрута короткие).
    private static func closest(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                                _ b: CLLocationCoordinate2D) -> (t: Double, distance: Double) {
        let scale = cos(a.latitude * .pi / 180)
        let bx = (b.longitude - a.longitude) * 111_320 * scale, by = (b.latitude - a.latitude) * 111_320
        let px = (p.longitude - a.longitude) * 111_320 * scale, py = (p.latitude - a.latitude) * 111_320
        let length2 = bx * bx + by * by
        let t = length2 > 0 ? min(1, max(0, (px * bx + py * by) / length2)) : 0
        let dx = px - bx * t, dy = py - by * t
        return (t, (dx * dx + dy * dy).squareRoot())
    }
}

// MARK: - Применение к маршруту

extension LaneOverlay {

    /// Шаги и проезды маршрута после слоя — и счёт для журнала.
    nonisolated struct Attached: Equatable, Sendable {
        var steps: [RouteStep]
        var notices: [LaneNotice]
        var stats: Stats
    }

    /// «полосы: OSRM N, слой M, край K» — одна строка на маршрут, по ней
    /// видно в реальной поездке, сколько дал слой.
    nonisolated struct Stats: Equatable, Sendable {
        /// Манёвров с рядом от OSRM.
        var osrm = 0
        /// Манёвров с рядом от слоя.
        var overlay = 0
        /// Манёвров без ряда, но с краем по ПДД (20.2).
        var edge = 0
        /// Проездов прямо с ограничением полос: от OSRM и от слоя.
        var osrmNotices = 0
        var overlayNotices = 0

        var logLine: String {
            "полосы: OSRM \(osrm), слой \(overlay), край \(edge) (проезды: OSRM \(osrmNotices), слой \(overlayNotices))"
        }
    }

    /// Приложить слой к маршруту. Сначала снимается всё, что слой приложил
    /// раньше (новый слой, или пульт его выключил — `overlay` nil), потом
    /// заново — только туда, где нет полос OSRM: OSRM главнее всегда.
    /// Проезд прямо получает ряд, только если в нём есть и подходящие, и
    /// неподходящие полосы — то же правило, что у рядов OSRM.
    nonisolated static func attach(steps: [RouteStep], notices: [LaneNotice], probes: [LaneProbe],
                       overlay: LaneOverlay?) -> Attached {
        var steps = steps.map { step -> RouteStep in
            guard step.laneSource == .overlay else { return step }
            var cleared = step
            cleared.lanes = []
            cleared.laneSource = .osrm
            return cleared
        }
        var notices = notices.filter { $0.source != .overlay }
        if let overlay {
            for probe in probes {
                switch probe.target {
                case .step(let index):
                    guard steps.indices.contains(index), steps[index].lanes.isEmpty,
                          let hints = overlay.lanes(at: probe.coordinate, approachBearing: probe.approachBearing,
                                                    maneuver: probe.maneuver) else { continue }
                    steps[index].lanes = hints
                    steps[index].laneSource = .overlay
                case .passage(let along):
                    guard let hints = overlay.lanes(at: probe.coordinate, approachBearing: probe.approachBearing,
                                                    maneuver: nil),
                          hints.contains(where: \.isValid), hints.contains(where: { !$0.isValid }) else { continue }
                    notices.append(LaneNotice(distanceAlong: along, lanes: hints, source: .overlay))
                }
            }
            // Ближайшее ограничение ищется первым подходящим — порядок по ходу.
            notices.sort { $0.distanceAlong < $1.distanceAlong }
        }
        var stats = Stats()
        for step in steps {
            if !step.lanes.isEmpty {
                if step.laneSource == .overlay { stats.overlay += 1 } else { stats.osrm += 1 }
            } else if step.edge != nil {
                stats.edge += 1
            }
        }
        for notice in notices {
            if notice.source == .overlay { stats.overlayNotices += 1 } else { stats.osrmNotices += 1 }
        }
        return Attached(steps: steps, notices: notices, stats: stats)
    }
}

// MARK: - Доверие

/// Индекс → файл → слой: одна цепочка и для сети, и для КАЖДОГО чтения с
/// диска. Подпись — SignedPayload (единственный проверяющий, правило 19),
/// дальше схема индекса, размер и sha файла, разбор.
nonisolated enum LaneOverlayTrust {

    nonisolated enum Rejection: Error, Equatable, Sendable {
        case notEnvelope
        case signature
        case schema
        case missingFile
        case size(expected: Int, actual: Int)
        case sha
        case data(LaneOverlay.Failure)

        var logDescription: String {
            switch self {
            case .notEnvelope: "не конверт SignedPayload"
            case .signature: "подпись не сошлась"
            case .schema: "индекс не по контракту"
            case .missingFile: "файла нет"
            case .size(let expected, let actual): "размер \(actual) вместо \(expected)"
            case .sha: "sha256 не сошёлся с индексом"
            case .data(let failure): failure.logDescription
            }
        }
    }

    /// Подписанный индекс: конверт → подпись → схема.
    static func verifyIndex(_ data: Data, publicKeyB64: String = AppConfig.otaPublicKeyB64)
        -> Result<(manifest: LanesManifest, file: LanesManifest.File), Rejection> {
        let envelope: SignedPayload<LanesManifest>
        do {
            envelope = try JSONDecoder().decode(SignedPayload<LanesManifest>.self, from: data)
        } catch {
            return .failure(.notEnvelope)
        }
        switch envelope.verify(publicKeyB64: publicKeyB64) {
        case .failure(.payloadNotBase64): return .failure(.notEnvelope)
        case .failure(.signature): return .failure(.signature)
        case .failure(.json): return .failure(.schema)
        case .success(let manifest):
            guard let file = manifest.usableFile else { return .failure(.schema) }
            return .success((manifest, file))
        }
    }

    /// Файл против индекса: размер (дёшево), потом sha ровно этих байтов.
    static func verifyData(_ data: Data, against file: LanesManifest.File) -> Rejection? {
        guard data.count == file.bytes else { return .size(expected: file.bytes, actual: data.count) }
        guard RoadTiles.sha256Hex(of: data) == file.sha256 else { return .sha }
        return nil
    }

    /// Вся цепочка: индекс, байты файла по его имени, разбор. Любой сбой —
    /// слоя нет (fail closed), причина — в журнал у вызывающего.
    static func overlay(index: Data, file read: (String) -> Data?,
                        publicKeyB64: String = AppConfig.otaPublicKeyB64)
        -> Result<(version: Int, overlay: LaneOverlay), Rejection> {
        let verified: (manifest: LanesManifest, file: LanesManifest.File)
        switch verifyIndex(index, publicKeyB64: publicKeyB64) {
        case .failure(let why): return .failure(why)
        case .success(let value): verified = value
        }
        guard let bytes = read(verified.file.name) else { return .failure(.missingFile) }
        if let why = verifyData(bytes, against: verified.file) { return .failure(why) }
        switch LaneOverlay.decode(bytes) {
        case .failure(let failure): return .failure(.data(failure))
        case .success(let overlay): return .success((verified.manifest.version, overlay))
        }
    }
}
