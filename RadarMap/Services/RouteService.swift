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
import os

@MainActor
@Observable
final class RouteService {

    /// Снос — БЕЗ прыжка на актор, и это не стиль, а обход живого бага рантайма.
    ///
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor синтезирует isolated deinit
    /// каждому @MainActor-классу, даже когда своего deinit нет. Такой deinit
    /// уходит в swift_task_deinitOnExecutor, тот в синхронном кадре главного
    /// потока (текущей Task нет) заводит TaskLocal::StopLookupScope, а
    /// MarkerItem::create в рантайме iOS 26 берёт память у task-аллокатора
    /// БЕЗУСЛОВНО — при task == nullptr это статический слэб внутри
    /// libswift_Concurrency. Item::destroy потом зовёт free() по этому
    /// указателю: «pointer being freed was not allocated» → SIGABRT.
    ///
    /// Условия сходятся ровно там, где SwiftUI сносит вью с @State-моделью
    /// внутри GraphHost.runTransaction: там жива task-local привязка. В ветке
    /// main рантайма баг уже исправлен; до выхода такой iOS помогает одно —
    /// не синтезировать isolated deinit вовсе.
    nonisolated deinit {}
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
    /// Пройденный кусок маршрута (рисуется тусклым поверх линии).
    private(set) var traveledPolyline: MKPolyline?

    /// Прибытие к цели — данные для карточки «Вы на месте».
    struct ArrivalSummary: Equatable {
        let name: String
        let at: Date
    }
    private(set) var lastArrival: ArrivalSummary?
    func dismissArrival() { lastArrival = nil }

    /// Голосовые события — подключаются в AppEnvironment.
    /// Пульт: маршруты строит наш OSRM, и его падение — единственная беда,
    /// которую иначе никак не сообщить пользователю до следующего релиза.
    @ObservationIgnored weak var config: RemoteConfigService?
    var isRoutingEnabled: Bool { config?.isRoutingEnabled ?? true }

