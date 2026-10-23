//
//  CameraZoneTests.swift
//  RadarMapTests
//
//  Зона камеры на асфальте (28.B). Что проверяем:
//    • цель — первая впереди на маршруте (встречный близнец и проехавшая —
//      нет), без маршрута — ближайшая HUD;
//    • лента — 80 м её проезжей части ПЕРЕД камерой по ходу, кончается под
//      значком (и там, куда значок перенесён);
//    • без доказательства — ничего: нет куска дороги, профиль не доверен,
//      неточная координата, пост ДПС, курс неизвестен, поперёк, против
//      односторонней проезжей части, огрызок дороги перед камерой;
//    • источник не переписывается на шевелении значка;
//    • цвет читается на полотне любого класса в обеих темах и не путается
//      с линией маршрута;
//    • ТОЛЬКО картинка: конвейер оповещений зону не читает.
//

import XCTest
import MapKit
import CoreLocation
@testable import RadarMap

final class CameraZoneTests: XCTestCase {

    private typealias Zone = CameraZone

    private let origin = CLLocationCoordinate2D(latitude: 41.3330, longitude: 69.2190)

    /// Кусок дороги через камеру: точки по азимуту `bearing` от −`before` до
    /// +`after` м (в порядке возрастания), шаг 20 м — дельты 1e-6°, как в базе.
    private func road(at camera: CLLocationCoordinate2D, bearing: Double,
                      before: Double = 100, after: Double = 100) -> [Int] {
        var out: [Int] = []
        for along in stride(from: -before, through: after, by: 20) {
            let p = GeoMath.destination(from: camera, bearing: along < 0 ? bearing + 180 : bearing,
                                        distanceMeters: abs(along))
            out += [Int(((p.latitude - camera.latitude) * 1e6).rounded()),
                    Int(((p.longitude - camera.longitude) * 1e6).rounded())]
        }
        return out
    }

    private func camera(_ id: Int = 1, at coordinate: CLLocationCoordinate2D? = nil,
                        type: String = "Стационар камера", dir: Int? = nil, cls: String? = "primary",
                        lanes: Int? = 3, needsReview: Bool? = nil, road: [Int]?? = nil,
                        roadBearing: Double = 90) -> Camera {
        let at = coordinate ?? origin
        return Camera(id: id, region: "Toshkent shahar", city: "Olmazor tumani", location: "Тест \(id)",
                      lat: at.latitude, lon: at.longitude, type: type, violations: [],
                      needsReview: needsReview, axis: Int(roadBearing.truncatingRemainder(dividingBy: 180)),
                      dir: dir, lanes: lanes, cls: cls,
                      road: road ?? self.road(at: at, bearing: roadBearing),
                      split: dir == nil ? nil : true, twin: nil)
    }

