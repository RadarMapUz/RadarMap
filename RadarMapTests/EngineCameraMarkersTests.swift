//
//  EngineCameraMarkersTests.swift
//  RadarMapTests
//
//  Камеры на карте движка — P0 20.1 (поездка владельца 21.10): в поездке по
//  маршруту ни одного маркера камеры, ни на телефоне, ни в машине, хотя
//  панель писала «251 м», «135 м до камеры».
//
//  Причина — не значки и не стиль, а выборка камер видимой области. Она
//  урезана бюджетом (160) и при переполнении оставляет ближайшие к центру,
//  а повторялась только на выходе вида из прежней области. Обзор маршрута в
//  11 км (он показывается после каждой постройки — на телефоне и выбором
//  маршрута в машине) набирал 160 камер вокруг середины пути; кадр ведения у
//  машины лежал внутри той области, и выборка не повторялась до конца
//  поездки. У CarPlay, подключённого на ходу, то же делал первый кадр карты —
//  вид всего мира до установки камеры. Журнал здоровья машины говорил ровно
//  это: «камер в источнике 160, в кадре 0».
//
//  Здесь же — то, что проверялось по пути и могло дать тот же симптом: имя
//  значка без картинки в стиле (движок молча не рисует) и слои камер под
//  непрозрачной основой или в списках гасимых на ходу.
//

import Foundation
import MapKit
import MapLibre
import Testing
import UIKit

@testable import RadarMap

@Suite("Камеры на карте движка")
struct EngineCameraMarkersTests {

    private let limit = AppConfig.engineCameraViewportLimit

    // MARK: - Выборка видимой области

    private func bundledCameras() throws -> [Camera] {
        let url = try #require(Bundle.main.url(forResource: "cameras", withExtension: "json"))
        return try JSONDecoder().decode([Camera].self, from: Data(contentsOf: url))
    }

    /// Контракт CameraRepository.cameras(in:limit:): камеры в рамке области,
    /// а при переполнении — `limit` ближайших к её центру.
    private func provider(_ all: [Camera]) -> (MKCoordinateRegion, Int) -> [Camera] {
        { region, limit in
            let inside = all.filter {
                abs($0.lat - region.center.latitude) <= region.span.latitudeDelta / 2
                    && abs($0.lon - region.center.longitude) <= region.span.longitudeDelta / 2
            }
            guard inside.count > limit else { return inside }
            let c = region.center
            return Array(inside.sorted {
                GeoMath.fastDistance(c.latitude, c.longitude, $0.lat, $0.lon)
                    < GeoMath.fastDistance(c.latitude, c.longitude, $1.lat, $1.lon)
            }.prefix(limit))
        }
    }

    /// Что делает карта на каждом кадре (EngineMapView.updateCameras):
    /// повторить выборку или оставить прежнюю.
    private struct Viewport {
        var window: EngineMapPresentation.CameraWindow?
        var cameras: [Camera] = []
        var queries = 0

        mutating func show(_ view: MKCoordinateRegion, limit: Int,
                           provider: (MKCoordinateRegion, Int) -> [Camera]) {
            guard EngineMapPresentation.needsCameraQuery(window, view: view) else { return }
            cameras = provider(EngineMapPresentation.padded(view), limit)
            window = EngineMapPresentation.CameraWindow(view: view, found: cameras.count, limit: limit)
            queries += 1
        }
    }

    private func inView(_ cameras: [Camera], _ view: MKCoordinateRegion) -> [Camera] {
        cameras.filter {
            abs($0.lat - view.center.latitude) <= view.span.latitudeDelta / 2
                && abs($0.lon - view.center.longitude) <= view.span.longitudeDelta / 2
        }
    }

