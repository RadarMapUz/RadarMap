//
//  RouteService.swift
//  RadarMap
//
//  Автомобильный маршрут: варианты, камеры вдоль линии, голосовые манёвры, прогресс.
//
//  Apple Maps не строит автомобильные маршруты в Узбекистане, поэтому движков два:
//  сначала пробуем MKDirections (работает за границей и на случай, если Apple включит
//  регион), при отказе — свой OSRM-сервер на графе OpenStreetMap.
//

import Foundation
import MapKit
import Observation

/// Манёвр на маршруте («через 300 м — направо»).
struct RouteStep {
    let distanceAlong: CLLocationDistance   // где манёвр, метры от старта
    let text: String                        // «Поверните направо на Амира Темура»
    let icon: String                        // SFSymbol для баннера
}

@MainActor
@Observable
final class RouteService {
    struct RouteCamera: Identifiable {
        let camera: Camera
        let distanceAlong: CLLocationDistance   // от старта по маршруту
        var id: Int { camera.id }
    }

    /// Один вариант маршрута — в виде, не зависящем от движка.
    struct Variant: Identifiable {
        let id: Int
        let points: [MKMapPoint]
        let polyline: MKPolyline
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let cameras: [RouteCamera]
        let steps: [RouteStep]

        var etaText: String { Formatting.duration(travelTime) }
        var distanceText: String { Formatting.distance(distance) }
    }

    private enum RouteError: Error {
        case noRoute          // оба движка не нашли путь между точками
        case serverUnreachable
    }

    private(set) var variants: [Variant] = []
    private(set) var selectedID = 0
    private(set) var destinationName: String = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var isBuilding = false
    private(set) var errorMessage: String?

    // Живой прогресс (обновляется на каждой GPS-точке при активном маршруте).
    private(set) var progressAlong: CLLocationDistance = 0
    private(set) var nextCamera: RouteCamera?
    private(set) var nextCameraDistance: CLLocationDistance = 0
    private(set) var nextStep: RouteStep?
    private(set) var nextStepDistance: CLLocationDistance = 0

    /// Голосовые события — подключаются в AppEnvironment.
    @ObservationIgnored var onRerouted: (() -> Void)?
    @ObservationIgnored var onArrived: (() -> Void)?
    @ObservationIgnored var onManeuver: ((String) -> Void)?

    @ObservationIgnored private var offRouteTicks = 0
    @ObservationIgnored private var lastRebuildAt: Date = .distantPast
    @ObservationIgnored private var isRebuilding = false
    @ObservationIgnored private var announcedStage: [Int: Int] = [:]   // индекс шага → стадия (2 далеко, 1 близко, 0 сейчас)
    @ObservationIgnored private var segmentHint = 0                    // ускоряет проекцию точки на маршрут

    var isActive: Bool { !variants.isEmpty }
    var selected: Variant? { variants.first { $0.id == selectedID } }
    var polyline: MKPolyline? { selected?.polyline }
    var camerasOnRoute: [RouteCamera] { selected?.cameras ?? [] }
    var distanceText: String { selected?.distanceText ?? "" }
    var etaText: String { selected?.etaText ?? "" }

    // MARK: - Построение

    func build(from source: CLLocationCoordinate2D,
               to destination: CLLocationCoordinate2D,
               name: String, cameras: [Camera],
               alternatives: Bool = true) async {
        isBuilding = true
        errorMessage = nil
        defer { isBuilding = false }

        do {
            let built = try await calculate(from: source, to: destination, alternatives: alternatives)
            await apply(built, name: name, destination: destination, cameras: cameras)
        } catch RouteError.serverUnreachable {
            errorMessage = String(localized: "Нет связи с сервером маршрутов — проверьте интернет")
        } catch {
            errorMessage = String(localized: "Маршрут не найден")
        }
    }

    func selectVariant(_ id: Int) {
        guard id != selectedID, variants.contains(where: { $0.id == id }) else { return }
        selectedID = id
        resetProgress()
    }

    func clear() {
        variants = []
        selectedID = 0
        destinationName = ""
        destinationCoordinate = nil
        errorMessage = nil
        resetProgress()
    }

    private func resetProgress() {
        progressAlong = 0
        nextCamera = nil
        nextCameraDistance = 0
        nextStep = nil
        nextStepDistance = 0
        offRouteTicks = 0
        announcedStage = [:]
        segmentHint = 0
    }

    // MARK: - Прогресс: прибытие, следующая камера, манёвры, перестроение