    private func distance(_ a: CameraOnLine.Point, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    private func length(_ points: [CameraOnLine.Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + GeoMath.fastDistance($1.0.latitude, $1.0.longitude, $1.1.latitude, $1.1.longitude)
        }
    }

    // MARK: - Цель

    func testRouteTargetIsTheFirstCameraAheadThatIsOurs() {
        let route: [(id: Int, along: Double)] = [(1, 300), (2, 900), (3, 500), (4, 120)]
        let notOurs = CameraOnLine.Spot(point: .init(origin), verdict: .notOurs)
        // Встречный близнец (3) — не цель, проехавшая (4, 80 м позади) — тоже.
        XCTAssertEqual(Zone.target(route: route, spots: [3: notOurs], progress: 200, nearest: 2), 1)
        // Только что проехали (10 м позади, GPS отстаёт от значка) — ещё цель.
        XCTAssertEqual(Zone.target(route: route, spots: [:], progress: 310, nearest: nil), 1)
        // Прошли дальше запаса — следующая.
        XCTAssertEqual(Zone.target(route: route, spots: [3: notOurs], progress: 330, nearest: nil), 2)
        // Всё позади — ничего, ближайшая HUD на маршруте не подменяет линию.
        XCTAssertNil(Zone.target(route: route, spots: [:], progress: 1000, nearest: 2))
    }

    func testWithoutRouteTheTargetIsTheHUDCamera() {
        XCTAssertEqual(Zone.target(route: [(1, 300)], spots: [:], progress: nil, nearest: 7), 7)
        XCTAssertNil(Zone.target(route: [], spots: [:], progress: nil, nearest: nil))
    }

    // MARK: - Лента

    func testOneWayZoneLiesBeforeTheCameraAlongTheTraffic() throws {
        // Односторонняя проезжая часть на восток, едем на восток.
        let cam = camera(dir: 90, lanes: 3)
        let band = try XCTUnwrap(Zone.band(camera: cam, heading: 92))
        XCTAssertEqual(band.cameraID, 1)
        // Последняя точка — камера, первая — 80 м западнее (позади по ходу).
        XCTAssertLessThan(distance(band.points.last!, origin), 0.5)
        XCTAssertEqual(length(band.points), AppConfig.cameraZoneMeters, accuracy: 1)
        let start = band.points.first!.coordinate
        XCTAssertLessThan(start.longitude, origin.longitude)
        XCTAssertEqual(GeoMath.bearing(from: start, to: origin), 90, accuracy: 2)
        // Вся проезжая часть (3 полосы × 3,5 м), чуть уже — на асфальте; без сдвига.
        XCTAssertEqual(band.widthMeters, 3 * AppConfig.laneWidthMeters * AppConfig.cameraZoneWidthShare,
                       accuracy: 0.01)
        XCTAssertEqual(band.offsetMeters, 0)
    }

    func testOrderOfRoadPointsDoesNotMatter() throws {
        // Кусок записан с востока на запад — зона всё равно перед камерой по ходу.
        let reversed = camera(dir: 90, roadBearing: 270)
        let band = try XCTUnwrap(Zone.band(camera: reversed, heading: 90))
        XCTAssertLessThan(band.points.first!.longitude, origin.longitude)
        XCTAssertLessThan(distance(band.points.last!, origin), 0.5)
    }

    func testOppositeOneWayCarriagewayGetsNoZone() {
        // Камера на встречной проезжей части разделённой улицы: её полоса — не наша.
        XCTAssertNil(Zone.band(camera: camera(dir: 270), heading: 90))
    }

    func testTwoWayRoadZoneIsOnOurHalfFromOurSide() throws {
        let cam = camera(dir: nil, lanes: 4)
        let east = try XCTUnwrap(Zone.band(camera: cam, heading: 90))
        let west = try XCTUnwrap(Zone.band(camera: cam, heading: 270))
        // Подъезд с запада — зона западнее камеры, с востока — восточнее.
        XCTAssertLessThan(east.points.first!.longitude, origin.longitude)
        XCTAssertGreaterThan(west.points.first!.longitude, origin.longitude)
        XCTAssertLessThan(distance(west.points.last!, origin), 0.5)
        // Наша половина: ширина — половина дороги, середина ленты — на четверть вправо.
        let carriageway = 4 * AppConfig.laneWidthMeters
        XCTAssertEqual(east.widthMeters, carriageway / 2 * AppConfig.cameraZoneWidthShare, accuracy: 0.01)
        XCTAssertEqual(east.offsetMeters, carriageway / 4, accuracy: 0.01)
    }

    func testZoneEndsUnderTheMovedMarker() throws {
        // Значок перенесён на линию маршрута в 12 м к югу: лента — туда же.
        let anchor = GeoMath.destination(from: origin, bearing: 180, distanceMeters: 12)
        let band = try XCTUnwrap(Zone.band(camera: camera(dir: 90), heading: 90, anchor: anchor))
        XCTAssertLessThan(distance(band.points.last!, anchor), 0.5)
        XCTAssertEqual(length(band.points), AppConfig.cameraZoneMeters, accuracy: 1)
    }

    func testShortRoadBeforeTheCameraIsClampedOrDropped() throws {
        // 40 м куска перед камерой — лента 40 м, не выдуманные 80.
        let shortish = camera(dir: 90, road: .some(road(at: origin, bearing: 90, before: 40)))
        let band = try XCTUnwrap(Zone.band(camera: shortish, heading: 90))
        XCTAssertEqual(length(band.points), 40, accuracy: 1)
        // Огрызок в 20 м (перекрёсток режет дорогу) — ничего.
        let stub = camera(dir: 90, road: .some(road(at: origin, bearing: 90, before: 20)))
        XCTAssertNil(Zone.band(camera: stub, heading: 90))
    }

    func testNoProofNoZone() {
        // Нет куска дороги (старая база, отметка водителей).
        XCTAssertNil(Zone.band(camera: camera(dir: 90, road: .some(nil)), heading: 90))
        // Снап сел на тротуар / переход.
        XCTAssertNil(Zone.band(camera: camera(dir: 90, cls: "footway"), heading: 90))
        // Снап на проезд — чаще промах сопоставления.
        XCTAssertNil(Zone.band(camera: camera(dir: 90, cls: "service"), heading: 90))
        // Координата восстановлена приблизительно.
        XCTAssertNil(Zone.band(camera: camera(dir: 90, needsReview: true), heading: 90))
        // Пост ДПС скорость не меряет.
        XCTAssertNil(Zone.band(camera: camera(type: "Пост ДПС", dir: 90), heading: 90))
        // Курс неизвестен (стоим).
        XCTAssertNil(Zone.band(camera: camera(dir: 90), heading: -1))
        // Поперёк дороги камеры: мост, поперечная улица развязки.
        XCTAssertNil(Zone.band(camera: camera(dir: nil), heading: 0))
        XCTAssertNil(Zone.band(camera: camera(dir: nil), heading: 90 + AppConfig.cameraZoneMaxAxisDegrees + 5))
    }

    // MARK: - Курс маршрута у камеры

    func testRouteHeadingIsTheApproachCourse() throws {
        // Линия на восток 300 м, затем на север: камера прямо на повороте.
        let corner = GeoMath.destination(from: origin, bearing: 90, distanceMeters: 300)
        var points = stride(from: 0.0, through: 300, by: 50).map {
            MKMapPoint(GeoMath.destination(from: origin, bearing: 90, distanceMeters: $0))
        }
        points += stride(from: 50.0, through: 300, by: 50).map {
            MKMapPoint(GeoMath.destination(from: corner, bearing: 0, distanceMeters: $0))
        }
        XCTAssertEqual(try XCTUnwrap(Zone.routeHeading(points: points, along: 300)), 90, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(Zone.routeHeading(points: points, along: 450)), 0, accuracy: 1)
        XCTAssertNil(Zone.routeHeading(points: points, along: 5000))
    }

    // MARK: - Запись источника

    func testSourceIsNotRewrittenOnMarkerJitter() throws {
        let cam = camera(dir: 90)
        let a = try XCTUnwrap(Zone.band(camera: cam, heading: 90))
        let jitter = GeoMath.destination(from: origin, bearing: 180, distanceMeters: 1)
        let b = try XCTUnwrap(Zone.band(camera: cam, heading: 95, anchor: jitter))
        XCTAssertFalse(Zone.needsRewrite(a, b), "доля метра значка — не повод будить движок")
        let moved = GeoMath.destination(from: origin, bearing: 180, distanceMeters: 8)
        let c = try XCTUnwrap(Zone.band(camera: cam, heading: 90, anchor: moved))
        XCTAssertTrue(Zone.needsRewrite(a, c))
        let other = try XCTUnwrap(Zone.band(camera: camera(2, dir: 90), heading: 90))
        XCTAssertTrue(Zone.needsRewrite(a, other))
        XCTAssertTrue(Zone.needsRewrite(nil, a))
        XCTAssertTrue(Zone.needsRewrite(a, nil))
        XCTAssertFalse(Zone.needsRewrite(nil, nil))
    }

    // MARK: - Согласованность

    @MainActor
    func testZoneLengthIsThePassMeasurementZone() {
        XCTAssertEqual(AppConfig.cameraZoneMeters, AppConfig.passZoneMeters)
    }

    func testWidthTurnsIntoScreenPointsLikeTheEngineDoes() {
        // На экваторе мир движка — 512 точек на масштабе 0.
        XCTAssertEqual(Zone.metersPerPointAtZoomZero(latitude: 0), 78_271.517, accuracy: 0.01)
        // Ташкент, z17: 11 м проезжей части — ~24 точки.
        let perPoint = Zone.metersPerPointAtZoomZero(latitude: 41.3) / pow(2, 17)
        XCTAssertEqual(11 / perPoint, 24.5, accuracy: 0.5)
    }

    // MARK: - Цвет

    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func lab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = linear(c.0), g = linear(c.1), b = linear(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// Лента поверх полотна — как смешивает движок (sRGB, альфа).
    private func over(_ zone: (hex: UInt32, alpha: Double), _ road: UInt32) -> (Double, Double, Double) {
        let z = rgb(zone.hex), r = rgb(road)
        return (r.0 + (z.0 - r.0) * zone.alpha, r.1 + (z.1 - r.1) * zone.alpha, r.2 + (z.2 - r.2) * zone.alpha)
    }

    /// Полотно дорог по темам: палитра 27.C (make_style.py PALETTES, как в
    /// PaletteTests.asphalt) и палитра «Чистый» 28.A (план 23.10) — лента
    /// обязана читаться на обеих.
    private let asphaltDay: [UInt32] = [0xFFE7A3, 0xFFCF9A, 0xFFFFFF, 0xEFECE5,   // 27.C
                                        0xFFFFFF, 0xF2F3F5, 0xFFD27A, 0xF5B86A]   // 28.A
    private let asphaltNight: [UInt32] = [0x5F6B86, 0x647090, 0x46526B, 0x36435F, 0x0F1420,   // 27.C
                                          0x30343C, 0x5A606C, 0x16181C]                       // 28.A

    func testZoneIsVisibleOnEveryAsphaltInBothThemes() {
        for (zone, roads, theme) in [(Zone.Colors.day, asphaltDay, "днём"), (Zone.Colors.night, asphaltNight, "ночью")] {
            for road in roads {
                XCTAssertGreaterThanOrEqual(deltaE(over(zone, road), rgb(road)), 12,
                                            "лента на полотне #\(String(road, radix: 16)) \(theme)")
            }
            // Полупрозрачная: разметка под ней видна, это подсветка, а не заливка.
            XCTAssertGreaterThan(zone.alpha, 0.2)
            XCTAssertLessThanOrEqual(zone.alpha, 0.45)
        }
    }

    func testZoneIsNotTheRouteColour() {
        for (zone, route, theme) in [(Zone.Colors.day, RouteColors.body.day, "днём"),
                                     (Zone.Colors.night, RouteColors.body.night, "ночью")] {
            XCTAssertGreaterThanOrEqual(deltaE(rgb(zone.hex), rgb(route)), 40, "лента ≠ маршрут \(theme)")
        }
    }

    // MARK: - Только картинка

    func testAlertPipelineNeverReadsTheZone() throws {
        // Зона — для карты. Гейты, проезды, голос и прогресс маршрута её не
        // читают: в Services/ слова CameraZone нет вовсе.
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RadarMap/Services")
        let files = FileManager.default.enumerator(at: services, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("CameraZone") || text.contains("cameraZone"),
                           "\(file.lastPathComponent): зона камеры в конвейере")
        }
    }
}
