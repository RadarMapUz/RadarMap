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
        /// Чем вариант хорош на фоне остальных (RouteChoice). У единственного
        /// варианта и после перестроения — пусто: сравнивать не с чем.
        var assessment: RouteChoice.Assessment = .none
        /// Ограничения полос на проездах прямо (только OSRM).
        var laneNotices: [LaneNotice] = []
        /// Где по линии остановка по пути (конец первого плеча). nil — без заезда.
        var stopAlong: CLLocationDistance?
        /// Сколько добавляют пробки (TrafficSnapshot.delay); nil — данных о
        /// пробках нет (не «ноль»: ноль значит «пробок нет», а это мы знаем
        /// только при свежем наборе).
        var trafficDelay: TimeInterval?

        /// Время в пути с пробками — его и показываем, и сравниваем.
        var expectedTime: TimeInterval { travelTime + (trafficDelay ?? 0) }
        var etaText: String { Formatting.duration(expectedTime) }
        var distanceText: String { Formatting.distance(distance) }
        /// «+12 мин из-за пробок» / «без пробок»; nil — данных нет.
        var trafficNote: String? {
            guard let trafficDelay else { return nil }
            if trafficDelay < 60 { return String(localized: "без пробок") }
            return String(format: String(localized: "+%@ из-за пробок"),
                          Formatting.unbreakable(Formatting.duration(trafficDelay)))
        }
    }

    private enum RouteError: Error {
        case noRoute          // оба движка не нашли путь между точками
        case serverUnreachable
    }

    private(set) var variants: [Variant] = []
    private(set) var selectedID = 0
    private(set) var destinationName: String = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D?

    /// Остановка по пути — АЗС, кафе — между машиной и целью.
    ///
    /// Раньше «АЗС по пути» из поиска строила НОВЫЙ маршрут до заправки, и
    /// цель поездки терялась: после заправки водитель вводил её заново. Теперь
    /// цель остаётся, маршрут идёт через остановку (OSRM принимает
    /// промежуточные точки), перестроение до остановки помнит о ней, после —
    /// ведёт прямо к цели.
    struct Stop {
        let coordinate: CLLocationCoordinate2D
        let name: String
    }
    private(set) var stop: Stop?
    private(set) var isBuilding = false
    private(set) var errorMessage: String?

    // Живой прогресс (обновляется на каждой GPS-точке при активном маршруте).
    private(set) var progressAlong: CLLocationDistance = 0
    /// Где рисовать стрелку: точка и направление НА линии маршрута, если
    /// машина от неё ближе routeSnapMeters, иначе nil. Только картинка —
    /// алерты и проезды живут на сыром фиксе. Не наблюдается: читает
    /// LocationService сразу после updateProgress.
    @ObservationIgnored private(set) var displaySnap: (coordinate: CLLocationCoordinate2D,
                                                       course: CLLocationDirection)?
    private(set) var nextCamera: RouteCamera?
    private(set) var nextCameraDistance: CLLocationDistance = 0
    private(set) var nextStep: RouteStep?
    private(set) var nextStepDistance: CLLocationDistance = 0
    /// Ближайшее ограничение полос на проезде прямо — до следующего манёвра и
    /// не дальше laneNoticeMeters.
    private(set) var laneNotice: LaneNotice?
    private(set) var laneNoticeDistance: CLLocationDistance = 0

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

    /// Свежие пробки для времени в пути; nil — нет данных или выключено.
    /// Ставит AppEnvironment (TrafficService). Снимок Sendable: задержка по
    /// вариантам считается вне главного потока вместе с камерами коридора.
    @ObservationIgnored var trafficSnapshot: (() -> TrafficSnapshot?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: trafficSnapshot,
                                               "RouteService.trafficSnapshot") }
    }
    /// Задержка пробками на ОСТАВШЕЙСЯ части маршрута — пересчитывается не на
    /// каждом фиксе, а каждые `routeTrafficRecomputeMeters` и на новом наборе.
    private(set) var remainingTrafficDelay: TimeInterval = 0
    @ObservationIgnored private var trafficAlong: CLLocationDistance = -.infinity
    @ObservationIgnored private var trafficRevisionSeen = -1

    @ObservationIgnored var onRerouted: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onRerouted,
                                               "RouteService.onRerouted") }
    }
    /// Найден объезд пробки — сказать водителю (голос). Решение принимает он.
    @ObservationIgnored var onDetourOffer: ((DetourOffer) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onDetourOffer,
                                               "RouteService.onDetourOffer") }
    }
    @ObservationIgnored var onArrived: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onArrived,
                                               "RouteService.onArrived") }
    }
    /// Что выбор варианта знает о водителе (треки, камеры с превышением).
    /// nil — выбор по своим поездкам выключен в настройках.
    @ObservationIgnored var personalHistory: (() -> RouteChoice.History?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: personalHistory,
                                               "RouteService.personalHistory") }
    }
    /// Язык названий улиц в манёврах (`AppLanguage.mapCode`). Спрашиваем в
    /// момент построения: OSRM отдаёт имя узбекской латиницей, и в русской
    /// версии его надо переписать (см. StreetName). nil — как в русской.
    @ObservationIgnored var streetNameLanguage: (() -> String)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: streetNameLanguage,
                                               "RouteService.streetNameLanguage") }
    }
    @ObservationIgnored var onManeuver: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onManeuver,
                                               "RouteService.onManeuver") }
    }

    /// Тип впервые произнесённого манёвра — для суточного счётчика. Отдельно
    /// от `onManeuver`: тот несёт фразу и срабатывает до трёх раз на манёвр, а
    /// считать надо манёвры, а не повторы. Этот счётчик поймал бы «поверните
    /// направо» на прямой дороге за один день (plan_algorithms.md, А3).
    @ObservationIgnored var onManeuverSpoken: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onManeuverSpoken,
                                               "RouteService.onManeuverSpoken") }
    }

    @ObservationIgnored private var offRouteTicks = 0
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
    var trafficNote: String? { selected?.trafficNote }
    var trafficDelay: TimeInterval? { selected?.trafficDelay }

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
        return selected.travelTime * remainingDistance / selected.distance + remainingTrafficDelay
    }

    /// Пересчитать задержку пробками на остатке пути: на новом наборе пробок
    /// (`revision`) или когда проехали `routeTrafficRecomputeMeters`.
    func refreshTrafficDelay(revision: Int) {
        guard let selected else {
            if remainingTrafficDelay != 0 { remainingTrafficDelay = 0 }
            return
        }
        guard revision != trafficRevisionSeen
                || abs(progressAlong - trafficAlong) >= AppConfig.routeTrafficRecomputeMeters else { return }
        trafficRevisionSeen = revision
        trafficAlong = progressAlong
        let delay = trafficSnapshot?().map { $0.delay(along: Self.remaining(selected.points, after: progressAlong)) } ?? 0
        if abs(delay - remainingTrafficDelay) >= 1 { remainingTrafficDelay = delay }
    }

    /// Точки маршрута после `along` метров от начала.
    nonisolated static func remaining(_ points: [MKMapPoint], after along: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return [] }
        var acc: CLLocationDistance = 0
        for i in 1..<points.count {
            acc += points[i - 1].distance(to: points[i])
            if acc >= along { return points[(i - 1)...].map(\.coordinate) }
        }
        return []
    }
    var arrivalDate: Date { Date().addingTimeInterval(remainingTime) }

    /// Путь впереди от машины до `meters` (для проб лимита): от текущей
    /// точки по линии маршрута. nil — маршрута нет.
    func pathAhead(from coordinate: CLLocationCoordinate2D, meters: CLLocationDistance) -> [CLLocationCoordinate2D]? {
        guard let selected else { return nil }
        let rest = Self.remaining(selected.points, after: progressAlong)
        guard rest.count >= 2 else { return nil }
        var path = [coordinate]
        var total: CLLocationDistance = 0
        for point in rest.dropFirst() {
            if let last = path.last {
                total += GeoMath.fastDistance(last.latitude, last.longitude, point.latitude, point.longitude)
            }
            path.append(point)
            if total >= meters { break }
        }
        return path
    }

    // MARK: - Построение

    /// Живой точки нет — маршрут не строим вовсе, и говорим об этом.
    ///
    /// Сообщение идёт тем же каналом, что остальные отказы (`BottomHint`
    /// показывает `errorMessage`): молчаливое «ничего не произошло» после тапа
    /// читается как поломка кнопки.
    func reportNoFix() {
        errorMessage = String(localized: "Не видим вашего положения — маршрут не построен")
    }

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
        resetDetour()

        lastArrival = nil   // новый маршрут — карточка прошлого прибытия неактуальна
        do {
            let built = try await calculate(from: source, via: nil, to: destination,
                                            alternatives: alternatives)
            guard gen == generation else { return }   // пока считали — маршрут сбросили/заменили
            // Новая цель — остановка прежнего маршрута не её. Забываем ТОЛЬКО
            // после успеха: не построилось — прежняя линия (через остановку)
            // остаётся, и перестроение по ней обязано помнить заезд.
            stop = nil
            await apply(built, name: name, destination: destination,
                        cameras: cameras, gen: gen, history: personalHistory?())
        } catch RouteError.serverUnreachable {
            errorMessage = String(localized: "Нет связи с сервером маршрутов — проверьте интернет")
        } catch {
            errorMessage = String(localized: "Маршрут не найден")
        }
    }

    /// Заехать по пути: та же цель, маршрут через `coordinate`.
    ///
    /// Без альтернатив и только своим OSRM: MKDirections промежуточных точек
    /// не знает, а сравнивать варианты заезда незачем — точку человек уже
    /// выбрал сам. Не вышло — старый маршрут остаётся как был, с сообщением.
    func addStop(_ coordinate: CLLocationCoordinate2D, name: String,
                 from source: CLLocationCoordinate2D, cameras: [Camera]) async {
        errorMessage = nil   // прежняя ошибка — не причина этого отказа
        guard isActive, let destination = destinationCoordinate else {
            // Маршрут успел закончиться (приехали, сбросили), пока выбирали место.
            errorMessage = String(localized: "Маршрута уже нет — заезд не добавлен")
            return
        }
        guard isRoutingEnabled else {
            errorMessage = String(localized: "Маршруты временно недоступны — мы уже чиним")
            return
        }
        isBuilding = true
        errorMessage = nil
        defer { isBuilding = false }
        generation += 1
        let gen = generation
        let destinationName = self.destinationName
        let newStop = Stop(coordinate: coordinate, name: name)
        do {
            let built = try await calculate(from: source, via: newStop, to: destination,
                                            alternatives: false)
            guard gen == generation else { return }
            stop = newStop
            await apply(built, name: destinationName, destination: destination,
                        cameras: cameras, gen: gen, history: nil)
        } catch RouteError.serverUnreachable {
            errorMessage = String(localized: "Нет связи с сервером маршрутов — проверьте интернет")
        } catch {
            errorMessage = String(localized: "Не удалось заехать по пути — маршрут прежний")
        }
    }

    func selectVariant(_ id: Int) {
        guard id != selectedID, variants.contains(where: { $0.id == id }) else { return }
        selectedID = id
        resetProgress()
    }

    func clear() {
        generation += 1   // rebuild в полёте не должен вернуть линию на карту
        resetDetour()
        variants = []
        selectedID = 0
        destinationName = ""
        destinationCoordinate = nil
        stop = nil
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
        if remainingDistance < AppConfig.arrivalOnTripEndMeters
            || destinationDistance < AppConfig.arrivalOnTripEndMeters {
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
        displaySnap = nil
        nextCamera = nil
        nextCameraDistance = 0
        nextStep = nil
        nextStepDistance = 0
        laneNotice = nil
        laneNoticeDistance = 0
        offRouteTicks = 0
        announcedStage = [:]
        segmentHint = 0
        // Задержка пробками — с варианта (посчитана при построении); дальше
        // её ведёт refreshTrafficDelay по ходу и по новым наборам.
        remainingTrafficDelay = selected?.trafficDelay ?? 0
        trafficAlong = 0
    }

    // MARK: - Прогресс: прибытие, следующая камера, манёвры, перестроение

    /// Вызывается на каждой GPS-точке. `announce` — озвучивать ли манёвры (в поездке).
    /// `course` — курс, которому МОЖНО верить (его выдаёт LocationFilter);
    /// `-1` означает «курса нет», и тогда он в выборе положения не участвует.
    func updateProgress(coordinate: CLLocationCoordinate2D, cameras: [Camera], announce: Bool,
                        course: CLLocationDirection = -1) {
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
                                              allowFullScan: offRouteTicks % 3 == 0,
                                              course: course)
        progressAlong = along
        displaySnap = deviation <= AppConfig.routeSnapMeters
            ? Self.pointAndCourse(along: along, pts: variant.points, cum: selectedCumulative)
            : nil

        // Прибытие: у самой цели ИЛИ проехали финиш по маршруту (парковка чуть в стороне,
        // GPS-точка не попала в малый радиус — маршрут всё равно выполнен).
        let destinationDistance = point.distance(to: MKMapPoint(destination))
        if destinationDistance <= AppConfig.arrivalRadiusMeters
            || (variant.distance - along < AppConfig.arrivalPassedRemainingMeters
                && destinationDistance < AppConfig.arrivalPassedRadiusMeters) {
            arrive()
            return
        }

        // Остановка по пути пройдена — дальше перестроение ведёт прямо к цели.
        if let current = stop,
           point.distance(to: MKMapPoint(current.coordinate)) <= AppConfig.routeStopReachedMeters
            || variant.stopAlong.map({ along > $0 + AppConfig.routeStopPassedMeters }) == true {
            stop = nil
        }

        // Следующая камера впереди по маршруту.
        if let cam = variant.cameras.first(where: {
            $0.distanceAlong > along - AppConfig.routeCameraBehindSlackMeters
        }) {
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
        let via = stop   // ещё не заехали — объезд всё равно через остановку
        Task {
            defer { isRebuilding = false }
            // Перестраиваем без альтернатив — быстрее, и в движении выбор не нужен.
            guard let built = try? await calculate(from: coordinate, via: via, to: destination,
                                                   alternatives: false) else {
                rerouteFailures += 1
                Log.route.error("перестроение маршрута не удалось (\(self.rerouteFailures, privacy: .public)-й раз) — остаёмся на старой линии")
                return
            }
            guard gen == generation else { return }   // маршрут успели сбросить/заменить
            rerouteFailures = 0
            await apply(built, name: name, destination: destination,
                        cameras: cameras, gen: gen, history: nil)
            onRerouted?()
        }
    }

    private func updateManeuvers(variant: Variant, along: CLLocationDistance, announce: Bool) {
        // Первый манёвр впереди (с запасом, чтобы не «перескакивал» на повороте).
        let index = variant.steps.firstIndex(where: {
            $0.distanceAlong > along + AppConfig.maneuverAheadSlackMeters
        })
        updateLaneNotice(variant: variant, along: along,
                         before: index.map { variant.steps[$0].distanceAlong } ?? .infinity)
        guard let index else {
            nextStep = nil
            return
        }
        let step = variant.steps[index]
        let distance = step.distanceAlong - along
        nextStep = step
        nextStepDistance = distance

        guard announce else { return }
        let stage = announcedStage[index] ?? 3
        switch Self.voiceStage(distance: distance, spoken: stage,
                               earlyCall: step.kind?.deservesEarlyCall ?? true) {
        case 0?:
            announcedStage[index] = 0
            onManeuver?(step.text)
        case 1?:
            announcedStage[index] = 1
            onManeuver?(Self.withLanes(String(format: String(localized: "Через %lld метров — %@"),
                                              Int((distance / 50).rounded() * 50), step.text),
                                       step.lanes))
        case 2?:
            announcedStage[index] = 2
            onManeuver?(Self.withLanes(String(format: String(localized: "Через %lld метров — %@"),
                                              Int((distance / 100).rounded() * 100), step.text),
                                       step.lanes))
        default:
            break
        }
        // Считаем манёвр один раз — при первом объявлении. Хранимые ступени
        // это 0…2, поэтому «было 3» означает «до сих пор не объявляли».
        if stage == 3, announcedStage[index] != nil {
            onManeuverSpoken?(step.kind?.rawValue ?? "unknown")
        }
    }

    /// Какую ступень голоса манёвра пора произнести: 2 — далеко («через 800
    /// метров»), 1 — близко, 0 — сама команда; nil — молчать. `spoken` — уже
    /// произнесённая ступень (3 — ещё ни одной). Ступень произносится один
    /// раз и только «вниз»: проскочив дальнюю (въехали в маршрут уже у
    /// поворота), сразу говорим ближнюю, а не догоняем пропущенную.
    nonisolated static func voiceStage(distance: CLLocationDistance, spoken: Int,
                                       earlyCall: Bool) -> Int? {
        if distance < AppConfig.maneuverNowCallMeters, spoken > 0 { return 0 }
        if distance < AppConfig.maneuverNearCallMeters, spoken > 1 { return 1 }
        if distance < AppConfig.maneuverFarCallMeters, spoken > 2, earlyCall { return 2 }
        return nil
    }

    /// Ограничение полос впереди: до манёвра (его ряд — в баннере манёвра) и
    /// не дальше laneNoticeMeters. Присваиваем только смену: свойство
    /// наблюдаемое, а тик — раз в секунду.
    private func updateLaneNotice(variant: Variant, along: CLLocationDistance,
                                  before maneuver: CLLocationDistance) {
        let notice = variant.laneNotices.first { notice in
            notice.distanceAlong > along + 15
                && notice.distanceAlong < maneuver - AppConfig.laneNoticeBeforeManeuverMeters
                && notice.distanceAlong - along <= AppConfig.laneNoticeMeters
        }
        if notice != laneNotice { laneNotice = notice }
        laneNoticeDistance = notice.map { $0.distanceAlong - along } ?? 0
    }

    /// Заблаговременная фраза манёвра + в какой ряд встать («…на Беруни.
    /// Из двух левых рядов.»). Только для ранних объявлений: на «сейчас»
    /// перестраиваться уже поздно, и лишние слова там мешают.
    nonisolated static func withLanes(_ phrase: String, _ lanes: [LaneHint]) -> String {
        guard let advice = LaneAdvice.phrase(lanes) else { return phrase }
        return phrase + ". " + advice
    }

    // MARK: - Движки

    private struct BuiltVariant {
        let points: [MKMapPoint]
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let steps: [RouteStep]
        var laneNotices: [LaneNotice] = []
        var stopAlong: CLLocationDistance?
    }

    private func calculate(from source: CLLocationCoordinate2D,
                           via stop: Stop?,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool) async throws -> [BuiltVariant] {
        // Сбой Apple-роутинга — штатный путь: ниже падаем на собственный OSRM.
        // С остановкой — сразу OSRM: промежуточных точек MKDirections не знает.
        if stop == nil,
           let apple = try? await appleRoute(from: source, to: destination, alternatives: alternatives),
           !apple.isEmpty { return apple }
        return try await osrmRoute(from: source, via: stop, to: destination, alternatives: alternatives)
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
            // Шаг без текста тоже занимает дорогу: пропуская его, не прибавляли
            // и его длину — следующие манёвры съезжали назад по маршруту.
            for step in route.steps {
                if !step.instructions.isEmpty {
                    steps.append(RouteStep(distanceAlong: along, text: step.instructions, icon: "arrow.up"))
                }
                along += step.distance
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.expectedTravelTime, steps: steps)
        }
    }

    private func osrmRoute(from source: CLLocationCoordinate2D,
                           via stop: Stop?,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool) async throws -> [BuiltVariant] {
        let path = ([source] + (stop.map { [$0.coordinate] } ?? []) + [destination])
            .map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }
            .joined(separator: ";")
        var components = URLComponents(url: AppConfig.osrmBaseURL
            .appendingPathComponent("route/v1/driving")
            .appendingPathComponent(path),
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
            var request = URLRequest(url: components.url!, timeoutInterval: AppConfig.osrmTimeoutSeconds)
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

        // Один язык на весь ответ: фраза баннера и голос получают одно имя.
        let language = streetNameLanguage?() ?? "ru"
        guard let parsed = await Self.parseOSRM(data, language: language, stopName: stop?.name) else {
            throw RouteError.noRoute
        }
        return parsed
    }

    /// Разбор ответа OSRM — ВНЕ главного потока. Междугородний ответ — это
    /// мегабайты GeoJSON (десятки тысяч точек на каждый из трёх вариантов), и
    /// разбор на главном шёл ровно в момент перестроения на ходу: съехал с
    /// маршрута — и карта с голосом замирали на разборе. nil — ответ пуст или
    /// не читается (причина — в журнале).
    ///
    /// Плечи (`legs`) идут подряд: с остановкой по пути их два, и манёвры
    /// второго считаются от начала маршрута, а прибытие первого — это заезд.
    @concurrent
    private nonisolated static func parseOSRM(_ data: Data, language: String,
                                              stopName: String?) async -> [BuiltVariant]? {
        let response: OSRMResponse
        do {
            response = try JSONDecoder().decode(OSRMResponse.self, from: data)
        } catch {
            Log.route.error("OSRM: ответ не разобран — \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard response.code == "Ok", let routes = response.routes, !routes.isEmpty else {
            Log.route.error("OSRM: код \(response.code, privacy: .public), маршрутов нет")
            return nil
        }
        let variants = routes.prefix(3).compactMap { route -> BuiltVariant? in
            guard route.geometry.coordinates.count >= 2 else { return nil }
            let points = route.geometry.coordinates.map {
                MKMapPoint(CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]))
            }
            var steps: [RouteStep] = []
            var notices: [LaneNotice] = []
            var along: CLLocationDistance = 0
            var stopAlong: CLLocationDistance?
            for (legIndex, leg) in route.legs.enumerated() {
                let isLast = legIndex == route.legs.count - 1
                for step in leg.steps {
                    let built = maneuverStep(step, at: along, language: language,
                                             stopName: isLast ? nil : stopName)
                    if let built { steps.append(built) }
                    notices += laneNotices(step, at: along, isManeuver: built != nil)
                    along += step.distance
                }
                if !isLast, stopAlong == nil { stopAlong = along }
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.duration, steps: steps, laneNotices: notices,
                                stopAlong: stopAlong)
        }
        return variants.isEmpty ? nil : variants
    }

    /// nonisolated: разбирается в фоне (parseOSRM) — изоляция главным потоком
    /// сделала бы и соответствие Decodable главнопоточным.
    nonisolated struct OSRMResponse: Decodable {
        let code: String
        let routes: [Route]?
        nonisolated struct Route: Decodable {
            let distance: Double
            let duration: Double
            let geometry: Geometry
            let legs: [Leg]
        }
        nonisolated struct Geometry: Decodable {
            let coordinates: [[Double]]   // GeoJSON: [lon, lat]
        }
        nonisolated struct Leg: Decodable { let steps: [Step] }
        nonisolated struct Step: Decodable {
            let distance: Double
            let name: String
            let maneuver: Maneuver
            /// Полосы приезжают здесь и раньше молча выбрасывались. `var` с
            /// умолчанием, а не `let`: у структуры синтезируется ещё и
            /// memberwise-инициализатор, которым пользуются тесты.
            var intersections: [Intersection]? = nil
        }
        nonisolated struct Maneuver: Decodable {
            let type: String
            let modifier: String?
            let exit: Int?
            /// [lon, lat] точки манёвра — начало шага.
            var location: [Double]? = nil
        }
        nonisolated struct Intersection: Decodable {
            let lanes: [Lane]?
            /// [lon, lat] перекрёстка.
            var location: [Double]? = nil
        }
        nonisolated struct Lane: Decodable {
            let valid: Bool?
            let indications: [String]?
        }
    }

    /// OSRM-манёвр → человеческая фраза + иконка. nil — шаг не озвучиваем (смена названия улицы и т.п.).
    /// `language` — язык приложения («ru»/«uz»): имя улицы во фразе приводится
    /// к нему (StreetName), и ту же фразу произносит голос (onManeuver).
    /// `stopName` — прибытие этого шага не к цели, а к остановке по пути:
    /// «заезд: АЗС Лукойл» вместо «вы прибыли».
    nonisolated static func maneuverStep(_ step: OSRMResponse.Step,
                                         at along: CLLocationDistance,
                                         language: String,
                                         stopName: String? = nil) -> RouteStep? {
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
            if let stopName {
                text = String(format: String(localized: "заезд: %@"), stopName); icon = "mappin.circle.fill"
            } else {
                text = String(localized: "вы прибыли"); icon = "flag.checkered"
            }
        default:
            break   // depart, new name и прочее не озвучиваем
        }

        guard var result = text else { return nil }
        let phrase = result
        if !step.name.isEmpty, m.type != "arrive" {
            // «на улицу Беруни», а не «на Beruniy shoh ko'chasi»: фраза просит
            // винительный падеж.
            let street = StreetName.display(step.name, language: language,
                                            grammaticalCase: .accusative)
            result += String(format: String(localized: " на %@"), street)
        }
        // Тип манёвра — отдельно от фразы. Фраза зависит ещё и от типа
        // развязки («держитесь правее» на развилке против «поверните направо»
        // на перекрёстке), а геометрия поворота — только от модификатора.
        let kind: ManeuverKind = m.type == "arrive" ? .arrive
            : m.type == "roundabout" || m.type == "rotary" ? .roundabout
            : ManeuverKind.fromOSRM(modifier: m.modifier)
        return RouteStep(distanceAlong: along, text: result, icon: icon,
                         kind: kind, lanes: lanes(of: step),
                         shortText: result == phrase ? nil : phrase)
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
        return hints(lanes)
    }

    /// Ограничения полос на перекрёстках, которые шаг проезжает ПРЯМО.
    ///
    /// Первый перекрёсток шага-манёвра — сам манёвр (его полосы уже в
    /// RouteStep); у шага без манёвра («new name», «continue») он тоже проезд.
    /// Берётся только ряд, где есть и подходящие, и неподходящие полосы: «все
    /// годятся» — сказать нечего. Положение — от точки начала шага по прямой:
    /// внутри шага дорога почти прямая, а подсказке полос хватает и такого.
    nonisolated static func laneNotices(_ step: OSRMResponse.Step, at along: CLLocationDistance,
                                        isManeuver: Bool) -> [LaneNotice] {
        guard let intersections = step.intersections,
              let start = step.maneuver.location, start.count == 2 else { return [] }
        var out: [LaneNotice] = []
        for (index, intersection) in intersections.enumerated() {
            if index == 0, isManeuver { continue }
            guard let lanes = intersection.lanes, !lanes.isEmpty,
                  let point = intersection.location, point.count == 2 else { continue }
            let row = hints(lanes)
            guard row.contains(where: \.isValid), row.contains(where: { !$0.isValid }) else { continue }
            let offset = min(step.distance,
                             GeoMath.fastDistance(start[1], start[0], point[1], point[0]))
            out.append(LaneNotice(distanceAlong: along + offset, lanes: row))
        }
        return out
    }

    nonisolated private static func hints(_ lanes: [OSRMResponse.Lane]) -> [LaneHint] {
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
                       gen: Int, history: RouteChoice.History?) async {
        // Камеры по коридору каждого варианта считаем ВНЕ главного потока —
        // длинные маршруты не должны дёргать UI даже на старых устройствах.
        let inputs = built.filter { $0.points.count >= 2 }
        guard !inputs.isEmpty else { return }
        let traffic = trafficSnapshot?()

        // Там же — выбор варианта по своим поездкам: сравнение с сотней
        // треков стоит десятки миллисекунд, главному потоку они не нужны.
        let (variantCameras, verdict, trafficDelays) = await Task.detached(priority: .userInitiated) {
            let found = inputs.map { variant -> [RouteCamera] in
                var bbox = MKMapRect.null
                for p in variant.points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
                let centerLat = variant.points[variant.points.count / 2].coordinate.latitude
                return Self.camerasAlong(pts: variant.points, bbox: bbox,
                                         centerLat: centerLat, cameras: cameras)
            }
            // Пробки — к каждому варианту: «Быстрый» выбирается по времени
            // с пробками, а не по пустым дорогам графа.
            let delays = inputs.map { variant in traffic?.delay(along: variant.points.map(\.coordinate)) }
            let choice = RouteChoice.decide(inputs.indices.map { index in
                RouteChoice.Input(path: inputs[index].points.map(\.coordinate),
                                  distance: inputs[index].distance,
                                  travelTime: inputs[index].travelTime + (delays[index] ?? 0),
                                  cameraIDs: found[index].map(\.camera.id),
                                  hardManeuvers: RouteChoice.hardManeuvers(inputs[index].steps))
            }, history: history)
            return (found, choice, delays)
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
                    steps: variant.steps,
                    assessment: verdict.assessments[index],
                    laneNotices: variant.laneNotices,
                    stopAlong: variant.stopAlong,
                    trafficDelay: trafficDelays[index])
        }
        selectedID = verdict.recommended
        destinationName = name
        destinationCoordinate = destination
        errorMessage = nil
        resetProgress()
        // Первый манёвр — сразу, а не со следующим фиксом: маршрут начинается
        // там, где стоит машина, а у стоящей машины фикса может не быть минуту
        // (distanceFilter). Всё это время экран машины показывал «Loading…»
        // вместо поворота (CarPlay Simulator, 11.10), а телефон — пустую
        // карточку манёвра. Без голоса: озвучка — дело живого прогресса.
        if let variant = selected { updateManeuvers(variant: variant, along: 0, announce: false) }
    }

    // MARK: - Объезд пробки (DetourAdvisor)

    /// Предложение объезда, ждущее ответа водителя. Маршрут без его нажатия
    /// не меняется никогда.
    struct DetourOffer: Identifiable, Equatable {
        let id: Int
        /// Сколько выигрывает объезд, секунды.
        let saving: TimeInterval
        /// Улица, которой объезд уходит; nil — не назвать.
        let via: String?
        /// Без ответа до этого момента — «остаёмся».
        let expires: Date

        /// «Быстрее на 8 мин».
        var title: String {
            String(format: String(localized: "Быстрее на %@"), Formatting.unbreakable(Formatting.duration(saving)))
        }
        /// «Объезд пробки · через Шота Руставели».
        var subtitle: String {
            guard let via else { return String(localized: "Объезд пробки") }
            return String(format: String(localized: "Объезд пробки · через %@"), via)
        }
        /// Фраза голосом.
        var spoken: String {
            let head = String(format: String(localized: "Впереди пробка. Есть путь быстрее на %@"),
                              Formatting.duration(saving))
            guard let via else { return head }
            return head + String(format: String(localized: ", через %@"), via)
        }
    }

    private(set) var detourOffer: DetourOffer?
    @ObservationIgnored private var detourVariant: BuiltVariant?
    @ObservationIgnored private var detourCounter = 0
    @ObservationIgnored private var detourCrawl = DetourAdvisor.CrawlWatch()
    @ObservationIgnored private var detourSearchAt: Date?
    @ObservationIgnored private var detourDeclinedAt: Date?
    @ObservationIgnored private var detourOffers = 0
    @ObservationIgnored private var detourSearching = false

    /// На каждом фиксе поездки — и стоя: в пробке машина не сдвигается, и
    /// updateProgress (он ждёт смещения) молчит ровно тогда, когда объезд нужен.
    func considerDetour(coordinate: CLLocationCoordinate2D, speedKmh: Double, now: Date = Date()) {
        if let offer = detourOffer, now >= offer.expires { declineDetour(now: now, reason: "нет ответа") }
        let crawl = detourCrawl.update(speedKmh: speedKmh, at: now)
        guard let variant = selected, let destination = destinationCoordinate,
              !isBuilding, !isRebuilding, detourOffer == nil, !detourSearching,
              let snapshot = trafficSnapshot?(), snapshot.isFresh(now: now),
              DetourAdvisor.shouldSearch(remainingDistance: remainingDistance,
                                         delayAhead: remainingTrafficDelay, crawl: crawl,
                                         sinceLastSearch: detourSearchAt.map { now.timeIntervalSince($0) },
                                         sinceDecline: detourDeclinedAt.map { now.timeIntervalSince($0) },
                                         offersOnRoute: detourOffers) else { return }
        detourSearching = true
        detourSearchAt = now
        let gen = generation
        let current = Self.remaining(variant.points, after: progressAlong)
        let currentRemaining = remainingTime
        let via = stop
        Log.route.notice("объезд: ищу — впереди +\(Int(self.remainingTrafficDelay), privacy: .public) с, ползём \(Int(crawl), privacy: .public) с")
        Task {
            defer { detourSearching = false }
            guard let built = try? await calculate(from: coordinate, via: via, to: destination,
                                                   alternatives: true),
                  gen == generation else { return }
            let candidates = built.map { variant in
                (points: variant.points.map(\.coordinate), travelTime: variant.travelTime, steps: variant.steps)
            }
            let offer = await Task.detached(priority: .utility) { () -> DetourAdvisor.Offer? in
                let scored = candidates.map { candidate in
                    DetourAdvisor.Candidate(points: candidate.points,
                                            expectedTime: candidate.travelTime + snapshot.delay(along: candidate.points),
                                            steps: candidate.steps)
                }
                return DetourAdvisor.decide(currentRemaining: currentRemaining, current: current, candidates: scored)
            }.value
            guard gen == generation, detourOffer == nil else { return }
            guard let offer, built.indices.contains(offer.index) else {
                Log.route.notice("объезд: выгодного нет")
                return
            }
            detourVariant = built[offer.index]
            detourCounter += 1
            detourOffers += 1
            let shown = DetourOffer(id: detourCounter, saving: offer.saving, via: offer.via,
                                    expires: Date().addingTimeInterval(AppConfig.detourOfferSeconds))
            detourOffer = shown
            Log.route.notice("объезд: предлагаю, выигрыш \(Int(offer.saving), privacy: .public) с")
            onDetourOffer?(shown)
        }
    }

    /// «Объехать»: тот вариант становится маршрутом.
    func acceptDetour(cameras: [Camera]) {
        guard detourOffer != nil, let built = detourVariant, let destination = destinationCoordinate else { return }
        detourOffer = nil
        detourVariant = nil
        generation += 1
        let gen = generation
        let name = destinationName
        Log.route.notice("объезд: принят")
        Task {
            await apply([built], name: name, destination: destination, cameras: cameras, gen: gen, history: nil)
            guard gen == generation else { return }
            onRerouted?()
        }
    }

    /// «Остаться» (или нет ответа): 10 минут тишины.
    func declineDetour(now: Date = Date(), reason: String = "остаться") {
        guard detourOffer != nil else { return }
        detourOffer = nil
        detourVariant = nil
        detourDeclinedAt = now
        Log.route.notice("объезд: отказ (\(reason, privacy: .public))")
    }

    #if DEBUG
    /// Скриншот-хук `-demoDetour`: карточка объезда без настоящей пробки.
    /// Варианта за ней нет — «Объехать» ничего не меняет.
    func seedDemoDetourOffer() {
        detourCounter += 1
        detourOffer = DetourOffer(id: detourCounter, saving: 8 * 60, via: "Шота Руставели",
                                  expires: Date().addingTimeInterval(120))
    }
    #endif

    private func resetDetour() {
        detourOffer = nil
        detourVariant = nil
        detourSearchAt = nil
        detourDeclinedAt = nil
        detourOffers = 0
        detourCrawl.reset()
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
    /// Точка и направление на линии через `along` метров от старта.
    nonisolated static func pointAndCourse(along: CLLocationDistance, pts: [MKMapPoint],
                                           cum: [CLLocationDistance])
    -> (coordinate: CLLocationCoordinate2D, course: CLLocationDirection)? {
        let n = pts.count
        guard n >= 2, cum.count == n else { return nil }
        let target = min(max(0, along), cum[n - 1])
        // Двоичный поиск сегмента: cum возрастает.
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= target { lo = mid } else { hi = mid }
        }
        let i = lo
        let a = pts[i], b = pts[i + 1]
        let span = cum[i + 1] - cum[i]
        let t = span > 0 ? (target - cum[i]) / span : 0
        let point = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let from = a.coordinate, to = b.coordinate
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let course = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (point.coordinate, course)
    }

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
                                    allowFullScan: Bool = true,
                                    course: CLLocationDirection = -1)
    -> (along: CLLocationDistance, deviation: CLLocationDistance) {
        let n = pts.count
        guard n >= 2, cum.count == n else { return (0, .greatestFiniteMagnitude) }

        // Выбираем не просто ближайший сегмент, а согласованный с курсом:
        // встречный получает надбавку к расстоянию. Возвращаем при этом
        // ИСТИННОЕ отклонение, а не оценку с надбавкой, — на нём стоит решение
        // о перестроении маршрута.
        func scan(_ range: Range<Int>) -> (Int, Double, CLLocationDistance) {
            var bestIndex = range.lowerBound
            var bestT = 0.0
            var bestScore = Double.greatestFiniteMagnitude
            var bestDist = Double.greatestFiniteMagnitude
            for i in range {
                let (closest, t) = closestPoint(p, pts[i], pts[i + 1])
                let d = p.distance(to: closest)
                let score = d + wrongWayPenalty(from: pts[i], to: pts[i + 1], course: course)
                if score < bestScore {
                    bestScore = score; bestDist = d; bestIndex = i; bestT = t
                }
            }
            return (bestIndex, bestT, bestDist)
        }

        // Окно вокруг прошлой позиции — в МЕТРАХ по кумулятиву, а не в
        // вершинах: у полилинии OSRM их плотность на прямой и в повороте
        // отличается на порядок, и «сорок вершин» означало то сто метров, то
        // три километра (docs/plan_algorithms.md, А1).
        let anchor = cum[min(max(hint, 0), n - 1)]
        let lo = max(0, lowerBound(cum, anchor - AppConfig.routeProjectBackMeters) - 1)
        let hi = min(n - 1, max(lo + 1,
                                lowerBound(cum, anchor + AppConfig.routeProjectAheadMeters)))
        var (index, t, deviation) = scan(lo..<hi)
        // Далеко от окна — полный перебор: так маршрут ловится заново после
        // объезда. Курс участвует и здесь, иначе перебор сам и притягивал бы
        // точку на обратную ветку.
        if deviation > 200, allowFullScan {
            (index, t, deviation) = scan(0..<(n - 1))
        }
        hint = index

        let along = cum[index] + t * pts[index].distance(to: pts[index + 1])
        return (along, deviation)
    }

    /// Первый индекс, у которого `cum[i] >= value`. Кумулятив отсортирован,
    /// поэтому двоичный поиск: линейный проход по нему на каждом тике — это то
    /// самое, от чего кумулятив когда-то и завели.
    nonisolated private static func lowerBound(_ cum: [CLLocationDistance],
                                               _ value: CLLocationDistance) -> Int {
        var lo = 0, hi = cum.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Надбавка сегменту, идущему против нашего курса. `-1` — курса нет, и
    /// тогда никакой надбавки: недостоверный курс не вправе двигать прогресс.
    nonisolated private static func wrongWayPenalty(from a: MKMapPoint, to b: MKMapPoint,
                                                    course: CLLocationDirection)
    -> CLLocationDistance {
        guard course >= 0 else { return 0 }
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return 0 }
        let bearing = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        var diff = abs(bearing - course).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff > 90 ? AppConfig.routeWrongWayPenaltyMeters : 0
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