    /// Вызывается на каждой GPS-точке. `announce` — озвучивать ли манёвры (в поездке).
    func updateProgress(coordinate: CLLocationCoordinate2D, cameras: [Camera], announce: Bool) {
        guard let variant = selected, !isBuilding, !isRebuilding,
              let destination = destinationCoordinate else { return }
        let point = MKMapPoint(coordinate)

        if point.distance(to: MKMapPoint(destination)) <= AppConfig.arrivalRadiusMeters {
            clear()
            onArrived?()
            return
        }

        let (along, deviation) = Self.project(point, onto: variant.points, hint: &segmentHint)
        progressAlong = along

        // Следующая камера впереди по маршруту.
        if let cam = variant.cameras.first(where: { $0.distanceAlong > along - 30 }) {
            nextCamera = cam
            nextCameraDistance = max(0, cam.distanceAlong - along)
        } else {
            nextCamera = nil
        }

        updateManeuvers(variant: variant, along: along, announce: announce)

        // Отклонение → перестроение (с защитой от шума GPS и кулдауном).
        guard deviation > AppConfig.rerouteDeviationMeters else {
            offRouteTicks = 0
            return
        }
        offRouteTicks += 1
        guard offRouteTicks >= AppConfig.rerouteConfirmTicks,
              Date().timeIntervalSince(lastRebuildAt) > AppConfig.rerouteCooldownSeconds else { return }

        offRouteTicks = 0
        lastRebuildAt = Date()
        isRebuilding = true
        let name = destinationName
        Task {
            defer { isRebuilding = false }
            // Перестраиваем без альтернатив — быстрее, и в движении выбор не нужен.
            guard let built = try? await calculate(from: coordinate, to: destination, alternatives: false) else { return }
            await apply(built, name: name, destination: destination, cameras: cameras)
            onRerouted?()
        }
    }

    private func updateManeuvers(variant: Variant, along: CLLocationDistance, announce: Bool) {
        // Первый манёвр впереди (с запасом 15 м, чтобы не «перескакивал» на повороте).
        guard let index = variant.steps.firstIndex(where: { $0.distanceAlong > along + 15 }) else {
            nextStep = nil
            return
        }
        let step = variant.steps[index]
        let distance = step.distanceAlong - along
        nextStep = step
        nextStepDistance = distance

        guard announce else { return }
        let stage = announcedStage[index] ?? 3
        if distance < 45, stage > 0 {
            announcedStage[index] = 0
            onManeuver?(step.text)
        } else if distance < 280, stage > 1 {
            announcedStage[index] = 1
            onManeuver?(String(format: String(localized: "Через %lld метров — %@"),
                               Int((distance / 50).rounded() * 50), step.text))
        } else if distance < 850, stage > 2 {
            announcedStage[index] = 2
            onManeuver?(String(format: String(localized: "Через %lld метров — %@"),
                               Int((distance / 100).rounded() * 100), step.text))
        }
    }

    // MARK: - Движки

    private struct BuiltVariant {
        let points: [MKMapPoint]
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let steps: [RouteStep]
    }

    private func calculate(from source: CLLocationCoordinate2D,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool) async throws -> [BuiltVariant] {
        if let apple = try? await appleRoute(from: source, to: destination, alternatives: alternatives),
           !apple.isEmpty { return apple }
        return try await osrmRoute(from: source, to: destination, alternatives: alternatives)
    }

