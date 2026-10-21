//
//  LaneOverlayTests.swift
//  RadarMapTests
//
//  Слой полос (20.8). Контракт с сервером — образец данных из
//  server/fixtures/lanes_overlay_sample.json читается отсюда же (#filePath):
//  поменяется форма образца — упадёт тест, и телефон с сервером не
//  разъедутся молча. Остальное — что НЕ должно случиться: чужой подход
//  (встречный, далёкий, поперечный) дал ряд, полосы OSRM перекрыты слоем,
//  подменённый файл или чужая подпись приняты.
//
//  Подписи — от одноразовых ключей теста: ключ владельца живёт у него.
//

import CoreLocation
import CryptoKit
import XCTest
@testable import RadarMap

final class LaneOverlayTests: XCTestCase {

    // MARK: - Образец контракта

    private var sampleURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/fixtures/lanes_overlay_sample.json")
    }

    private func sample() throws -> Data { try Data(contentsOf: sampleURL) }

    /// Словарь стрелок контракта (docs/lanes_overlay_contract.md).
    private let vocabulary = ["left", "slight left", "sharp left", "straight", "slight right", "right",
                              "sharp right", "uturn", "merge to left", "merge to right", "none"]

    func testContractVocabularyIsUnderstood() {
        for word in vocabulary {
            XCTAssertNotNil(LaneArrow.fromOSRM(word), "«\(word)» из словаря контракта не понят телефоном")
        }
    }

    func testContractSampleDecodes() throws {
        let overlay = try LaneOverlay.decode(sample()).get()
        XCTAssertEqual(overlay.count, 3)
        XCTAssertEqual(overlay.dropped, 0, "в образце нет плохих записей — телефон обязан принять все")
        XCTAssertEqual(overlay.generated, 1_792_560_000)
        let first = try XCTUnwrap(overlay.junctions.first { $0.id == "tash-0001" })
        XCTAssertEqual(first.latitude, 41.31102)
        XCTAssertEqual(first.longitude, 69.27951)
        XCTAssertEqual(first.bearing, 352)
        XCTAssertEqual(first.tolerance, 30)
        XCTAssertEqual(first.lanes, [[.left], [.left, .straight], [.straight], [.straight], [.straight, .right]])
        let uturn = try XCTUnwrap(overlay.junctions.first { $0.id == "tash-0002" })
        XCTAssertEqual(uturn.lanes.first, [.uturn, .left])
        XCTAssertEqual(overlay.junctions.first { $0.id == "tash-0003" }?.tolerance, 25)
    }

    /// Форма образца — ровно та, что разбирает телефон. Новое поле, другое
    /// имя или чужая стрелка на сервере — сначала сюда и в LaneOverlay.
    func testContractSampleShapeIsPinned() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sample()) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["v", "generated", "junctions"])
        XCTAssertEqual(root["v"] as? Int, LanesManifest.dataFormat)
        let junctions = try XCTUnwrap(root["junctions"] as? [[String: Any]])
        XCTAssertFalse(junctions.isEmpty)
        for junction in junctions {
            XCTAssertEqual(Set(junction.keys), ["id", "lat", "lon", "bearing", "tolerance", "lanes", "src", "checked"],
                           "форма записи разошлась с контрактом")
            XCTAssertTrue(["osm", "survey", "dashcam", "vendor"].contains(junction["src"] as? String ?? ""))
            let lanes = try XCTUnwrap(junction["lanes"] as? [String])
            for lane in lanes {
                for arrow in lane.split(separator: ";") {
                    XCTAssertTrue(vocabulary.contains(String(arrow)), "стрелка «\(arrow)» вне словаря")
                }
            }
        }
    }

    // MARK: - Разбор: плохие записи — по одной, плохой файл — целиком

    private func file(_ records: [String]) -> Data {
        Data(#"{"v":1,"generated":1792560000,"junctions":[\#(records.joined(separator: ","))]}"#.utf8)
    }

    private func record(id: String = "t", lat: String = "41.31", lon: String = "69.27",
                        bearing: String = "90", tolerance: String? = "30",
                        lanes: String = #"["left","straight"]"#) -> String {
        let tol = tolerance.map { #","tolerance":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","lat":\#(lat),"lon":\#(lon),"bearing":\#(bearing)\#(tol),"lanes":\#(lanes),"src":"osm","checked":"2026-10-21"}"#
    }

    func testInvalidRecordsAreDroppedOneByOne() throws {
        let data = file([
            record(id: "good"),
            record(id: "word", lanes: #"["left","diagonal"]"#),
            record(id: "none", lanes: "[]"),
            record(id: "nine", lanes: #"["straight","straight","straight","straight","straight","straight","straight","straight","straight"]"#),
            record(id: "abroad", lat: "50.1"),
            record(id: "wide", tolerance: "60"),
            record(id: "zero", tolerance: "0"),
            record(id: "full-circle", bearing: "360"),
            record(id: "negative", bearing: "-5"),
            record(id: "blank-lane", lanes: #"["left",""]"#),
            record(id: "blank-arrow", lanes: #"["left;;straight"]"#),
            record(id: "type", bearing: #""north""#),
            record(id: ""),
            #"{"lat":41.3}"#,
        ])
        let overlay = try LaneOverlay.decode(data).get()
        XCTAssertEqual(overlay.junctions.map(\.id), ["good"])
        XCTAssertEqual(overlay.dropped, 13)
    }

    func testEdgesOfTheContractAreAccepted() throws {
        let data = file([
            record(id: "eight", lanes: #"["left","straight","straight","straight","straight","straight","straight","right"]"#),
            record(id: "one", lanes: #"["none"]"#),
            record(id: "tight", bearing: "359", tolerance: "45"),
            record(id: "default", tolerance: nil),
            record(id: "spaced", lanes: #"["left; straight"]"#),
        ])
        let overlay = try LaneOverlay.decode(data).get()
        XCTAssertEqual(overlay.count, 5, "края контракта — не повод отбрасывать")
        XCTAssertEqual(overlay.junctions.first { $0.id == "default" }?.tolerance,
                       AppConfig.laneOverlayDefaultTolerance)
        XCTAssertEqual(overlay.junctions.first { $0.id == "one" }?.lanes, [[.straight]], "«none» — прямо")
    }

    func testWholeFileRejectedOnlyForFileLevelDefects() {
        XCTAssertEqual(LaneOverlay.decode(Data("не json".utf8)).failure, .json)
        XCTAssertEqual(LaneOverlay.decode(Data(#"{"v":2,"junctions":[]}"#.utf8)).failure, .format(2))
        let tooMany = Data((#"{"v":1,"junctions":["# + Array(repeating: "{}", count: AppConfig.laneOverlayMaxJunctions + 1)
            .joined(separator: ",") + "]}").utf8)
        XCTAssertEqual(LaneOverlay.decode(tooMany).failure, .tooMany(AppConfig.laneOverlayMaxJunctions + 1))
    }

    // MARK: - Поиск подхода

    private let center = CLLocationCoordinate2D(latitude: 41.31102, longitude: 69.27951)

    private func overlay(_ junctions: [LaneOverlay.Junction]) -> LaneOverlay {
        LaneOverlay(junctions: junctions)
    }

    private func junction(_ id: String = "j", at point: CLLocationCoordinate2D? = nil, bearing: Double = 352,
                          tolerance: Double = 30,
                          lanes: [[LaneArrow]] = [[.left], [.left, .straight], [.straight], [.straight], [.straight, .right]])
        -> LaneOverlay.Junction {
        let point = point ?? center
        return LaneOverlay.Junction(id: id, latitude: point.latitude, longitude: point.longitude,
                                    bearing: bearing, tolerance: tolerance, lanes: lanes)
    }

    private func moved(_ meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(from: center, bearing: bearing, distanceMeters: meters)
    }

    func testMatchWithinTwentyFiveMetres() {
        let layer = overlay([junction()])
        XCTAssertNotNil(layer.junction(at: moved(20, bearing: 90), approachBearing: 352))
        XCTAssertNil(layer.junction(at: moved(30, bearing: 90), approachBearing: 352),
                     "30 м — уже соседний перекрёсток или дублёр")
    }

    func testBearingToleranceAndWrapAround() {
        let layer = overlay([junction(tolerance: 30)])
        XCTAssertNotNil(layer.junction(at: center, approachBearing: 20), "352 и 20 — 28°, через север")
        XCTAssertNil(layer.junction(at: center, approachBearing: 25), "33° — вне допуска")
        let tight = overlay([junction(bearing: 90, tolerance: 10)])
        XCTAssertNotNil(tight.junction(at: center, approachBearing: 99))
        XCTAssertNil(tight.junction(at: center, approachBearing: 101))
    }

    func testWrongApproachDirectionIsNoMatch() {
        let layer = overlay([junction(bearing: 352)])
        XCTAssertNil(layer.junction(at: center, approachBearing: 172), "встречный подход — другие полосы")
        XCTAssertNil(layer.junction(at: center, approachBearing: 82), "поперечный подход — другие полосы")
        XCTAssertNil(layer.junction(at: center, approachBearing: -1), "курса нет — подхода нет")
    }

    func testOwnApproachOfTheSameJunctionWins() {
        let layer = overlay([
            junction("north", bearing: 0, lanes: [[.left], [.straight]]),
            junction("south", bearing: 180, lanes: [[.uturn], [.straight], [.right]]),
            junction("east", bearing: 90, lanes: [[.left, .straight], [.right]]),
        ])
        XCTAssertEqual(layer.junction(at: center, approachBearing: 5)?.id, "north")
        XCTAssertEqual(layer.junction(at: center, approachBearing: 185)?.id, "south")
        XCTAssertEqual(layer.junction(at: center, approachBearing: 80)?.id, "east")
    }

    func testNearestOfTwoMatchingApproachesWins() {
        let layer = overlay([junction("far", at: moved(20, bearing: 0)), junction("near", at: moved(5, bearing: 180))])
        XCTAssertEqual(layer.junction(at: center, approachBearing: 352)?.id, "near")
    }

    func testCellBordersDoNotHideAJunction() {
        // Точка в соседней ячейке сетки (0.001°): поиск обязан смотреть девять ячеек.
        let border = CLLocationCoordinate2D(latitude: 41.31, longitude: 69.27)
        let layer = overlay([junction(at: CLLocationCoordinate2D(latitude: 41.30999, longitude: 69.26999))])
        XCTAssertNotNil(layer.junction(at: border, approachBearing: 352))
        XCTAssertNotNil(layer.junction(at: CLLocationCoordinate2D(latitude: 41.31001, longitude: 69.27001),
                                       approachBearing: 352))
    }

    // MARK: - Какие полосы «наши»

    private func valid(_ lanes: [[LaneArrow]], _ maneuver: ManeuverKind?) -> [Bool]? {
        LaneOverlay.hints(lanes, maneuver: maneuver)?.map(\.isValid)
    }

    private let fiveLanes: [[LaneArrow]] = [[.left], [.left, .straight], [.straight], [.straight], [.straight, .right]]

    func testValidityBySideOfTheManeuver() throws {
        XCTAssertEqual(valid(fiveLanes, .left), [true, true, false, false, false])
        XCTAssertEqual(valid(fiveLanes, .right), [false, false, false, false, true])
        XCTAssertEqual(valid(fiveLanes, .sharpLeft), [true, true, false, false, false],
                       "точной стрелки нет — годится любая налево")
        let hints = try XCTUnwrap(LaneOverlay.hints(fiveLanes, maneuver: .left))
        XCTAssertEqual(LaneAdvice.phrase(hints), String(localized: "Из двух левых рядов"))
    }

    func testStraightThroughNeedsAStraightArrow() throws {
        XCTAssertEqual(valid(fiveLanes, nil), [false, true, true, true, true])
        XCTAssertEqual(valid(fiveLanes, .straight), [false, true, true, true, true])
        let hints = try XCTUnwrap(LaneOverlay.hints(fiveLanes, maneuver: nil))
        XCTAssertEqual(LaneAdvice.phrase(hints), String(localized: "Из любого ряда, кроме левого"))
    }

    func testExactArrowBeatsTheSide() {
        let lanes: [[LaneArrow]] = [[.sharpLeft], [.left], [.straight]]
        XCTAssertEqual(valid(lanes, .left), [false, true, false], "налево — не с полосы «круто налево»")
        XCTAssertEqual(valid(lanes, .sharpLeft), [true, false, false])
        XCTAssertEqual(valid(lanes, .slightLeft), [true, true, false], "плавной нет — любая налево")
    }

    func testUturnFromUturnLaneOrFromLeftmostLeft() {
        XCTAssertEqual(valid([[.uturn, .left], [.straight], [.straight, .right]], .uturn), [true, false, false])
        XCTAssertEqual(valid([[.left], [.uturn], [.straight]], .uturn), [false, true, false],
                       "есть стрелка разворота — только она")
        XCTAssertEqual(valid([[.left], [.left, .straight], [.straight]], .uturn), [true, false, false],
                       "без стрелки разворота — крайний левый поворотный ряд")
        XCTAssertNil(valid([[.straight], [.straight, .right]], .uturn),
                     "крайняя левая — не поворотная: развернуться неоткуда, ряда нет")
    }

    func testNoValidLaneMeansNoRow() {
        XCTAssertNil(valid([[.left], [.straight]], .right), "ряд против маршрута — не наш подход")
        XCTAssertNil(valid([[.left], [.right]], nil))
        XCTAssertNil(valid(fiveLanes, .roundabout), "ряд на кольце — по съезду, не по стрелкам")
        XCTAssertNil(valid(fiveLanes, .arrive))
    }

    // MARK: - Приложение к маршруту: OSRM главнее

    private func step(_ along: Double, kind: ManeuverKind, lanes: [LaneHint] = [],
                      edge: LaneAdvice.Edge? = nil) -> RouteStep {
        RouteStep(distanceAlong: along, text: "поверните", icon: "arrow.up", kind: kind, lanes: lanes, edge: edge)
    }

    private func probe(_ target: LaneProbe.Target, at point: CLLocationCoordinate2D? = nil,
                       bearing: Double = 352, maneuver: ManeuverKind?) -> LaneProbe {
        let point = point ?? center
        return LaneProbe(target: target, latitude: point.latitude, longitude: point.longitude,
                         approachBearing: bearing, maneuver: maneuver)
    }

    func testOsrmLanesTakePrecedence() {
        let osrm = [LaneHint(arrows: [.left], isValid: true), LaneHint(arrows: [.straight], isValid: false)]
        let steps = [step(100, kind: .left, lanes: osrm, edge: .left),
                     step(500, kind: .left, edge: .left),
                     step(900, kind: .right, edge: .right)]
        let layer = overlay([junction()])
        // Точка спроса и у шага с полосами OSRM: слой всё равно не вправе их заменить.
        let attached = LaneOverlay.attach(steps: steps, notices: [],
                                          probes: [probe(.step(0), maneuver: .left), probe(.step(1), maneuver: .left)],
                                          overlay: layer)
        XCTAssertEqual(attached.steps[0].lanes, osrm)
        XCTAssertEqual(attached.steps[0].laneSource, .osrm)
        XCTAssertEqual(attached.steps[1].laneSource, .overlay)
        XCTAssertEqual(attached.steps[1].lanes.map(\.isValid), [true, true, false, false, false])
        XCTAssertEqual(attached.steps[1].laneAdvice, .lanes(.leftTwo), "дальше — как с полосами OSRM")
        XCTAssertTrue(attached.steps[2].lanes.isEmpty)
        XCTAssertEqual(attached.stats, LaneOverlay.Stats(osrm: 1, overlay: 1, edge: 1))
        XCTAssertEqual(RouteService.laneLogLine(attached.stats, overlay: layer),
                       "полосы: OSRM 1, слой 1, край 1 (проезды: OSRM 0, слой 0), слой: 1 подходов")
    }

    func testReattachReplacesOnlyOverlayLanes() {
        let osrm = [LaneHint(arrows: [.right], isValid: true), LaneHint(arrows: [.straight], isValid: false)]
        let steps = [step(100, kind: .right, lanes: osrm), step(500, kind: .left, edge: .left)]
        let probes = [probe(.step(1), maneuver: .left)]
        let first = LaneOverlay.attach(steps: steps, notices: [], probes: probes, overlay: overlay([junction()]))
        XCTAssertEqual(first.steps[1].laneSource, .overlay)
        // Пульт снял слой: ряд слоя уходит, ряд OSRM остаётся, край — снова край.
        let cleared = LaneOverlay.attach(steps: first.steps, notices: first.notices, probes: probes, overlay: nil)
        XCTAssertTrue(cleared.steps[1].lanes.isEmpty)
        XCTAssertEqual(cleared.steps[0].lanes, osrm)
        XCTAssertEqual(cleared.stats, LaneOverlay.Stats(osrm: 1, overlay: 0, edge: 1))
        // Новая версия слоя — ряды по ней, а не поверх старых.
        let newer = overlay([junction(lanes: [[.left], [.straight], [.straight]])])
        let again = LaneOverlay.attach(steps: first.steps, notices: first.notices, probes: probes, overlay: newer)
        XCTAssertEqual(again.steps[1].lanes.map(\.isValid), [true, false, false])
    }

    func testPassageGetsANoticeOnlyWhenSomeLanesDoNotFit() {
        let osrmNotice = LaneNotice(distanceAlong: 700, lanes: [LaneHint(arrows: [.straight], isValid: true),
                                                                LaneHint(arrows: [.right], isValid: false)])
        let elsewhere = moved(500, bearing: 90)
        let layer = overlay([junction(), junction("all", at: elsewhere, lanes: [[.straight], [.straight, .right]])])
        let attached = LaneOverlay.attach(steps: [], notices: [osrmNotice],
                                          probes: [probe(.passage(900), maneuver: nil),
                                                   probe(.passage(300), at: elsewhere, maneuver: nil)],
                                          overlay: layer)
        XCTAssertEqual(attached.notices.map(\.distanceAlong), [700, 900], "по ходу; «подходят все» — не ограничение")
        XCTAssertEqual(attached.notices.map(\.source), [.osrm, .overlay])
        XCTAssertEqual(LaneAdvice.phrase(attached.notices[1].lanes), String(localized: "Из любого ряда, кроме левого"))
        XCTAssertEqual(attached.stats.osrmNotices, 1)
        XCTAssertEqual(attached.stats.overlayNotices, 1)
        let cleared = LaneOverlay.attach(steps: [], notices: attached.notices, probes: [], overlay: nil)
        XCTAssertEqual(cleared.notices, [osrmNotice])
    }

    // MARK: - Точки спроса из ответа OSRM

    private typealias R = RouteService.OSRMResponse

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Север 222 м через перекрёсток M, налево на J, запад 250 м до E.
    private let s = (41.300, 69.250), m = (41.301, 69.250), j = (41.302, 69.250), e = (41.302, 69.247)

    private func osrmSteps(turnLanes: [R.Lane]? = nil) -> [R.Step] {
        [R.Step(distance: 222.6, name: "",
                maneuver: R.Maneuver(type: "depart", modifier: nil, exit: nil, location: [s.1, s.0]),
                intersections: [R.Intersection(lanes: nil, location: [s.1, s.0]),
                                R.Intersection(lanes: nil, location: [m.1, m.0])]),
         R.Step(distance: 250, name: "",
                maneuver: R.Maneuver(type: "turn", modifier: "left", exit: nil, location: [j.1, j.0]),
                intersections: [R.Intersection(lanes: turnLanes, location: [j.1, j.0])]),
         R.Step(distance: 0, name: "",
                maneuver: R.Maneuver(type: "arrive", modifier: nil, exit: nil, location: [e.1, e.0]),
                intersections: [R.Intersection(lanes: nil, location: [e.1, e.0])])]
    }

    private func collect(_ osrm: [R.Step]) -> (steps: [RouteStep], probes: [LaneProbe]) {
        var collector = RouteService.LaneProbeCollector(path: [c(s.0, s.1), c(m.0, m.1), c(j.0, j.1), c(e.0, e.1)])
        var steps: [RouteStep] = []
        var along = 0.0
        for step in osrm {
            let built = RouteService.maneuverStep(step, at: along, language: "ru")
            collector.add(step, at: along, built: built, index: steps.count)
            if let built { steps.append(built) }
            along += step.distance
        }
        return (steps, collector.probes)
    }

    func testProbesAtManeuverAndPassageWithApproachBearing() throws {
        let (steps, probes) = collect(osrmSteps())
        XCTAssertEqual(steps.map(\.kind), [.left, .arrive])
        XCTAssertEqual(probes.count, 2, "проезд M и поворот J; старт без подъезда, финиш — не манёвр")
        let passage = try XCTUnwrap(probes.first { if case .passage = $0.target { true } else { false } })
        XCTAssertEqual(passage.latitude, m.0)
        XCTAssertNil(passage.maneuver)
        XCTAssertLessThan(GeoMath.angleDifference(passage.approachBearing, 0), 1)
        let turn = try XCTUnwrap(probes.first { $0.target == .step(0) })
        XCTAssertEqual(turn.maneuver, .left)
        XCTAssertLessThan(GeoMath.angleDifference(turn.approachBearing, 0), 1,
                          "курс въезда — по линии ДО манёвра, а не после поворота")
    }

    func testOsrmLanesAtTheTurnMeanNoProbe() {
        let lanes = [R.Lane(valid: true, indications: ["left"]), R.Lane(valid: false, indications: ["straight"])]
        let (steps, probes) = collect(osrmSteps(turnLanes: lanes))
        XCTAssertFalse(steps[0].lanes.isEmpty)
        XCTAssertFalse(probes.contains { $0.target == .step(0) }, "у OSRM есть полосы — слой не спрашиваем")
    }

    func testProbeToAttachEndToEnd() throws {
        let (steps, probes) = collect(osrmSteps())
        let layer = overlay([junction("J", at: c(j.0, j.1), bearing: 0, lanes: [[.left], [.straight], [.straight]]),
                             junction("J-south", at: c(j.0, j.1), bearing: 180, lanes: [[.straight], [.right]])])
        let attached = LaneOverlay.attach(steps: steps, notices: [], probes: probes, overlay: layer)
        XCTAssertEqual(attached.steps[0].laneSource, .overlay)
        XCTAssertEqual(attached.steps[0].laneAdvice, .lanes(.leftOne))
        XCTAssertNil(attached.steps[1].laneAdvice, "финиш без ряда")
    }

    func testCursorTellsTheWayBackFromTheWayThere() throws {
        // Север 222 м и обратно по той же оси: на обратном пути точка та же,
        // а курс — встречный.
        var cursor = RoutePathCursor(path: [c(41.300, 69.25), c(41.302, 69.25), c(41.3005, 69.25)])
        let point = c(41.301, 69.25)
        let there = try XCTUnwrap(cursor.approachBearing(to: point, estimatedAlong: 111))
        XCTAssertLessThan(GeoMath.angleDifference(there, 0), 1)
        let back = try XCTUnwrap(cursor.approachBearing(to: point, estimatedAlong: 333))
        XCTAssertLessThan(GeoMath.angleDifference(back, 180), 1)
    }

    func testCursorRefusesOffPathAndTheStart() {
        var cursor = RoutePathCursor(path: [c(41.300, 69.25), c(41.302, 69.25)])
        XCTAssertNil(cursor.approachBearing(to: c(41.30005, 69.25), estimatedAlong: 6), "6 м от старта — подъезда нет")
        XCTAssertNil(cursor.approachBearing(to: c(41.301, 69.2505), estimatedAlong: 111), "42 м от линии — не наша точка")
        XCTAssertNotNil(cursor.approachBearing(to: c(41.301, 69.25005), estimatedAlong: 111))
    }

    // MARK: - Индекс и доверие

    private let key = Curve25519.Signing.PrivateKey()
    private var publicKeyB64: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func index(for data: Data, name: String? = nil, bytes: Int? = nil, format: Int = 1,
                       version: Int = 3) throws -> Data {
        let sha = RoadTiles.sha256Hex(of: data)
        let payload = try JSONSerialization.data(withJSONObject: [
            "format": format, "version": version,
            "files": [["format": 1, "name": name ?? "lanes.\(sha.prefix(16)).json",
                       "sha256": sha, "bytes": bytes ?? data.count]],
        ])
        return try envelope(payload)
    }

    private func envelope(_ payload: Data, signedBy signer: Curve25519.Signing.PrivateKey? = nil,
                          signed: Bool = true) throws -> Data {
        var object: [String: Any] = ["payload": payload.base64EncodedString()]
        if signed { object["sig"] = try (signer ?? key).signature(for: payload).base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func load(_ index: Data, _ files: [String: Data]) -> Result<(version: Int, overlay: LaneOverlay),
                                                                        LaneOverlayTrust.Rejection> {
        LaneOverlayTrust.overlay(index: index, file: { files[$0] }, publicKeyB64: publicKeyB64)
    }

    private func name(_ data: Data) -> String { "lanes.\(RoadTiles.sha256Hex(of: data).prefix(16)).json" }

    func testSignedSetLoads() throws {
        let data = try sample()
        let loaded = try load(index(for: data), [name(data): data]).get()
        XCTAssertEqual(loaded.version, 3)
        XCTAssertEqual(loaded.overlay.count, 3)
    }

    func testTamperedDataIsRejected() throws {
        let data = try sample()
        var tampered = data
        let at = try XCTUnwrap(tampered.firstIndex(of: UInt8(ascii: "5")))
        tampered[at] = UInt8(ascii: "6")   // одна цифра: размер тот же, sha другой
        XCTAssertEqual(load(try index(for: data), [name(data): tampered]).failure, .sha)
    }

    func testWrongSizeIsRejected() throws {
        let data = try sample()
        XCTAssertEqual(load(try index(for: data), [name(data): data + Data(" ".utf8)]).failure,
                       .size(expected: data.count, actual: data.count + 1))
    }

    func testForeignKeyAndUnsignedIndexAreRejected() throws {
        let data = try sample()
        let sha = RoadTiles.sha256Hex(of: data)
        let payload = try JSONSerialization.data(withJSONObject: [
            "format": 1, "version": 3,
            "files": [["format": 1, "name": name(data), "sha256": sha, "bytes": data.count]],
        ])
        XCTAssertEqual(load(try envelope(payload, signedBy: Curve25519.Signing.PrivateKey()), [name(data): data]).failure,
                       .signature, "чужой ключ")
        XCTAssertEqual(load(try envelope(payload, signed: false), [name(data): data]).failure, .signature, "без подписи")
        // Подпись от одного payload, а в конверте — другой (подменили версию).
        let other = try JSONSerialization.data(withJSONObject: ["format": 1, "version": 9, "files": []])
        let forged = try JSONSerialization.data(withJSONObject: [
            "payload": other.base64EncodedString(),
            "sig": try key.signature(for: payload).base64EncodedString(),
        ])
        XCTAssertEqual(load(forged, [name(data): data]).failure, .signature)
        XCTAssertEqual(load(Data("{}".utf8), [:]).failure, .notEnvelope)
    }

    func testIndexOutsideTheContractIsRejected() throws {
        let data = try sample()
        XCTAssertEqual(load(try index(for: data, name: "../lanes.x.json"), [:]).failure, .schema)
        XCTAssertEqual(load(try index(for: data, name: "routes.x.json"), [:]).failure, .schema, "не файл слоя")
        XCTAssertEqual(load(try index(for: data, bytes: AppConfig.laneOverlayMaxBytes + 1), [:]).failure, .schema)
        XCTAssertEqual(load(try index(for: data, format: 2), [:]).failure, .schema)
        XCTAssertEqual(load(try index(for: data, version: 0), [:]).failure, .schema)
        XCTAssertEqual(load(try index(for: data), [:]).failure, .missingFile)
    }

    func testSignedButUnreadableFileIsNoOverlay() throws {
        let garbage = Data("не json, но подписан честно".utf8)
        XCTAssertEqual(load(try index(for: garbage), [name(garbage): garbage]).failure, .data(.json))
    }

    func testManifestUsableFileRules() throws {
        func manifest(_ json: String) throws -> LanesManifest {
            try JSONDecoder().decode(LanesManifest.self, from: Data(json.utf8))
        }
        let sha = String(repeating: "a", count: 64)
        XCTAssertNotNil(try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"lanes.0123456789abcdef.json","sha256":"\#(sha)","bytes":123456}]}"#).usableFile)
        XCTAssertNil(try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"lanes.x.json","sha256":"\#(sha.uppercased())","bytes":100}]}"#).usableFile,
                     "заглавный hex не сойдётся никогда")
        XCTAssertNil(try manifest(#"{"format":1,"version":3,"files":[{"format":2,"name":"lanes.x.json","sha256":"\#(sha)","bytes":100}]}"#).usableFile,
                     "чужой формат данных")
        XCTAssertNil(try manifest(#"{"format":1,"version":3,"files":[{"format":1,"name":"sub/lanes.x.json","sha256":"\#(sha)","bytes":100}]}"#).usableFile)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