    @ObservationIgnored var onRerouted: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onRerouted,
                                               "RouteService.onRerouted") }
    }
    @ObservationIgnored var onArrived: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onArrived,
                                               "RouteService.onArrived") }
    }
    @ObservationIgnored var onManeuver: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onManeuver,
                                               "RouteService.onManeuver") }
    }

    @ObservationIgnored private var offRouteTicks = 0
    @ObservationIgnored private var lastSplitAlong: CLLocationDistance = -1
    @ObservationIgnored private var lastRebuildAt: Date = .distantPast
    @ObservationIgnored private var isRebuilding = false
    /// Поколение маршрута: растёт при build/clear. Фоновое перестроение (OSRM, до 12 с)
    /// сверяется с ним — иначе доехавший rebuild «воскрешал» бы сброшенный маршрут
    /// или перетирал свежепостроенный к новой цели.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var announcedStage: [Int: Int] = [:]   // индекс шага → стадия (2 далеко, 1 близко, 0 сейчас)
    @ObservationIgnored private var segmentHint = 0                    // ускоряет проекцию точки на маршрут
    /// Кумулятивная длина выбранного варианта (см. Self.cumulative).
    @ObservationIgnored private var selectedCumulative: [CLLocationDistance] = []
    /// Подряд неудачных перестроений: каждое удваивает кулдаун (сеть на трассе
    /// пропадает надолго, и два сетевых захода каждые 20 с — 3 будильника
    /// радио в минуту на всё время объезда).
    @ObservationIgnored private var rerouteFailures = 0

    var isActive: Bool { !variants.isEmpty }
    var selected: Variant? { variants.first { $0.id == selectedID } }
    var polyline: MKPolyline? { selected?.polyline }

    /// Координаты выбранного маршрута — для схемы на приборке, которая чертит
    /// линию сама, без карты.
    ///
    /// С кэшем: геттер дёргается на каждом GPS-тике открытой приборки, а
    /// `getCoordinates` копирует ВЕСЬ маршрут — для Ташкент—Бухара это тысячи
    /// точек каждую секунду впустую. Ключ — сам объект полилайна, а не
    /// поколение: перестроение при уходе с маршрута заменяет варианты, НЕ
    /// трогая поколение, и кэш по поколению отдавал бы старую линию.
    var routeCoordinates: [CLLocationCoordinate2D] {
        guard let polyline else { return [] }
        if let cache = coordinatesCache, cache.polyline === polyline {
            return cache.points
        }
        var points = [CLLocationCoordinate2D](repeating: .init(),
                                              count: polyline.pointCount)
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        coordinatesCache = (polyline, points)
        return points
    }
    /// Держит полилайн сильной ссылкой: пока ключ жив, его адрес не достанется
    /// новому объекту и кэш не совпадёт с чужим маршрутом по случайности.
    @ObservationIgnored private var coordinatesCache:
        (polyline: MKPolyline, points: [CLLocationCoordinate2D])?
    var camerasOnRoute: [RouteCamera] { selected?.cameras ?? [] }
    var distanceText: String { selected?.distanceText ?? "" }
    var etaText: String { selected?.etaText ?? "" }

    // MARK: - Индекс камер маршрута

    /// Камеры выбранного маршрута по идентификатору — и их набор для карты.
    ///
    /// Кэш, а не перебор, потому что вопрос «эта камера на маршруте?» задают не
    /// раз в секунду, а полтораста раз в секунду: `recomputeNearest` спрашивает
    /// его про каждую камеру окна на каждом GPS-тике. На междугородном маршруте
    /// камер под две сотни — перебором это десятки тысяч сравнений на тик, и
    /// растёт оно ровно там, где дорога длиннее и телефон греется дольше.
    ///
    /// Ключ — объект полилайна выбранного варианта, как у `routeCoordinates`:
    /// перестроение при уходе с маршрута заменяет варианты, НЕ трогая поколение,
    /// и кэш по поколению отдавал бы камеры старой линии.
    @ObservationIgnored private var routeIndexCache:
        (polyline: MKPolyline, byID: [Int: RouteCamera], ids: Set<Int>)?

    /// Сам индекс — чистая функция, чтобы его можно было проверить тестом без
    /// живого маршрута (собрать `Variant` извне нельзя, он строится сетью).
    ///
    /// Камера может встретиться на маршруте дважды — петля развязки, круговое
    /// движение, разворот. Оставляем ПЕРВУЮ, как делал прежний `first(where:)`:
    /// она ближайшая по ходу, и остаток пути считается именно до неё. Со второй
    /// приложение молчало бы о камере, пока не проедет её в первый раз.
    nonisolated static func index(of cameras: [RouteCamera])
        -> (byID: [Int: RouteCamera], ids: Set<Int>) {
        let byID = Dictionary(cameras.map { ($0.camera.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return (byID, Set(byID.keys))
    }

    private func routeIndex() -> (byID: [Int: RouteCamera], ids: Set<Int>) {
        guard let variant = selected else { return ([:], []) }
        if let cache = routeIndexCache, cache.polyline === variant.polyline {
            return (cache.byID, cache.ids)
        }
        let built = Self.index(of: variant.cameras)
        routeIndexCache = (variant.polyline, built.byID, built.ids)
        return built
    }

    /// Идентификаторы камер маршрута. Карта красит по ним маркеры и строила
    /// этот набор заново внутри `MapContentBuilder` — то есть на каждую
    /// пересборку слоя, а их за поездку тысячи.
    var routeCameraIDs: Set<Int> { routeIndex().ids }

    /// Камера маршрута по идентификатору — O(1).
    func routeCamera(id: Int) -> RouteCamera? { routeIndex().byID[id] }

    // Живой остаток пути (для компактной панели поездки).
    var remainingDistance: CLLocationDistance {
        guard let selected else { return 0 }
        return max(0, selected.distance - progressAlong)
    }
    var remainingTime: TimeInterval {
        guard let selected, selected.distance > 0 else { return 0 }
        return selected.travelTime * remainingDistance / selected.distance
    }
    var arrivalDate: Date { Date().addingTimeInterval(remainingTime) }

    // MARK: - Построение

    func build(from source: CLLocationCoordinate2D,
               to destination: CLLocationCoordinate2D,
               name: String, cameras: [Camera],
               alternatives: Bool = true) async {
        // Пульт: если наш OSRM лежит, честное «временно недоступны» лучше, чем
        // спиннер на 20 секунд и «Маршрут не найден» — последнее водитель
        // прочитает как «дороги нет», а не как «сервер чинят».
        guard isRoutingEnabled else {
            errorMessage = String(localized: "Маршруты временно недоступны — мы уже чиним")
            return
        }
        isBuilding = true
        errorMessage = nil
        defer { isBuilding = false }
        generation += 1
        let gen = generation

        lastArrival = nil   // новый маршрут — карточка прошлого прибытия неактуальна
        do {
            let built = try await calculate(from: source, to: destination, alternatives: alternatives)
            guard gen == generation else { return }   // пока считали — маршрут сбросили/заменили
            await apply(built, name: name, destination: destination,
                        cameras: cameras, gen: gen)
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
        generation += 1   // rebuild в полёте не должен вернуть линию на карту
        variants = []
        selectedID = 0
        destinationName = ""
        destinationCoordinate = nil
        errorMessage = nil
        selectedCumulative = []
        rerouteFailures = 0
        resetProgress()
    }

    /// Поездка завершена рядом с целью — маршрут выполнен, убираем его сами.
    /// (Пользователь припарковался и вышел: линия не должна висеть на карте.)
    func finishIfNearDestination(coordinate: CLLocationCoordinate2D?) {
        guard isActive, let destination = destinationCoordinate else { return }
        let destinationDistance = coordinate.map {
            MKMapPoint($0).distance(to: MKMapPoint(destination))
        } ?? .greatestFiniteMagnitude
        if remainingDistance < 400 || destinationDistance < 400 {
            arrive()
        }
    }

    private func arrive() {
        lastArrival = ArrivalSummary(name: destinationName, at: Date())
        clear()
        onArrived?()
    }

    private func resetProgress() {
        progressAlong = 0
        nextCamera = nil
        nextCameraDistance = 0
        nextStep = nil
        nextStepDistance = 0
        traveledPolyline = nil
        lastSplitAlong = -1
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

        // Кумулятив ленится к текущему варианту: одна точка самолечения на все
        // пути смены маршрута (apply, выбор варианта, перестроение).
        if selectedCumulative.count != variant.points.count {
            selectedCumulative = Self.cumulative(of: variant.points)
        }
        // Вне линии полный перебор — каждый третий тик, не каждый.
        let (along, deviation) = Self.project(point, onto: variant.points,
                                              cum: selectedCumulative,
                                              hint: &segmentHint,
                                              allowFullScan: offRouteTicks % 3 == 0)
        progressAlong = along

        // Прибытие: у самой цели ИЛИ проехали финиш по маршруту (парковка чуть в стороне,
        // GPS-точка не попала в малый радиус — маршрут всё равно выполнен).
        let destinationDistance = point.distance(to: MKMapPoint(destination))
        if destinationDistance <= AppConfig.arrivalRadiusMeters
            || (variant.distance - along < 80 && destinationDistance < 250) {
            arrive()
            return
        }

        // Пройденный кусок для тусклой отрисовки. Шаг крупный намеренно: эту
        // линию читает тело экрана карты, и каждая перезапись пересобирает
        // карту со всеми маркерами (см. AppConfig.routeTraveledStepMeters).
        if abs(along - lastSplitAlong) > AppConfig.routeTraveledStepMeters {
            lastSplitAlong = along
            traveledPolyline = Self.traveledPrefix(points: variant.points, upTo: along)
        }

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
        // Кулдаун растёт с каждой неудачей (×2, потолок ×16): без бэкоффа при
        // мёртвой сети перестроение долбило MKDirections + OSRM (таймаут 12 с)
        // каждые 20 с всё время объезда.
        let cooldown = AppConfig.rerouteCooldownSeconds
            * pow(2, Double(min(rerouteFailures, 4)))
        guard offRouteTicks >= AppConfig.rerouteConfirmTicks,
              Date().timeIntervalSince(lastRebuildAt) > cooldown else { return }

        offRouteTicks = 0
        lastRebuildAt = Date()
        isRebuilding = true
        let name = destinationName
        let gen = generation
        Task {
            defer { isRebuilding = false }
            // Перестраиваем без альтернатив — быстрее, и в движении выбор не нужен.
            guard let built = try? await calculate(from: coordinate, to: destination, alternatives: false) else {
                rerouteFailures += 1
                Log.route.error("перестроение маршрута не удалось (\(self.rerouteFailures, privacy: .public)-й раз) — остаёмся на старой линии")
                return
            }
            guard gen == generation else { return }   // маршрут успели сбросить/заменить
            rerouteFailures = 0
            await apply(built, name: name, destination: destination,
                        cameras: cameras, gen: gen)
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
        } else if distance < 850, stage > 2, step.kind?.deservesEarlyCall ?? true {
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
        // Сбой Apple-роутинга — штатный путь: ниже падаем на собственный OSRM.
        if let apple = try? await appleRoute(from: source, to: destination, alternatives: alternatives),
           !apple.isEmpty { return apple }
        return try await osrmRoute(from: source, to: destination, alternatives: alternatives)
    }

    private func appleRoute(from source: CLLocationCoordinate2D,
                            to destination: CLLocationCoordinate2D,
                            alternatives: Bool) async throws -> [BuiltVariant] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
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

        // Сторонний OSRM, не наш бэкенд — единственное осознанное исключение из
        // правила «сеть только через APIClient» (свой формат URL и ошибок).
        let data: Data
        let response: URLResponse
        do {
            var request = URLRequest(url: components.url!, timeoutInterval: 12)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RouteError.serverUnreachable
        }
        // 5xx/4xx без валидного тела — это «сервер недоступен», а не «маршрута нет»:
        // пользователь должен видеть проблему сети, а не думать, что дороги не существует.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Log.route.error("OSRM HTTP \(http.statusCode, privacy: .public)")
            throw RouteError.serverUnreachable
        }

        guard let response = try? JSONDecoder().decode(OSRMResponse.self, from: data),
              response.code == "Ok", let routes = response.routes, !routes.isEmpty
        else {
            Log.route.error("OSRM: пустой или нечитаемый ответ")
            throw RouteError.noRoute
        }

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

    struct OSRMResponse: Decodable {
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
            /// Полосы приезжают здесь и раньше молча выбрасывались. `var` с
            /// умолчанием, а не `let`: у структуры синтезируется ещё и
            /// memberwise-инициализатор, которым пользуются тесты.
            var intersections: [Intersection]? = nil
        }
        struct Maneuver: Decodable {
            let type: String
            let modifier: String?
            let exit: Int?
        }
        struct Intersection: Decodable {
            let lanes: [Lane]?
        }
        struct Lane: Decodable {
            let valid: Bool?
            let indications: [String]?
        }
    }

    /// OSRM-манёвр → человеческая фраза + иконка. nil — шаг не озвучиваем (смена названия улицы и т.п.).
    nonisolated static func maneuverStep(_ step: OSRMResponse.Step,
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
        case "turn", "end of road":
            if let (phrase, symbol) = turnPhrase(m.modifier) { text = phrase; icon = symbol }
        case "continue":
            // `continue` у OSRM значит «ОСТАВАЙТЕСЬ на своей дороге», а
            // modifier описывает, куда эта дорога изгибается. Стоял он в одной
            // ветке с turn — и «дорога уходит правее» произносилось как
            // «поверните направо». Водитель едет прямо и слышит команду
            // свернуть; каждый такой шаг объявлялся ещё и трижды.
            //
            // Молчим. Если изгиб настолько крут, что нужен голос, OSRM пришлёт
            // turn, а не continue. Разворот — единственное исключение: он
            // требует действия, как его ни назови.
            if m.modifier == "uturn", let (phrase, symbol) = turnPhrase("uturn") {
                text = phrase; icon = symbol
            }
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
        // Тип манёвра — отдельно от фразы. Фраза зависит ещё и от типа
        // развязки («держитесь правее» на развилке против «поверните направо»
        // на перекрёстке), а геометрия поворота — только от модификатора.
        let kind: ManeuverKind = m.type == "arrive" ? .arrive
            : m.type == "roundabout" || m.type == "rotary" ? .roundabout
            : ManeuverKind.fromOSRM(modifier: m.modifier)
        return RouteStep(distanceAlong: along, text: result, icon: icon,
                         kind: kind, lanes: lanes(of: step))
    }

    /// Полосы на подходе к манёвру.
    ///
    /// Берём ПЕРВЫЙ перекрёсток шага: в модели OSRM шаг начинается своим
    /// манёвром, и `intersections[0]` — это как раз тот перекрёсток, на
    /// котором манёвр совершается; его `lanes` описывают полосы на подходе.
    ///
    /// Полоса без единой понятной стрелки отбрасывается целиком, а не
    /// подменяется на «прямо»: пустая клетка в ряду читается как поломка
    /// рендера, а выдуманная стрелка — как указание, которого никто не давал.
    nonisolated static func lanes(of step: OSRMResponse.Step) -> [LaneHint] {
        guard let lanes = step.intersections?.first?.lanes, !lanes.isEmpty else { return [] }
        let hints = lanes.compactMap { lane -> LaneHint? in
            let arrows = (lane.indications ?? []).compactMap(LaneArrow.fromOSRM)
            guard !arrows.isEmpty else { return nil }
            return LaneHint(arrows: arrows, isValid: lane.valid ?? false)
        }
        // Ряд, из которого выпала хоть одна полоса, врёт про их количество —
        // а водитель считает полосы глазами. Либо весь ряд, либо ничего.
        return hints.count == lanes.count ? hints : []
    }

    // MARK: - Применение результата

    private func apply(_ built: [BuiltVariant], name: String,
                       destination: CLLocationCoordinate2D, cameras: [Camera],
                       gen: Int) async {
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

        // Второй раз, и это не дублирование проверки у вызывающего: тот
        // сверял поколение ДО входа сюда, а внутри мы сами ушли в await на
        // время подсчёта камер по коридору. Успел человек за это время нажать
        // «отменить» или перестроить — generation вырос, и запись ниже вернула
        // бы на карту маршрут, который уже отменён. Правило 12: после каждого
        // await состояние перепроверяется, а не досчитывается по памяти.
        guard gen == generation else { return }

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

    nonisolated static func camerasAlong(pts: [MKMapPoint], bbox: MKMapRect,
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

    /// Кумулятивная длина маршрута: cum[i] — метры от старта до точки i.
    /// Считается один раз на маршрут: без неё project честно суммировал длину
    /// от нуля НА КАЖДОМ ТИКЕ — O(позиция), к середине междугородного маршрута
    /// это тысячи sqrt в секунду на main, и чем дольше едешь, тем горячее
    /// телефон. Ровно профиль жалобы «греется в дальней дороге».
    nonisolated static func cumulative(of pts: [MKMapPoint]) -> [CLLocationDistance] {
        guard !pts.isEmpty else { return [] }
        var cum = [CLLocationDistance](repeating: 0, count: pts.count)
        for i in 1..<pts.count { cum[i] = cum[i - 1] + pts[i - 1].distance(to: pts[i]) }
        return cum
    }

    /// Проекция точки на маршрут: (пройдено от старта, отклонение от линии).
    /// `hint` — индекс сегмента с прошлого раза: обычно машина рядом, полный перебор не нужен.
    /// `allowFullScan` — разрешён ли полный перебор при большом отклонении:
    /// пока водитель едет по дублёру, полный перебор всех сегментов шёл каждый
    /// тик (десятки тысяч операций в секунду минутами) — а отклонению для
    /// логики перестроения достаточно оконной оценки, точный индекс нужен реже.
    nonisolated static func project(_ p: MKMapPoint, onto pts: [MKMapPoint],
                                    cum: [CLLocationDistance],
                                    hint: inout Int,
                                    allowFullScan: Bool = true) -> (along: CLLocationDistance, deviation: CLLocationDistance) {
        let n = pts.count
        guard n >= 2, cum.count == n else { return (0, .greatestFiniteMagnitude) }

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
        if deviation > 200, allowFullScan {
            (index, t, deviation) = scan(0..<(n - 1))
        }
        hint = index

        let along = cum[index] + t * pts[index].distance(to: pts[index + 1])
        return (along, deviation)
    }

    /// Начальный кусок маршрута длиной `upTo` метров (пройденная часть).
    nonisolated static func traveledPrefix(points: [MKMapPoint],
                                                   upTo along: CLLocationDistance) -> MKPolyline? {
        guard along > 60, points.count >= 2 else { return nil }
        var result: [MKMapPoint] = [points[0]]
        var acc: CLLocationDistance = 0
        for i in 1..<points.count {
            let step = points[i - 1].distance(to: points[i])
            if acc + step >= along {
                let t = step > 0 ? (along - acc) / step : 0
                result.append(MKMapPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                                         y: points[i - 1].y + (points[i].y - points[i - 1].y) * t))
                break
            }
            acc += step
            result.append(points[i])
        }
        return result.count >= 2 ? MKPolyline(points: result, count: result.count) : nil
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