    private func region(_ lat: Double, _ lon: Double, _ dLat: Double, _ dLon: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLon))
    }

    @Test("Обзор маршрута в 11 км не оставляет камеру у машины за кадром")
    func routeOverviewThenFollow() throws {
        let all = try bundledCameras()
        let provide = provider(all)
        // Чиланзар → Юнусабад, как у владельца (11,7 км): обзор — рамка
        // маршрута с полями (MapState.showRouteOverview, 18 % с каждой стороны).
        let car = CLLocationCoordinate2D(latitude: 41.2850, longitude: 69.2040)
        let finish = CLLocationCoordinate2D(latitude: 41.3650, longitude: 69.2850)
        let overview = region((car.latitude + finish.latitude) / 2, (car.longitude + finish.longitude) / 2,
                              abs(finish.latitude - car.latitude) * 1.36,
                              abs(finish.longitude - car.longitude) * 1.36)
        // «Поехали»: ведение на z17 у машины, камера 2158 — в 181 м впереди.
        let follow = region(41.2858, 69.2047, 0.004, 0.006)

        var map = Viewport()
        map.show(overview, limit: limit, provider: provide)
        let window = try #require(map.window)
        #expect(map.cameras.count == limit, "обзор города упирается в бюджет — выборка урезана")
        #expect(!window.complete)
        // Ровно та ловушка: вид ведения лежит внутри области обзора, и
        // прежняя проверка «внутри — значит, всё уже есть» выборку не повторяла.
        #expect(EngineMapPresentation.contains(window.padded, follow))
        let near = inView(all, follow)
        #expect(!near.isEmpty, "у машины есть камера")
        #expect(inView(map.cameras, follow).isEmpty, "урезанная выборка обзора — вокруг середины пути")

        map.show(follow, limit: limit, provider: provide)
        #expect(map.queries == 2, "приближение к машине — выборка заново")
        #expect(Set(inView(map.cameras, follow).map(\.id)) == Set(near.map(\.id)),
                "все камеры кадра ведения — в источнике карты")
    }

    @Test("Первый кадр новой карты — вид всего мира — не запирает выборку")
    func worldFirstFrame() throws {
        let all = try bundledCameras()
        let provide = provider(all)
        var map = Viewport()
        // До установки камеры движок отдаёт границы всего мира (z0):
        // CarPlay, подключённый на ходу, получал 160 камер «у экватора».
        map.show(region(0, 0, 170, 350), limit: limit, provider: provide)
        #expect(map.window?.complete == false)
        let follow = region(41.2858, 69.2047, 0.004, 0.006)
        map.show(follow, limit: limit, provider: provide)
        #expect(map.queries == 2)
        #expect(!inView(map.cameras, follow).isEmpty)
    }

    @Test("Полная выборка не повторяется внутри области, урезанная — на месте")
    func noChurn() {
        let view = region(41.31, 69.28, 0.02, 0.03)
        let complete = EngineMapPresentation.CameraWindow(view: view, found: 20, limit: limit)
        #expect(complete.complete)
        // Осмотр внутри запаса — без перестановки символов.
        #expect(!EngineMapPresentation.needsCameraQuery(complete, view: region(41.312, 69.282, 0.02, 0.03)))
        #expect(!EngineMapPresentation.needsCameraQuery(complete, view: region(41.31, 69.28, 0.004, 0.006)))
        // Вышли из запаса — выборка заново.
        #expect(EngineMapPresentation.needsCameraQuery(complete, view: region(41.33, 69.28, 0.02, 0.03)))
        #expect(EngineMapPresentation.needsCameraQuery(nil, view: view))

        let cut = EngineMapPresentation.CameraWindow(view: view, found: limit, limit: limit)
        #expect(!cut.complete, "ровно бюджет — могла быть урезана")
        // Стоящий вид (шум пересчёта границ) — без новой выборки на каждом кадре.
        #expect(!EngineMapPresentation.needsCameraQuery(cut, view: region(41.31 + 0.00005, 69.28, 0.02, 0.03)))
        #expect(EngineMapPresentation.needsCameraQuery(cut, view: region(41.311, 69.28, 0.02, 0.03)))
        #expect(EngineMapPresentation.needsCameraQuery(cut, view: region(41.31, 69.28, 0.015, 0.0225)))
    }

    // MARK: - Значки

    @Test("Каждое имя значка, которое может назвать точка камеры, лежит в стиле")
    @MainActor func everyIconNameIsRegistered() {
        let registered = Set(EngineMapView.Coordinator.cameraImageNames)
        let kinds: [CameraType] = [.stationaryCamera, .stationaryRadar, .intelligentRadar, .mobileRadar,
                                   .tripod, .dpsPost, .accident, .other("Неизвестный тип")]
        var id = 1
        for kind in kinds {
            for mobileConfirmed in [nil, false, true] as [Bool?] {
                let camera = Camera(id: id, region: "", city: "", location: "", lat: 41.31, lon: 69.28,
                                    type: kind.sourceString, violations: [], needsReview: nil,
                                    mobileConfirmed: mobileConfirmed)
                id += 1
                // Тревога, на пути, спокойная; своя и чужая; день и ночь.
                for alert in [camera.id, nil] as [Int?] {
                    for path in [[camera.id], []] as [Set<Int>] {
                        for familiar in [[camera.id], []] as [Set<Int>] {
                            for daylight in [true, false] {
                                let attributes = EngineMapView.Coordinator.cameraAttributes(
                                    camera, alert: alert, path: path, familiar: familiar,
                                    daylight: daylight, limit: nil)
                                let icon = attributes["icon"] as? String ?? ""
                                #expect(registered.contains(icon), "значка «\(icon)» нет в стиле — камера не нарисуется")
                                let badge = attributes["badge"] as? String ?? ""
                                #expect(badge.isEmpty || registered.contains(badge), "пометки «\(badge)» нет в стиле")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Значок каждого глифа во всех обликах рисуется: без картинки тип молча пропадает")
    @MainActor func everyMarkerImageRenders() {
        for glyph in EngineMapView.Coordinator.markerGlyphs {
            for look in CameraMarkerLook.rasters(glyph) {
                let image = CameraIconArt.marker(glyph, look: look)
                let canvas = CameraMarkerArt.canvas(look)
                #expect(abs(image.size.width - canvas.width) < 0.01, "\(glyph)\(look.suffix)")
                #expect(abs(image.size.height - canvas.height) < 0.01, "\(glyph)\(look.suffix)")
                #expect(Double(image.size.width) >= look.side, "\(glyph)\(look.suffix): фигура не влезла")
            }
        }
    }

    @Test("Булавка стоит остриём на нижнем крае картинки: якорь bottom — точка камеры")
    @MainActor func pinTipTouchesTheBottomEdge() throws {
        for suffix in ["-d", "-n", "-alert"] {
            let look = try #require(CameraMarkerLook.rasters(.camera).first { $0.suffix == suffix })
            let image = CameraIconArt.marker(.camera, look: look, scale: 3)
            let cg = try #require(image.cgImage)
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let context = try #require(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                                 bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Память — сверху вниз: последняя строка буфера — нижний край картинки.
            func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * w + x) * 4 + 3] }
            let bottom = (h - 3...h - 1).flatMap { y in (w / 2 - 3...w / 2 + 3).map { alpha($0, y) } }
            #expect(bottom.contains { $0 > 128 }, "\(suffix): остриё не у нижнего края")
            #expect(alpha(2, h - 1) == 0 && alpha(w - 3, h - 1) == 0, "\(suffix): у нижнего края только остриё")
        }
    }

    // MARK: - Слои

    private let base = URL(string: "https://soulmed.uz/radarmap")!

    private func modernRelease() throws -> TileRelease {
        try JSONDecoder().decode(TileRelease.self, from: Data("""
        {"bucketZoom":10,"sets":{"mvt":{"buckets":{"708_382":"aa","low":"bb"},"ext":"mvt","path":"mvt","tiles":2},\
        "omt":{"buckets":{"708_382":"cc","low":"dd"},"ext":"pbf","path":"omt","tiles":2}},"version":2610071018}
        """.utf8))
    }

    private func layers(_ json: String?) throws -> [[String: Any]] {
        let text = try #require(json)
        let style = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return style["layers"] as? [[String: Any]] ?? []
    }

    /// Все стили, на которых едут: новая карта (телефон — с «Местами» и без,
    /// машина — без), обе темы, с режимом поездки и без; прежняя карта — с
    /// тайлами и до проверки индекса.
    private func drivingStyles() throws -> [(name: String, layers: [[String: Any]])] {
        let release = try modernRelease()
        var out: [(String, [[String: Any]])] = []
        for daylight in [true, false] {
            for places in [true, false] {
                for driving in [false, true] {
                    out.append(("новая день=\(daylight) места=\(places) поездка=\(driving)",
                                try layers(EngineModernStyle.json(daylight: daylight, base: base, release: release,
                                                                  houses: true, places: places, driving: driving))))
                }
            }
            for ready in [true, false] {
                out.append(("прежняя день=\(daylight) тайлы=\(ready)",
                            try layers(EngineMapStyle.json(daylight: daylight, base: base, houses: true,
                                                           tilesReady: ready))))
            }
        }
        return out
    }

    @Test("Камеры в каждом стиле поездки — над всей основой и без разрыва по зуму")
    func cameraLayersOnTop() throws {
        // Над камерами — только то, что рисуется поверх них намеренно.
        // «camera-label» — расстояние у алерт-камеры в машине (25.F).
        let overCameras: Set<String> = ["cameras", "camera-label", "marks", "position"]
        for (name, layers) in try drivingStyles() {
            let ids = layers.compactMap { $0["id"] as? String }
            let dot = try #require(ids.firstIndex(of: "camera-dot"), "\(name): нет camera-dot")
            let icons = try #require(ids.firstIndex(of: "camera-icons"), "\(name): нет camera-icons")
            #expect(ids.contains("camera-badges"), "\(name): нет camera-badges")
            #expect(icons > dot)
            for (index, layer) in layers.enumerated() where index > dot {
                let source = layer["source"] as? String ?? ""
                #expect(overCameras.contains(source), "\(name): слой \(ids[index]) лёг поверх камер")
            }
            // Точка до 14.5, значок с 14.5 — на любом зуме камера чем-то нарисована.
            let dotMax = layers[dot]["maxzoom"] as? Double
            let iconMin = layers[icons]["minzoom"] as? Double
            #expect(dotMax != nil && dotMax == iconMin, "\(name): разрыв между точкой и значком")
        }
    }

    @Test("Булавка стоит остриём на камере, ореол тревоги — у её головы, на обзоре — у точки")
    func pinAnchorAndHalo() throws {
        for (name, layers) in try drivingStyles() {
            let icons = try #require(layers.first { $0["id"] as? String == "camera-icons" }, "\(name)")
            let anchor = (icons["layout"] as? [String: Any])?["icon-anchor"] as? [Any]
            #expect(((anchor?[1] as? [Any])?.last as? String) == "anchor", "\(name): якорь не из точки")
            let halo = try #require(layers.first { $0["id"] as? String == "camera-halo-pin" }, "\(name): нет ореола булавки")
            let translate = try #require((halo["paint"] as? [String: Any])?["circle-translate"] as? [Any])
            #expect(translate.first as? String == "step", "\(name): ореол не следует за точкой на обзоре")
            #expect(translate[3] as? Double == EngineMapStyle.cameraIconMinZoom)
            let head = ((translate[4] as? [Any])?[1] as? [Any])?.last as? Double
            #expect(head == -CameraMarkerLook.pinHeadLift(side: CameraMarkerLook.pinAlertSide))
        }
    }

    @Test("Слои камер не гасятся ни на горячем телефоне, ни на ходу")
    @MainActor func cameraLayersNeverHidden() {
        let cameraLayers = ["camera-halo", "camera-halo-pin", "camera-dot", "camera-icons", "camera-badges"]
        let hidden = Set(EngineMapView.Coordinator.hotHiddenLayers).union(MapDetailLayers.managed)
        for id in cameraLayers {
            #expect(!hidden.contains(id), "\(id) в списке гасимых")
            #expect(!EngineModernStyle.hiddenWhileDriving(id), "\(id) вырезается в поездке")
        }
    }
}