    private func appleRoute(from source: CLLocationCoordinate2D,
                            to destination: CLLocationCoordinate2D,
                            alternatives: Bool) async throws -> [BuiltVariant] {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: source.latitude, longitude: source.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternatives

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RouteError.noRoute }
        return response.routes.prefix(3).map { route in
            let points = Array(UnsafeBufferPointer(start: route.polyline.points(),
                                                   count: route.polyline.pointCount))
            // Инструкции Apple уже локализованы системой; позиция шага — накопленная длина.
            var along: CLLocationDistance = 0
            var steps: [RouteStep] = []
            for step in route.steps where !step.instructions.isEmpty {
                steps.append(RouteStep(distanceAlong: along, text: step.instructions, icon: "arrow.up"))
                along += step.distance
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.expectedTravelTime, steps: steps)
        }
    }

    private func osrmRoute(from source: CLLocationCoordinate2D,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool) async throws -> [BuiltVariant] {
        var components = URLComponents(url: AppConfig.osrmBaseURL
            .appendingPathComponent("route/v1/driving")
            .appendingPathComponent(String(format: "%.6f,%.6f;%.6f,%.6f",
                                           source.longitude, source.latitude,
                                           destination.longitude, destination.latitude)),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "alternatives", value: alternatives ? "true" : "false"),
            URLQueryItem(name: "steps", value: "true"),
        ]

        let data: Data
        do {
            var request = URLRequest(url: components.url!, timeoutInterval: 12)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RouteError.serverUnreachable
        }

        guard let response = try? JSONDecoder().decode(OSRMResponse.self, from: data),
              response.code == "Ok", let routes = response.routes, !routes.isEmpty
        else { throw RouteError.noRoute }

        return routes.prefix(3).compactMap { route -> BuiltVariant? in
            guard route.geometry.coordinates.count >= 2 else { return nil }
            let points = route.geometry.coordinates.map {
                MKMapPoint(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]))
            }
            var steps: [RouteStep] = []
            var along: CLLocationDistance = 0
            for step in route.legs.first?.steps ?? [] {
                if let built = Self.maneuverStep(step, at: along) { steps.append(built) }
                along += step.distance
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.duration, steps: steps)
        }
    }

    private struct OSRMResponse: Decodable {
        let code: String
        let routes: [Route]?
        struct Route: Decodable {
            let distance: Double
            let duration: Double
            let geometry: Geometry
            let legs: [Leg]
        }
        struct Geometry: Decodable {
            let coordinates: [[Double]]   // GeoJSON: [lon, lat]
        }
        struct Leg: Decodable { let steps: [Step] }
        struct Step: Decodable {
            let distance: Double
            let name: String
            let maneuver: Maneuver
        }
        struct Maneuver: Decodable {
            let type: String
            let modifier: String?
            let exit: Int?
        }
    }

    /// OSRM-манёвр → человеческая фраза + иконка. nil — шаг не озвучиваем (смена названия улицы и т.п.).
    nonisolated private static func maneuverStep(_ step: OSRMResponse.Step,
                                                 at along: CLLocationDistance) -> RouteStep? {
        let m = step.maneuver
        var text: String?
        var icon = "arrow.up"

        func turnPhrase(_ modifier: String?) -> (String, String)? {
            switch modifier {
            case "left":         return (String(localized: "поверните налево"), "arrow.turn.up.left")
            case "right":        return (String(localized: "поверните направо"), "arrow.turn.up.right")
            case "slight left":  return (String(localized: "плавно левее"), "arrow.up.left")
            case "slight right": return (String(localized: "плавно правее"), "arrow.up.right")
            case "sharp left":   return (String(localized: "круто налево"), "arrow.turn.up.left")
            case "sharp right":  return (String(localized: "круто направо"), "arrow.turn.up.right")
            case "uturn":        return (String(localized: "разворот"), "arrow.uturn.left")
            default:             return nil
            }
        }

        switch m.type {
        case "turn", "continue", "end of road":
            if let (phrase, symbol) = turnPhrase(m.modifier) { text = phrase; icon = symbol }
        case "fork":
            switch m.modifier {
            case "left", "slight left":
                text = String(localized: "держитесь левее"); icon = "arrow.up.left"
            case "right", "slight right":
                text = String(localized: "держитесь правее"); icon = "arrow.up.right"
            default: break
            }
        case "merge":
            text = String(localized: "перестройтесь в поток"); icon = "arrow.merge"
        case "on ramp":
            text = String(localized: "съезд на развязку"); icon = "arrow.up.right"
        case "off ramp":
            text = String(localized: "сверните на съезд"); icon = "arrow.down.right"
        case "roundabout", "rotary":
            let exit = m.exit ?? 1
            text = String(format: String(localized: "на кольце %lld-й съезд"), exit)
            icon = "arrow.triangle.2.circlepath"
        case "arrive":
            text = String(localized: "вы прибыли"); icon = "flag.checkered"
        default:
            break   // depart, new name и прочее не озвучиваем
        }

        guard var result = text else { return nil }
        if !step.name.isEmpty, m.type != "arrive" {
            result += String(format: String(localized: " на %@"), step.name)
        }
        return RouteStep(distanceAlong: along, text: result, icon: icon)
    }

    // MARK: - Применение результата

    private func apply(_ built: [BuiltVariant], name: String,
                       destination: CLLocationCoordinate2D, cameras: [Camera]) async {
        // Камеры по коридору каждого варианта считаем ВНЕ главного потока —
        // длинные маршруты не должны дёргать UI даже на старых устройствах.
        let inputs = built.filter { $0.points.count >= 2 }
        guard !inputs.isEmpty else { return }

        let variantCameras = await Task.detached(priority: .userInitiated) {
            inputs.map { variant -> [RouteCamera] in
                var bbox = MKMapRect.null
                for p in variant.points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
                let centerLat = variant.points[variant.points.count / 2].coordinate.latitude
                return Self.camerasAlong(pts: variant.points, bbox: bbox,
                                         centerLat: centerLat, cameras: cameras)
            }
        }.value

        variants = inputs.enumerated().map { index, variant in
            Variant(id: index,
                    points: variant.points,
                    polyline: MKPolyline(points: variant.points, count: variant.points.count),
                    distance: variant.distance,
                    travelTime: variant.travelTime,
                    cameras: variantCameras[index],
                    steps: variant.steps)
        }
        selectedID = 0
        destinationName = name
        destinationCoordinate = destination
        errorMessage = nil
        resetProgress()
    }

    // MARK: - Геометрия (фоновые потоки)

    nonisolated private static func camerasAlong(pts: [MKMapPoint], bbox: MKMapRect,
                                                 centerLat: CLLocationDegrees,
                                                 cameras: [Camera]) -> [RouteCamera] {
        let n = pts.count
        guard n >= 2 else { return [] }

        // Кумулятивная длина по сегментам (метры).
        var cum = [CLLocationDistance](repeating: 0, count: n)
        for i in 1..<n { cum[i] = cum[i - 1] + pts[i - 1].distance(to: pts[i]) }

        // Расширенный bbox для быстрого отсева 3341 камеры.
        let pad = AppConfig.routeCorridorMeters * MKMapPointsPerMeterAtLatitude(centerLat)
        let rect = bbox.insetBy(dx: -pad, dy: -pad)

        var result: [RouteCamera] = []
        for camera in cameras {
            let mp = MKMapPoint(camera.coordinate)
            guard rect.contains(mp) else { continue }
            var bestMeters = Double.greatestFiniteMagnitude
            var bestAlong: CLLocationDistance = 0
            for i in 0..<(n - 1) {
                let (closest, t) = closestPoint(mp, pts[i], pts[i + 1])
                let d = mp.distance(to: closest)
                if d < bestMeters {
                    bestMeters = d
                    bestAlong = cum[i] + t * pts[i].distance(to: pts[i + 1])
                }
            }
            if bestMeters <= AppConfig.routeCorridorMeters {
                result.append(RouteCamera(camera: camera, distanceAlong: bestAlong))
            }
        }
        return result.sorted { $0.distanceAlong < $1.distanceAlong }
    }

    /// Проекция точки на маршрут: (пройдено от старта, отклонение от линии).
    /// `hint` — индекс сегмента с прошлого раза: обычно машина рядом, полный перебор не нужен.
    nonisolated private static func project(_ p: MKMapPoint, onto pts: [MKMapPoint],
                                            hint: inout Int) -> (along: CLLocationDistance, deviation: CLLocationDistance) {
        let n = pts.count
        guard n >= 2 else { return (0, .greatestFiniteMagnitude) }

        func scan(_ range: Range<Int>) -> (Int, Double, CLLocationDistance) {
            var bestIndex = range.lowerBound
            var bestT = 0.0
            var bestDist = Double.greatestFiniteMagnitude
            for i in range {
                let (closest, t) = closestPoint(p, pts[i], pts[i + 1])
                let d = p.distance(to: closest)
                if d < bestDist { bestDist = d; bestIndex = i; bestT = t }
            }
            return (bestIndex, bestT, bestDist)
        }

        // Окно вокруг прошлой позиции; если далеко (>200 м) — полный перебор (петли, перестроение).
        let lo = max(0, hint - 8), hi = min(n - 1, hint + 40)
        var (index, t, deviation) = scan(lo..<hi)
        if deviation > 200 {
            (index, t, deviation) = scan(0..<(n - 1))
        }
        hint = index

        var along: CLLocationDistance = 0
        for i in 0..<index { along += pts[i].distance(to: pts[i + 1]) }
        along += t * pts[index].distance(to: pts[index + 1])
        return (along, deviation)
    }

    /// Ближайшая точка на сегменте AB к точке P + параметр t (0…1).
    nonisolated private static func closestPoint(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> (MKMapPoint, Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return (a, 0) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return (MKMapPoint(x: a.x + t * dx, y: a.y + t * dy), t)
    }
}
