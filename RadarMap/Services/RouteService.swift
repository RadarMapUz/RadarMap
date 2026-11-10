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
        /// Доказанно встречная для линии маршрута (RouteCameraDirection, 27.J):
        /// в коридоре, но не наша — её судят обычные гейты по живому фиксу.
        var provenOncoming = false
        var id: Int { camera.id }
        /// Маршрут вправе назвать её нашей (шаг 1 гейтов).
        var countsAsOurs: Bool { !provenOncoming }
    }

    /// Один вариант маршрута — в виде, не зависящем от движка.
    struct Variant: Identifiable {
        let id: Int
        let points: [MKMapPoint]
        let polyline: MKPolyline
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let cameras: [RouteCamera]
        /// `var`: слой полос (20.8), приехавший после построения, прикладывается
        /// к уже построенному варианту (`laneOverlayChanged`).
        var steps: [RouteStep]
        /// Чем вариант хорош на фоне остальных (RouteChoice). У единственного
        /// варианта и после перестроения — пусто: сравнивать не с чем.
        var assessment: RouteChoice.Assessment = .none
        /// Ограничения полос на проездах прямо (OSRM и слой полос).
        var laneNotices: [LaneNotice] = []
        /// Где спросить слой полос: манёвры и проезды без полос OSRM (только OSRM).
        var laneProbes: [LaneProbe] = []
        /// Где по линии остановка по пути (конец первого плеча). nil — без заезда.
        var stopAlong: CLLocationDistance?
        /// Построен на телефоне по своему графу трасс без сети (12б.10):
        /// без запретов поворотов и без манёвров — «приблизительно».
        var isOffline = false
        /// Сколько добавляют пробки (TrafficForecast: живые и обычные для
        /// часа); nil — данных о пробках нет (не «ноль»: ноль значит «пробок
        /// нет», а это мы знаем только при свежем наборе).
        var trafficDelay: TimeInterval?
        /// Откуда `trafficDelay`: живые пробки, обычные для часа или обе.
        var trafficSource: TrafficForecast.Source?
        /// Часть `trafficDelay` от живых пробок (now.json); остальное — профиль
        /// «обычно». По ней подпись решает, «из-за пробок» это или «обычно в
        /// это время» (решение 28.10).
        var trafficLiveDelay: TimeInterval?
        /// Личный темп (33E) для класса дороги варианта: показанное время —
        /// время графа × темп + пробки (решение 28.10: одно время везде —
        /// крупная цифра, флажок, остаток, машина, «Поделиться прибытием»).
        /// 1 — без поправки. Выбор и ярлыки по нему не считаются.
        var paceFactor: Double = 1
        /// Где рисовать камеры маршрута — на его линии (CameraOnLine, 27.B).
        /// ТОЛЬКО для карты: оповещения и проезды читают `cameras` с
        /// настоящими координатами.
        var cameraSpots: [Int: CameraOnLine.Spot] = [:]
        /// Время графа вдоль линии по шагам OSRM; nil — движок длительностей
        /// не дал, остаток — долей расстояния.
        var timeline: RouteTimeline? = nil

        /// Время в пути с пробками — его и показываем, и сравниваем. У своей
        /// дороги (24.4) — по своим поездкам в этот час, если их хватает.
        var expectedTime: TimeInterval { assessment.myRoad?.seconds ?? travelTime + (trafficDelay ?? 0) }
        /// Время, которое видит водитель: `expectedTime` с личным темпом.
        /// Сравнения вариантов (выбор, «Быстрый», объезд) — по `expectedTime`;
        /// своя дорога уже по своим поездкам — темп к ней не прикладывается.
        var shownTime: TimeInterval {
            assessment.myRoad?.seconds ?? travelTime * paceFactor + (trafficDelay ?? 0)
        }
        /// Камеры, которые этот путь вправе назвать своими (29.E): доказанно
        /// встречные (27.J) на проспекте с разделительной лежат в коридоре,
        /// но снимают другую сторону — в плашке «📷 5» и в «Меньше камер»
        /// они раздували счёт пути по проспекту против пути переулками.
        var ourCameraCount: Int { cameras.reduce(0) { $0 + ($1.countsAsOurs ? 1 : 0) } }
        var etaText: String { Formatting.duration(shownTime) }
        var distanceText: String { Formatting.distance(distance) }
        /// Задержка пробками, которую показываем: у своей дороги со своим
        /// временем — только пробки сверх своего обычного (обычная пробка
        /// этого часа уже в нём), иначе — по пробкам на линии.
        var shownTrafficDelay: TimeInterval? {
            guard let mine = assessment.myRoad, mine.seconds != nil else {
                // «Обычно в этот час» без задержки — не утверждение «пробок
                // нет»: файл часа покрывает не каждую улицу (ни «без пробок»,
                // ни зелёного в машине).
                if trafficSource == .typical, (trafficDelay ?? 0) < 60 { return nil }
                return trafficDelay
            }
            return mine.jamSeconds
        }
        /// «+12 мин из-за пробок» / «без пробок»; nil — данных нет. У своей
        /// дороги «без пробок» не говорим: в её «обычно» пробки этого часа есть.
        var trafficNote: String? {
            guard let delay = shownTrafficDelay else { return nil }
            if delay < 60 {
                return assessment.myRoad?.seconds != nil ? nil : String(localized: "без пробок")
            }
            let text = Formatting.unbreakable(Formatting.duration(delay))
            // У своей дороги показана только пробка сверх своего обычного —
            // она живая по определению.
            guard assessment.myRoad?.seconds == nil else {
                return String(format: String(localized: "+%@ из-за пробок"), text)
            }
            switch TrafficForecast.cause(total: trafficDelay ?? delay, live: liveShare) {
            case .jams:
                return String(format: String(localized: "+%@ из-за пробок"), text)
            case .usual:
                return String(format: String(localized: "обычно +%@ в это время"), text)
            }
        }
        /// Живая часть задержки: у старых записей без разбивки — по источнику.
        private var liveShare: TimeInterval {
            if let trafficLiveDelay { return trafficLiveDelay }
            return trafficSource == .live ? (trafficDelay ?? 0) : 0
        }
    }

    nonisolated enum RouteError: Error {
        case noRoute          // оба движка не нашли путь между точками
        case serverUnreachable
        /// Запрос к OSRM не дошёл (таймаут, нет связи) — наружу уходит как
        /// `serverUnreachable`; отдельно — чтобы не повторять его без курса
        /// (`retriesWithoutHeading`).
        case noConnection
        /// Сервер маршрутов ответил сбоем (5xx, не JSON, чужой отказ) — не
        /// «нет связи» и не «пути нет».
        case serverFailed
    }

    /// Кумулятивная длина считается по ВЫБРАННОЙ линии: смена набора или
    /// выбора её сбрасывает (до 19.10 сверялось только число точек, и вариант
    /// с тем же числом точек брал чужие длины — ревью энергии).
    private(set) var variants: [Variant] = [] { didSet { selectedCumulative = [] } }
    private(set) var selectedID = 0 { didSet { selectedCumulative = [] } }
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
    /// Ход построения — одно состояние на телефон и машину (RouteBuildFlow).
    private(set) var buildFlow = RouteBuildFlow()
    /// Идёт расчёт. Ожидание GPS сюда не входит: прежний маршрут это время живёт.
    var isBuilding: Bool { buildFlow.isCalculating }
    @ObservationIgnored private var cancelBuildWork: (() -> Void)?
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
        /// Точка цели: маршрут к этому моменту уже снят, а поездке надо
        /// знать, стоим ли мы у цели (ArrivalFinish).
        var destination: ArrivalFinish.Point? = nil
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
    /// Файл «обычно» часа ИЗ ПАМЯТИ (TypicalTrafficService), без сети; nil —
    /// нет файла или пробки выключены. Ставит AppEnvironment. Прогноз
    /// (TrafficForecast) берёт его там, где живых пробок нет или они далеко.
    @ObservationIgnored var typicalTraffic: ((TypicalTraffic.Bucket) -> TrafficSnapshot?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: typicalTraffic,
                                               "RouteService.typicalTraffic") }
    }
    /// Попросить файлы часов, которых нет в памяти; пришли — AppEnvironment
    /// зовёт `typicalTrafficArrived`. Маршрут их не ждёт: OSRM быстрее сети.
    @ObservationIgnored var prefetchTypical: ((Set<TypicalTraffic.Bucket>) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: prefetchTypical,
                                               "RouteService.prefetchTypical") }
    }
    /// Типичные пробки по часу недели (33C, profile.json) из памяти; nil — нет
    /// файла, он старше 36 ч или пробки выключены. Есть — время вариантов и
    /// остатка считается во времени (TrafficTimeAhead), нет — прежний прогноз.
    @ObservationIgnored var trafficProfile: (() -> TrafficProfile?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: trafficProfile,
                                               "RouteService.trafficProfile") }
    }
    /// Попросить profile.json, если пора; пришёл — AppEnvironment зовёт
    /// `typicalTrafficArrived`. Маршрут его не ждёт.
    @ObservationIgnored var prefetchProfile: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: prefetchProfile,
                                               "RouteService.prefetchProfile") }
    }
    /// Личный темп (33E): во сколько раз своё время больше времени потока для
    /// класса дороги варианта; nil или 1 — без поправки. Ко всем показанным
    /// временам варианта (`Variant.paceFactor`, решение 28.10), не к выбору
    /// пути. Ставит AppEnvironment (PersonalPaceStore).
    @ObservationIgnored var paceFactor: ((PersonalPace.RoadClass) -> Double)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: paceFactor,
                                               "RouteService.paceFactor") }
    }
    /// Закрытый проезд по варианту — наблюдение личного темпа (на телефоне).
    @ObservationIgnored var onPaceSample: ((PersonalPace.Sample) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onPaceSample,
                                               "RouteService.onPaceSample") }
    }
    @ObservationIgnored private var paceTracker = PersonalPace.Tracker()
    /// Живые перекрытия и ремонт (12б.5) — для ярлыка «на пути перекрытие».
    /// Ставит AppEnvironment (MobileCameraService.roadEvents).
    @ObservationIgnored var roadEvents: (() -> [RoadEvent])? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: roadEvents,
                                               "RouteService.roadEvents") }
    }
    /// Задержка пробками на ОСТАВШЕЙСЯ части маршрута — пересчитывается не на
    /// каждом фиксе, а каждые `routeTrafficRecomputeMeters` и на новом наборе.
    private(set) var remainingTrafficDelay: TimeInterval = 0
    /// Обычная пробка часа на остатке пути (27.E) — только пока живых нет:
    /// идёт в прибытие (`remainingTime`), но НЕ в `engineRemaining` — объезд
    /// меряется живыми пробками, прогноз выдумывал бы выигрыш.
    private(set) var remainingTypicalDelay: TimeInterval = 0
    @ObservationIgnored private var trafficAlong: CLLocationDistance = -.infinity
    @ObservationIgnored private var trafficRevisionSeen = -1
    /// Пришли новые файлы «обычно» — остаток пересчитать на ближайшем фиксе.
    @ObservationIgnored private var typicalRevision = 0
    @ObservationIgnored private var typicalRevisionSeen = -1
    /// Профиль часа недели или файлы «обычно», пришедшие, пока маршрут
    /// собирался, — пересчитать время вариантов в конце сборки
    /// (TrafficArrivalGate, симуляция пробок 27.10).
    @ObservationIgnored private var trafficArrival = TrafficArrivalGate()
    /// Из чего выбирались ярлыки показанного набора (без пробок — они
    /// подставляются заново) — чтобы пересчитать их на поздних данных.
    @ObservationIgnored private var choiceBasis: (inputs: [RouteChoice.Input], history: RouteChoice.History?)?
    /// Касался ли водитель панели выбора с показа набора (решение 28.10).
    @ObservationIgnored private var choiceGate = ChoiceRelabelGate()
    /// Выбор открыт на экране машины (ставит CarPlay, 40I): новый набор,
    /// построенный в это время (на телефоне, к той же цели), замерзает сразу
    /// в `apply` — поздние пробки не должны успеть подвинуть его метки и
    /// выбор раньше, чем машина покажет карточку.
    @ObservationIgnored var choiceShownInCar = false
    /// Идёт ли поездка (LocationService) — ставит AppEnvironment. Набор,
    /// построенный в пути (новая цель из поиска), выбран сразу: поздние
    /// пробки не уводят машину на другой вариант.
    @ObservationIgnored var isTripActive: (() -> Bool)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: isTripActive,
                                               "RouteService.isTripActive") }
    }
    /// `apply` идёт: варианты ещё старые (или их нет), новые запишутся в конце.
    @ObservationIgnored private var isApplying = false

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
    /// Своя дорога к цели (24.4, MyRoad): план из профиля дороги дом↔работа,
    /// если цель — дом или работа и путь туда наезжен. nil — выключено
    /// («Учитывать мои поездки», «Время дороги на работу») или своей дороги нет.
    @ObservationIgnored var myRoadPlan: ((_ source: CLLocationCoordinate2D,
                                          _ destination: CLLocationCoordinate2D) -> MyRoad.Plan?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: myRoadPlan,
                                               "RouteService.myRoadPlan") }
    }
    /// План своей дороги, по которому построен её вариант (24.4): по нему
    /// перестроение ведёт через оставшиеся опорные точки. Действует, пока
    /// выбран вариант с ярлыком «Моя дорога».
    @ObservationIgnored private var myRoadInUse: MyRoad.Plan?
    /// Язык названий улиц в манёврах (`AppLanguage.mapCode`). Спрашиваем в
    /// момент построения: OSRM отдаёт имя узбекской латиницей, и в русской
    /// версии его надо переписать (см. StreetName). nil — как в русской.
    @ObservationIgnored var streetNameLanguage: (() -> String)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: streetNameLanguage,
                                               "RouteService.streetNameLanguage") }
    }
    /// Фраза манёвра и она же событием для записанного голоса (этап 16);
    /// событие nil — фраза с улицей, её говорит только синтезатор.
    @ObservationIgnored var onManeuver: ((String, VoiceEvent?) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onManeuver,
                                               "RouteService.onManeuver") }
    }
    /// Дороги своей сети вокруг точки — сколько полос на подъезде к манёвру
    /// (совет о ряде без полос OSRM, 20.2). nil — сети нет, края не будет.
    @ObservationIgnored var approachRoads: ((CLLocationCoordinate2D, CLLocationDistance) -> [RoadLine])? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: approachRoads,
                                               "RouteService.approachRoads") }
    }
    /// Слой полос (20.8) — ряды там, где OSRM молчит. nil — слоя нет: не
    /// скачан, не прошёл проверку, выключен пультом. Ставит AppEnvironment
    /// (LaneOverlayService); первый вызов поднимает слой с диска, и он
    /// приезжает позже — через `laneOverlayChanged`.
    @ObservationIgnored var laneOverlay: (() -> LaneOverlay?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: laneOverlay,
                                               "RouteService.laneOverlay") }
    }

    /// Тип впервые произнесённого манёвра — для суточного счётчика. Отдельно
    /// от `onManeuver`: тот несёт фразу и срабатывает до трёх раз на манёвр, а
    /// считать надо манёвры, а не повторы. Этот счётчик поймал бы «поверните
    /// направо» на прямой дороге за один день (plan_algorithms.md, А3).
    @ObservationIgnored var onManeuverSpoken: ((String) -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onManeuverSpoken,
                                               "RouteService.onManeuverSpoken") }
    }

    /// Когда перестраивать после съезда (RerouteGate, чистый).
    @ObservationIgnored private var rerouteGate = RerouteGate()
    /// Свой сервер маршрутов (OSRM) — через общий APIClient, как вся сеть.
    @ObservationIgnored private let osrm = APIClient(timeout: AppConfig.osrmTimeoutSeconds,
                                                     base: AppConfig.osrmBaseURL)
    /// Последний фикс — дальше `rerouteDeviationMeters` от линии: мы не на
    /// маршруте (съехали, перестроиться нельзя — нет сети). Остаток «по
    /// маршруту» до его камер тогда ничего не значит (сценарий S7).
    @ObservationIgnored private(set) var isOffRoute = false
    @ObservationIgnored private var isRebuilding = false
    /// Прогрессу по маршруту сейчас не верить: при построении `updateProgress`
    /// ждёт его конца, при перестроении ведёт по старой линии, с которой
    /// съехали. Остатку «по маршруту» до камер тогда верить нельзя
    /// (LocationGates.routeRemaining).
    var isProgressFrozen: Bool { isBuilding || isRebuilding }
    /// Идёт перестроение после съезда — наблюдаемо: машина на это время
    /// показывает «Перестраиваю маршрут» вместо уже неверного поворота.
    private(set) var isRerouting = false
    /// Поколение маршрута: растёт при build/clear. Фоновое перестроение (OSRM, до 12 с)
    /// сверяется с ним — иначе доехавший rebuild «воскрешал» бы сброшенный маршрут
    /// или перетирал свежепостроенный к новой цели.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var announcedStage: [Int: Int] = [:]   // индекс шага → стадия (2 далеко, 1 близко, 0 сейчас)
    /// Шаги, ряд которых уже назван: совет звучит один раз на манёвр.
    @ObservationIgnored private var laneAdviceSaid: Set<Int> = []
    /// Манёвры, к которым «затем» уже сказано (ManeuverThen).
    @ObservationIgnored private var thenSaid: Set<Int> = []
    /// Полос на подъезде по индексу шага (LaneAdvice.approachLanes) и когда
    /// спрашивали сеть, не найдя дороги: тайлы могли ещё не приехать.
    @ObservationIgnored private var approachLanesByStep: [Int: Int] = [:]
    @ObservationIgnored private var approachMissedAt: [Int: Date] = [:]
    @ObservationIgnored private var segmentHint = 0                    // ускоряет проекцию точки на маршрут
    /// Кумулятивная длина выбранного варианта (см. Self.cumulative).
    @ObservationIgnored private var selectedCumulative: [CLLocationDistance] = []

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
    /// Сколько камер маршрута — его (29.E): доказанно встречные лежат в
    /// коридоре, но число «камер на маршруте» обязано совпадать с плашкой.
    var ourCameraCount: Int { selected?.ourCameraCount ?? 0 }
    /// Точки камер маршрута на его линии — только для карты (27.B).
    var cameraSpotsOnRoute: [Int: CameraOnLine.Spot] { selected?.cameraSpots ?? [:] }
    var distanceText: String { selected?.distanceText ?? "" }
    var etaText: String { selected?.etaText ?? "" }
    var trafficNote: String? { selected?.trafficNote }
    var trafficDelay: TimeInterval? { selected?.shownTrafficDelay }

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
        guard selected != nil else { return 0 }
        // Маршрут по своей дороге на работу (8.8.11) — остаток по своим
        // прошлым поездкам (призрак): сами улучшаются прибытие в панели,
        // CarPlay и «Поделиться прибытием».
        if let personal = personalRemaining?() { return personal }
        // Последние 1–2 км — не оптимистичнее нашей средней скорости
        // (ArrivalTail): «0,7 км, прибытие сейчас» на 10 км/ч — снимок 63.
        guard let selected else { return 0 }
        return ArrivalTail.remaining(engine: Self.remainingEstimate(selected, remainingDistance: remainingDistance,
                                                                    liveDelay: remainingTrafficDelay,
                                                                    typicalDelay: remainingTypicalDelay),
                                     remainingMeters: remainingDistance,
                                     paceMps: pace.average(now: clock()))
    }

    // MARK: - Часы прибытия (ArrivalClock, 37)

    /// Прибытие на часах — ОДНО для всех выходов: панели, плашки, CarPlay,
    /// «Поделиться прибытием», близких, Siri. Ровно на минуте (ArrivalClock),
    /// пишется только при смене минуты: зрители не будятся каждые 30 с ради
    /// той же цифры. nil — маршрута нет.
    ///
    /// Хранимое, а не вычисляемое: `Date() + remainingTime` в body
    /// обновлялось только с перерисовкой, и стоя в пробке (фиксов нет)
    /// прибытие застывало, пока часы шли.
    private(set) var arrival: Date?

    /// Часы сервиса — подменяются в тестах (сквозной тест прибытия).
    @ObservationIgnored var clock: () -> Date = { Date() }

    /// Минута сменилась — для выходов, которые сами не наблюдают (плашка
    /// Live Activity, близкие): ставит AppEnvironment.
    @ObservationIgnored var onArrivalChanged: (() -> Void)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: onArrivalChanged,
                                               "RouteService.onArrivalChanged") }
    }

    /// Линия, для которой показана минута: на новой линии удерживать нечего.
    @ObservationIgnored private var arrivalLine: ObjectIdentifier?
    @ObservationIgnored private var arrivalTicker: Task<Void, Never>?

    /// Пересчитать прибытие: на каждом фиксе, на смене маршрута и пробок и
    /// по таймеру `arrivalClockTickSeconds`, пока маршрут есть.
    func refreshArrival() {
        let line = selected.map { ObjectIdentifier($0.polyline) }
        let raw = selected == nil ? nil : ArrivalClock.raw(now: clock(), remaining: remainingTime)
        let next = ArrivalClock.next(shown: arrival, raw: raw, sameRoute: line != nil && line == arrivalLine)
        arrivalLine = line
        if next == nil {
            arrivalTicker?.cancel()
            arrivalTicker = nil
        } else if arrivalTicker == nil {
            // Таймер — только пока маршрут есть; без GPS и сети, один
            // пересчёт остатка раз в полминуты (правило 8).
            arrivalTicker = Task { [weak self] in
                while !Task.isCancelled {
                    await Task.pause(seconds: AppConfig.arrivalClockTickSeconds)
                    guard !Task.isCancelled, let self else { return }
                    self.refreshArrival()
                }
            }
        }
        guard next != arrival else { return }
        arrival = next
        onArrivalChanged?()
    }

    /// «15:56» — прибытие одним форматом на всех экранах (Formatting.clock).
    var arrivalText: String {
        arrival.map(Formatting.clock) ?? "—"
    }

    /// Остаток до показанной минуты — для машины (CarPlay прибавляет его к
    /// своим часам) и для времени до манёвра.
    func arrivalSeconds(now: Date = Date()) -> TimeInterval {
        arrival.map { ArrivalClock.secondsUntil($0, now: now) } ?? 0
    }

    /// Остаток по маршруту до хвоста последних километров: доля времени графа
    /// (по шагам OSRM — RouteTimeline, без них — по расстоянию) с личным
    /// темпом варианта (33E) + пробки остатка. На старте (весь путь,
    /// задержки из `initialRemainingDelays`) — ровно `Variant.shownTime`:
    /// флажок прибытия и крупная цифра — одно время (решение 28.10). Мерка
    /// объезда (`engineRemaining`) темпа не знает.
    static func remainingEstimate(_ variant: Variant, remainingDistance: CLLocationDistance,
                                  liveDelay: TimeInterval, typicalDelay: TimeInterval) -> TimeInterval {
        guard variant.distance > 0 else { return 0 }
        return graphRemaining(variant, remainingDistance: remainingDistance) * variant.paceFactor
            + liveDelay + typicalDelay
    }

    /// Время графа на остатке пути, без темпа и пробок.
    static func graphRemaining(_ variant: Variant, remainingDistance: CLLocationDistance) -> TimeInterval {
        variant.travelTime * RouteTimeline.remainingShare(variant.timeline, distance: variant.distance,
                                                          remainingDistance: remainingDistance)
    }

    /// Закрыть наблюдение личного темпа (прибытие, снятие маршрута).
    private func closePaceSample() {
        if let sample = paceTracker.finish() { onPaceSample?(sample) }
    }

    /// Средняя скорость за последние ~2 минуты — для прибытия на последних
    /// километрах. Не наблюдается: остаток пересчитывается на каждом фиксе и
    /// так (прогресс), а лишняя запись в каждый тик будила бы всех зрителей.
    @ObservationIgnored private var pace = ArrivalTail.Pace()

    /// Отметить скорость фикса (каждый фикс, и стоя: стоянка у светофора —
    /// часть средней). Без маршрута не копим.
    func notePace(speedKmh: Double, at time: Date = Date()) {
        guard isActive else {
            if !pace.samples.isEmpty { pace.reset() }
            return
        }
        pace.add(speedKmh: speedKmh, at: time)
    }

    /// Остаток по оценке самого маршрута (движок + пробки) — для сравнения с
    /// другими вариантами (объезд): личное «обычно в этот час» нельзя мерить
    /// против времени OSRM — в час пик это выдумало бы выгодный объезд.
    var engineRemaining: TimeInterval {
        guard let selected, selected.distance > 0 else { return 0 }
        return Self.graphRemaining(selected, remainingDistance: remainingDistance) + remainingTrafficDelay
    }

    /// Личный остаток пути (8.8.11), подаёт AppEnvironment из призрака дороги
    /// на работу; nil — маршрут считает сам (линейная доля + пробки).
    @ObservationIgnored var personalRemaining: (() -> TimeInterval?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: personalRemaining,
                                               "RouteService.personalRemaining") }
    }

    /// Пересчитать задержку пробками на остатке пути: на новом наборе пробок
    /// (`revision`) или когда проехали `routeTrafficRecomputeMeters`.
    func refreshTrafficDelay(revision: Int, now: Date = Date()) {
        guard let selected else {
            if remainingTrafficDelay != 0 { remainingTrafficDelay = 0 }
            if remainingTypicalDelay != 0 { remainingTypicalDelay = 0 }
            return
        }
        defer { refreshArrival() }
        guard revision != trafficRevisionSeen || typicalRevision != typicalRevisionSeen
                || abs(progressAlong - trafficAlong) >= AppConfig.routeTrafficRecomputeMeters else { return }
        trafficRevisionSeen = revision
        typicalRevisionSeen = typicalRevision
        trafficAlong = progressAlong
        let remaining = Self.remaining(selected.points, after: progressAlong)
        var live: TimeInterval = 0, typical: TimeInterval = 0
        let snapshot = trafficSnapshot?()
        if let profile = trafficProfile?(), selected.distance > 0 {
            // 33C: остаток во времени — живое на ближние 15 минут пути,
            // дальше типичная часа недели прибытия. Мерка объезда
            // (engineRemaining) — по-прежнему только живые, разница идёт в
            // прибытие поправкой (может быть и отрицательной: пробка в
            // получасе впереди к нашему приезду обычно уже рассосётся).
            live = snapshot?.delay(along: remaining) ?? 0
            let baseTime = Self.graphRemaining(selected, remainingDistance: remainingDistance)
            let ahead = TrafficTimeAhead.delay(along: remaining, baseTime: baseTime, departure: now, now: now,
                                               live: snapshot, profile: profile)?.seconds ?? live
            typical = ahead - live
        } else if let snapshot {
            live = snapshot.delay(along: remaining)
        } else if selected.distance > 0 {
            // Живых нет (сборщик стоит, now.json старый) — обычная пробка
            // часа по остатку пути, с выездом «сейчас».
            let baseTime = Self.graphRemaining(selected, remainingDistance: remainingDistance)
            let needed = TrafficForecast.buckets(departure: now, travelTime: baseTime)
            let files = typicalFiles(needed)
            if files.count < needed.count { prefetchTypical?(needed) }
            typical = TrafficForecast.delay(along: remaining, baseTime: baseTime, departure: now, now: now,
                                            live: nil, typical: { files[$0] })?.seconds ?? 0
        }
        if abs(live - remainingTrafficDelay) >= 1 { remainingTrafficDelay = live }
        if abs(typical - remainingTypicalDelay) >= 1 { remainingTypicalDelay = typical }
    }

    /// Файлы «обычно» этих часов, которые уже в памяти.
    private func typicalFiles(_ buckets: Set<TypicalTraffic.Bucket>) -> [TypicalTraffic.Bucket: TrafficSnapshot] {
        guard let typicalTraffic else { return [:] }
        var out: [TypicalTraffic.Bucket: TrafficSnapshot] = [:]
        for bucket in buckets {
            if let file = typicalTraffic(bucket) { out[bucket] = file }
        }
        return out
    }

    /// Пришли файлы «обычно» (27.E) или профиль часа недели (33C): время
    /// вариантов пересчитать, а остаток пути — на ближайшем фиксе. Ярлыки
    /// выбора — только пока водитель не коснулся панели (ChoiceRelabelGate,
    /// решение 28.10): после касания «Быстрый» под пальцем не перескакивает.
    func typicalTrafficArrived(now: Date = Date()) {
        typicalRevision &+= 1
        // Пришло во время сборки — варианты сейчас старые или пустые, пересчёт
        // по ним пропал бы (линии сменятся), а новых он бы не увидел: профиль
        // просит сама сборка (`prefetchProfile`), и первый маршрут после
        // запуска показывал время без него (24 мин, в пути — 33).
        guard trafficArrival.arrived(whileBuilding: isBuilding || isRebuilding || isApplying) else { return }
        recomputeVariantTraffic(now: now)
    }

    /// Пришёл новый now.json, пока варианты ещё выбирают (до «Поехали»):
    /// время вариантов — по нему, ярлыки — до касания панели (решение 28.10).
    /// В пути остаток ведёт `refreshTrafficDelay`, варианты не трогаем.
    func liveTrafficArrived(now: Date = Date()) {
        guard isActive, progressAlong == 0 else { return }
        guard trafficArrival.arrived(whileBuilding: isBuilding || isRebuilding || isApplying) else { return }
        recomputeVariantTraffic(now: now)
    }

    /// Время вариантов по пробкам, которые есть в памяти сейчас (живые,
    /// профиль часа недели, файлы «обычно»).
    private func recomputeVariantTraffic(now: Date) {
        guard !variants.isEmpty else { return }
        let live = trafficSnapshot?()
        let profile = trafficProfile?()
        let needed = TrafficForecast.buckets(departure: now, travelTime: variants.map(\.travelTime).max() ?? 0)
        let files = typicalFiles(needed)
        guard live != nil || !files.isEmpty || profile != nil else { return }
        let lines = variants.map { $0.polyline }
        let inputs = variants.map { (points: $0.points, travelTime: $0.travelTime) }
        // Ярлыки — заново, только пока водитель не касался выбора: база
        // выбора та же, время — с новыми пробками, перекрытия — текущие.
        let basis = choiceGate.touched || variants.count < 2 ? nil : choiceBasis
        let events = roadEvents?() ?? []
        Task {
            let (forecasts, verdict) = await offMain { () -> ([TrafficForecast.Delay?], RouteChoice.Verdict?) in
                let forecasts = inputs.map { input in
                    Self.variantDelay(points: input.points.map(\.coordinate), travelTime: input.travelTime, now: now,
                                      live: live, profile: profile, typical: files)
                }
                guard let basis, basis.inputs.count == inputs.count else { return (forecasts, nil) }
                let relabeled = basis.inputs.indices.map { index in
                    let base = basis.inputs[index]
                    return RouteChoice.Input(path: base.path, distance: base.distance,
                                             travelTime: inputs[index].travelTime + (forecasts[index]?.seconds ?? 0),
                                             cameraIDs: base.cameraIDs, hardManeuvers: base.hardManeuvers,
                                             closures: RoadEventRules.closures(on: base.path, events: events, now: now),
                                             personal: base.personal)
                }
                return (forecasts, RouteChoice.decide(relabeled, history: basis.history))
            }
            // Пока считали, маршрут могли перестроить или снять.
            guard variants.count == lines.count,
                  zip(variants, lines).allSatisfy({ $0.polyline === $1 }) else { return }
            for index in variants.indices {
                let forecast = forecasts[index]
                guard forecast?.seconds != variants[index].trafficDelay
                        || forecast?.source != variants[index].trafficSource
                        || forecast?.liveSeconds != variants[index].trafficLiveDelay else { continue }
                variants[index].trafficDelay = forecast?.seconds
                variants[index].trafficSource = forecast?.source
                variants[index].trafficLiveDelay = forecast?.liveSeconds
            }
            // Касание могло случиться, пока считали, — проверяем снова.
            if let verdict, let fresh = choiceGate.relabel(verdict, variantCount: variants.count) {
                for index in variants.indices where variants[index].assessment != fresh.assessments[index] {
                    variants[index].assessment = fresh.assessments[index]
                }
                if fresh.selected != selectedID {
                    Log.route.notice("варианты: ярлыки по поздним пробкам, выбран \(fresh.selected, privacy: .public)")
                    selectedID = fresh.selected
                    resetProgress()
                }
            }
            // Ещё не тронулись — прибытие с новым временем варианта сразу, а не
            // с ближайшим фиксом (у стоящего телефона его может не быть минутами).
            if progressAlong == 0, let selected {
                let initial = Self.initialRemainingDelays(selected.trafficDelay, source: selected.trafficSource)
                remainingTrafficDelay = initial.live
                remainingTypicalDelay = initial.typical
            }
            refreshArrival()
        }
    }

    /// Задержка пробками варианта: во времени по профилю часа недели (33C),
    /// когда он есть, иначе прежний прогноз по живым и файлам «обычно» (27.E).
    nonisolated static func variantDelay(points: [CLLocationCoordinate2D], travelTime: TimeInterval, now: Date,
                                         live: TrafficSnapshot?, profile: TrafficProfile?,
                                         typical: [TypicalTraffic.Bucket: TrafficSnapshot]) -> TrafficForecast.Delay? {
        if profile != nil, let ahead = TrafficTimeAhead.delay(along: points, baseTime: travelTime, departure: now,
                                                              now: now, live: live, profile: profile) {
            return TrafficForecast.claimable(ahead)
        }
        return TrafficForecast.claimable(TrafficForecast.delay(along: points, baseTime: travelTime, departure: now,
                                                               now: now, live: live, typical: { typical[$0] }))
    }

    /// Остаток задержки сразу после выбора варианта, до первого фикса:
    /// (живые — мерка объезда, остальное — только прибытие). Смешанное время
    /// (33C: живые на ближние 15 мин + профиль часа недели — обычный случай)
    /// целиком идёт в прибытие: до 27.10 оно обнулялось до ближайшего фикса, а
    /// у стоящего телефона его нет минутами — «34 мин», а прибытие по графу
    /// через 24 (симуляция пробок). Объезд до фикса мерится без него — с
    /// осторожной стороны: выдуманного выигрыша нет.
    nonisolated static func initialRemainingDelays(_ delay: TimeInterval?, source: TrafficForecast.Source?)
        -> (live: TimeInterval, typical: TimeInterval) {
        let total = delay ?? 0
        switch source {
        case .live?: return (total, 0)
        case .typical?, .mixed?: return (0, total)
        case nil: return (0, 0)
        }
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

    /// Путь впереди от машины до `meters` (для проб лимита): от текущей
    /// точки по линии маршрута. nil — маршрута нет.
    func pathAhead(from coordinate: CLLocationCoordinate2D, meters: CLLocationDistance) -> [CLLocationCoordinate2D]? {
        guard let selected else { return nil }
        if selectedCumulative.count != selected.points.count {
            selectedCumulative = Self.cumulative(of: selected.points)
        }
        return Self.ahead(selected.points, cumulative: selectedCumulative, after: progressAlong,
                          from: coordinate, meters: meters)
    }

    /// Путь от `coordinate` вперёд по линии на `meters`: точка начала —
    /// двоичным поиском по кумулятивной длине, дальше только нужный кусок.
    /// До 19.10 весь хвост маршрута проходился от старта и копировался в
    /// массив координат на каждом GPS-тике (аудит энергии), хотя нужны были
    /// первые ~600 м.
    nonisolated static func ahead(_ points: [MKMapPoint], cumulative: [CLLocationDistance],
                                  after along: CLLocationDistance, from coordinate: CLLocationCoordinate2D,
                                  meters: CLLocationDistance) -> [CLLocationCoordinate2D]? {
        guard points.count >= 2, cumulative.count == points.count else { return nil }
        // Первый индекс, где пройденное ≥ along; сегмент, в котором машина, — с предыдущей точки.
        var low = 0, high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] >= along { high = mid } else { low = mid + 1 }
        }
        guard cumulative[low] >= along else { return nil }
        let start = max(1, low)
        var path = [coordinate]
        var total: CLLocationDistance = 0
        for i in start..<points.count {
            let point = points[i].coordinate
            if let last = path.last {
                total += GeoMath.fastDistance(last.latitude, last.longitude, point.latitude, point.longitude)
            }
            path.append(point)
            if total >= meters { break }
        }
        return path.count >= 2 ? path : nil
    }

    // MARK: - Построение

    /// Касание «построить»: отклик сразу, ещё до GPS и сети. nil — к этой цели
    /// уже строится, второе касание ничего не запускает.
    @discardableResult
    func beginBuild(to coordinate: CLLocationCoordinate2D, name: String,
                    purpose: RouteBuildFlow.Target.Purpose = .route) -> Int? {
        let target = RouteBuildFlow.Target(name: name, latitude: coordinate.latitude,
                                           longitude: coordinate.longitude, purpose: purpose)
        let attempt: Int
        switch buildFlow.begin(target) {
        case .duplicate:
            Log.route.notice("построение: повторное касание той же цели — пропускаю")
            return nil
        case .replaced(let next):
            Log.route.notice("построение: цель сменили — прежняя попытка не нужна")
            cancelBuildWork?()
            cancelBuildWork = nil
            attempt = next
        case .started(let next):
            attempt = next
        }
        errorMessage = nil
        Task { [weak self] in
            await Task.pause(seconds: AppConfig.routeBuildSlowSeconds)
            self?.buildFlow.markSlow(attempt)
        }
        return attempt
    }

    /// «Отмена» под индикатором: прежний маршрут, если он был, остаётся.
    func cancelBuild() {
        guard let stage = buildFlow.cancel() else { return }
        cancelBuildWork?()
        cancelBuildWork = nil
        // Ждали только GPS — считать было нечего, чужие расчёты не трогаем.
        if stage >= .calculating { generation += 1 }
        Log.route.notice("построение: отменено")
    }

    /// Закрыли сообщение об ошибке — маршрут при этом не трогаем.
    func dismissBuildFailure() {
        guard case .failed = buildFlow.state else { return }
        buildFlow.dismissFailure()
        errorMessage = nil
    }

    /// false — попытка уже не текущая, и её ошибка никому не нужна.
    @discardableResult
    private func failBuild(_ attempt: Int, _ failure: RouteBuildFlow.Failure, message: String) -> Bool {
        guard buildFlow.fail(attempt, failure) else { return false }
        errorMessage = message
        return true
    }

    /// Попытку заменили или отменили: что сказать тому, кто её начал.
    private var abandonedOutcome: RouteBuildFlow.Outcome { buildFlow.isWorking ? .superseded : .cancelled }

    /// Живой точки нет — маршрут не строим вовсе, и говорим об этом:
    /// молчаливое «ничего не произошло» после тапа читается как поломка кнопки.
    func reportNoFix(attempt: Int) {
        failBuild(attempt, .noFix, message: String(localized: "Не видим вашего положения — маршрут не построен"))
    }

    /// Убрать заезд не вышло без положения — маршрут при этом остаётся.
    func reportNoFixForStop(attempt: Int) {
        failBuild(attempt, .stopUnchanged, message: String(localized: "Не видим вашего положения — заезд остался"))
    }

    /// `heading` — курс машины, если она едет (`LocationService.routeHeading`,
    /// правило — `requestHeading`): маршрут начнётся туда, куда она едет, а не
    /// с разворота за спиной (20.9). Стоя — nil: поехать можно в любую сторону.
    ///
    /// `attempt` — номер из `beginBuild`, если кнопка уже ответила касанием;
    /// nil — попытка начнётся здесь (Siri, плитка главного экрана).
    @discardableResult
    func build(from source: CLLocationCoordinate2D,
               heading: CLLocationDirection?,
               to destination: CLLocationCoordinate2D,
               name: String, cameras: [Camera],
               alternatives: Bool = true,
               attempt given: Int? = nil) async -> RouteBuildFlow.Outcome {
        let attempt: Int
        if let given {
            guard buildFlow.isCurrent(given) else { return abandonedOutcome }
            attempt = given
        } else {
            guard let started = beginBuild(to: destination, name: name) else { return .duplicate }
            attempt = started
        }
        defer { buildFlow.finish(attempt) }
        // Пульт: если наш OSRM лежит, честное «временно недоступны» лучше, чем
        // спиннер на 20 секунд и «Маршрут не найден» — последнее водитель
        // прочитает как «дороги нет», а не как «сервер чинят».
        guard isRoutingEnabled else {
            failBuild(attempt, .unavailable, message: String(localized: "Маршруты временно недоступны — мы уже чиним"))
            return .failed
        }
        buildFlow.advance(attempt, to: .calculating)
        errorMessage = nil
        generation += 1
        let gen = generation
        resetDetour()

        lastArrival = nil   // новый маршрут — карточка прошлого прибытия неактуальна
        // Профиль часа недели (33C) — параллельно с запросом OSRM, а не после
        // него: успеет — ярлыки («Быстрый») и время вариантов посчитаны по нему
        // сразу; не успеет — время досчитает конец сборки (TrafficArrivalGate).
        prefetchProfile?()
        // Своя дорога (24.4) — только при выборе из вариантов: запрос через
        // её опорные точки идёт рядом с обычным, а не после него.
        let plan = alternatives ? myRoadPlan?(source, destination) : nil
        // Отдельной задачей: «Отмена» обрывает запросы, а не ждёт их таймаута.
        let work = Task { () throws -> ([BuiltVariant], BuiltVariant?) in
            async let engine = calculate(from: source, via: nil, to: destination,
                                         alternatives: alternatives, heading: heading)
            async let ownRoute = myRoadRoute(plan, from: source, to: destination, heading: heading)
            let built = try await engine
            return (built, await ownRoute)
        }
        cancelBuildWork = { work.cancel() }
        do {
            let (built, mine) = try await work.value
            guard buildFlow.isCurrent(attempt), gen == generation else { return abandonedOutcome }   // пока считали — маршрут сбросили/заменили
            buildFlow.advance(attempt, to: .comparing)
            let merged = await offMain { Self.merge(built, mine: mine, plan: plan) }
            guard buildFlow.isCurrent(attempt), gen == generation else { return abandonedOutcome }
            // Новая цель — остановка прежнего маршрута не её. Забываем ТОЛЬКО
            // после успеха: не построилось — прежняя линия (через остановку)
            // остаётся, и перестроение по ней обязано помнить заезд.
            stop = nil
            myRoadInUse = merged.index == nil ? nil : plan
            await apply(merged.variants, name: name, destination: destination,
                        cameras: cameras, gen: gen, history: personalHistory?(),
                        myRoad: merged.index.flatMap { index in plan.map { (index, $0) } })
            return buildFlow.isCurrent(attempt) && gen == generation ? .built : abandonedOutcome
        } catch RouteError.serverUnreachable {
            let shown = failBuild(attempt, .network,
                                  message: String(localized: "Нет связи с сервером маршрутов — проверьте интернет"))
            return shown ? .failed : abandonedOutcome
        } catch RouteError.serverFailed {
            let shown = failBuild(attempt, .unavailable,
                                  message: String(localized: "Маршруты временно недоступны — мы уже чиним"))
            return shown ? .failed : abandonedOutcome
        } catch {
            let shown = failBuild(attempt, .noRoute, message: String(localized: "Маршрут не найден"))
            return shown ? .failed : abandonedOutcome
        }
    }

    /// Заехать по пути: та же цель, маршрут через `coordinate`.
    ///
    /// Без альтернатив и только своим OSRM: MKDirections промежуточных точек
    /// не знает, а сравнивать варианты заезда незачем — точку человек уже
    /// выбрал сам. Не вышло — старый маршрут остаётся как был, с сообщением.
    func addStop(_ coordinate: CLLocationCoordinate2D, name: String,
                 from source: CLLocationCoordinate2D, heading: CLLocationDirection?,
                 cameras: [Camera], attempt given: Int? = nil) async {
        guard let attempt = stopAttempt(given, to: coordinate, name: name, purpose: .addStop) else { return }
        defer { buildFlow.finish(attempt) }
        guard isActive, let destination = destinationCoordinate else {
            // Маршрут успел закончиться (приехали, сбросили), пока выбирали место.
            failBuild(attempt, .stopUnchanged, message: String(localized: "Маршрута уже нет — заезд не добавлен"))
            return
        }
        guard isRoutingEnabled else {
            failBuild(attempt, .unavailable, message: String(localized: "Маршруты временно недоступны — мы уже чиним"))
            return
        }
        buildFlow.advance(attempt, to: .calculating)
        generation += 1
        let gen = generation
        let destinationName = self.destinationName
        let newStop = Stop(coordinate: coordinate, name: name)
        do {
            let built = try await calculate(from: source, via: newStop, to: destination,
                                            alternatives: false, heading: heading)
            guard buildFlow.isCurrent(attempt), gen == generation else { return }
            buildFlow.advance(attempt, to: .comparing)
            stop = newStop
            await apply(built, name: destinationName, destination: destination,
                        cameras: cameras, gen: gen, history: nil)
        } catch RouteError.serverUnreachable {
            failBuild(attempt, .stopUnchanged, message: String(localized: "Нет связи с сервером маршрутов — проверьте интернет"))
        } catch {
            failBuild(attempt, .stopUnchanged, message: String(localized: "Не удалось заехать по пути — маршрут прежний"))
        }
    }

    /// Убрать заезд, оставив цель (5.13): раньше передумавший заезжать на
    /// АЗС сбрасывал весь маршрут и искал адрес заново. Не вышло — заезд и
    /// линия остаются, как были, с сообщением.
    func removeStop(from source: CLLocationCoordinate2D, heading: CLLocationDirection?,
                    cameras: [Camera], attempt given: Int? = nil) async {
        guard let current = stop, isActive, let destination = destinationCoordinate else {
            if let given { buildFlow.finish(given) }
            return
        }
        guard let attempt = stopAttempt(given, to: current.coordinate, name: current.name, purpose: .removeStop)
        else { return }
        defer { buildFlow.finish(attempt) }
        guard isRoutingEnabled else {
            failBuild(attempt, .unavailable, message: String(localized: "Маршруты временно недоступны — мы уже чиним"))
            return
        }
        buildFlow.advance(attempt, to: .calculating)
        generation += 1
        let gen = generation
        let destinationName = self.destinationName
        do {
            let built = try await calculate(from: source, via: nil, to: destination,
                                            alternatives: false, heading: heading)
            guard buildFlow.isCurrent(attempt), gen == generation else { return }
            buildFlow.advance(attempt, to: .comparing)
            stop = nil
            await apply(built, name: destinationName, destination: destination,
                        cameras: cameras, gen: gen, history: nil)
        } catch RouteError.serverUnreachable {
            failBuild(attempt, .stopUnchanged, message: String(localized: "Нет связи с сервером маршрутов — проверьте интернет"))
        } catch {
            failBuild(attempt, .stopUnchanged, message: String(localized: "Не удалось убрать заезд — маршрут прежний"))
        }
    }

    /// Попытка заезда: начатая кнопкой или новая; nil — уже идёт такая же.
    private func stopAttempt(_ given: Int?, to coordinate: CLLocationCoordinate2D, name: String,
                             purpose: RouteBuildFlow.Target.Purpose) -> Int? {
        if let given { return buildFlow.isCurrent(given) ? given : nil }
        return beginBuild(to: coordinate, name: name, purpose: purpose)
    }

    func selectVariant(_ id: Int) {
        // Выбор водителя — даже того же варианта: ярлыки больше не двигаются.
        choiceGate.touch()
        guard id != selectedID, variants.contains(where: { $0.id == id }) else { return }
        selectedID = id
        resetProgress()
    }

    /// Водитель коснулся панели выбора (жест по карточкам) или поехал:
    /// ярлыки вариантов замерзают до следующего набора (ChoiceRelabelGate).
    func noteChoiceTouched() {
        if !choiceGate.touched { choiceGate.touch() }
    }

    func clear() {
        closePaceSample()
        choiceBasis = nil
        generation += 1   // rebuild в полёте не должен вернуть линию на карту
        buildFlow.reset()
        cancelBuildWork?()
        cancelBuildWork = nil
        resetDetour()
        variants = []
        selectedID = 0
        destinationName = ""
        destinationCoordinate = nil
        stop = nil
        myRoadInUse = nil
        errorMessage = nil
        selectedCumulative = []
        rerouteGate.reset()
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
        closePaceSample()
        lastArrival = ArrivalSummary(name: destinationName, at: Date(),
                                     destination: destinationCoordinate.map {
                                         ArrivalFinish.Point(lat: $0.latitude, lon: $0.longitude)
                                     })
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
        rerouteGate.resetTicks()
        isOffRoute = false
        announcedStage = [:]
        laneAdviceSaid = []
        thenSaid = []
        approachLanesByStep = [:]
        approachMissedAt = [:]
        segmentHint = 0
        // Задержка пробками — с варианта (посчитана при построении); дальше
        // её ведёт refreshTrafficDelay по ходу и по новым наборам. Живые и
        // обычные врозь (объезд меряется только живыми); смешанное время
        // варианта разложит ближайший фикс — пересчёт сразу, не через 300 м.
        let initial = Self.initialRemainingDelays(selected?.trafficDelay, source: selected?.trafficSource)
        remainingTrafficDelay = initial.live
        remainingTypicalDelay = initial.typical
        trafficRevisionSeen = -1
        typicalRevisionSeen = -1
        trafficAlong = 0
        refreshArrival()
    }

    // MARK: - Прогресс: прибытие, следующая камера, манёвры, перестроение

    /// Вызывается на каждой GPS-точке. `announce` — озвучивать ли манёвры (в поездке).
    /// `course` — курс, которому МОЖНО верить (его выдаёт LocationFilter);
    /// `-1` означает «курса нет», и тогда он в выборе положения не участвует.
    /// `speedKmh` — когда назвать ряд (LaneAdvice.adviceDistance);
    /// `cameraHolds` — камера впереди держит голос, ранний ряд ждёт её.
    func updateProgress(coordinate: CLLocationCoordinate2D, cameras: [Camera], announce: Bool,
                        course: CLLocationDirection = -1, speedKmh: Double = 0,
                        cameraHolds: Bool = false, accuracy: CLLocationAccuracy? = nil) {
        // Прибытие — на каждом фиксе, на любом выходе отсюда (и после
        // прибытия: маршрут снят — часов нет).
        defer { refreshArrival() }
        // Перестроение — не повод замирать: до прихода новой линии ведём по
        // старой (76), без второго перестроения поверх первого.
        guard let variant = selected, !isBuilding,
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
                                              allowFullScan: rerouteGate.offRouteTicks % 3 == 0,
                                              course: course)
        progressAlong = along
        // Личный темп (33E): проезд по варианту копится, смена варианта
        // (перестроение) закрывает прежний.
        // Ключ — сама линия варианта: номера вариантов (0, 1, 2) повторяются
        // от построения к построению.
        if let sample = paceTracker.note(.init(id: ObjectIdentifier(variant.polyline).hashValue,
                                               distance: variant.distance,
                                               travelTime: variant.travelTime, trafficDelay: variant.trafficDelay),
                                         along: along, at: Date()) {
            onPaceSample?(sample)
        }
        displaySnap = Self.displaySnap(
            deviation: deviation,
            on: deviation <= AppConfig.routeSnapMeters
                ? Self.pointAndCourse(along: along, pts: variant.points, cum: selectedCumulative) : nil,
            course: course)

        // Прибытие: у самой цели и по линии осталось мало ИЛИ проехали финиш по
        // маршруту (ArrivalReached).
        let destinationDistance = point.distance(to: MKMapPoint(destination))
        if ArrivalReached.isReached(destinationDistance: destinationDistance,
                                    remainingAlong: variant.distance - along, deviation: deviation) {
            arrive()
            return
        }

        // Остановка по пути пройдена — дальше перестроение ведёт прямо к цели.
        if let current = stop,
           point.distance(to: MKMapPoint(current.coordinate)) <= AppConfig.routeStopReachedMeters
            || variant.stopAlong.map({ along > $0 + AppConfig.routeStopPassedMeters }) == true {
            stop = nil
        }

        // Следующая камера впереди по маршруту. Доказанно встречная — не
        // «следующая наша» (27.J).
        if let cam = variant.cameras.first(where: {
            $0.countsAsOurs && $0.distanceAlong > along - AppConfig.routeCameraBehindSlackMeters
        }) {
            nextCamera = cam
            nextCameraDistance = max(0, cam.distanceAlong - along)
        } else {
            nextCamera = nil
        }

        updateManeuvers(variant: variant, along: along,
                        announce: announce && Self.voicesOldLine(rebuilding: isRebuilding, deviation: deviation),
                        speedKmh: speedKmh, cameraHolds: cameraHolds)

        // Отклонение → перестроение (с защитой от шума GPS и кулдауном).
        // Пульт выключил маршруты (OSRM лёг) — не перестраиваем: каждая
        // попытка шла в Apple и OSRM, пока владелец гасил именно это (S24).
        // Подтверждение шумом, кулдаун и бэкофф — RerouteGate. Маршрут без
        // сети приблизителен на длину своих прямых подъездов — и съездом
        // считается только уход дальше их (isOffRoute ниже остаётся по 150 м:
        // остатку до камер дальше линии всё равно не верим).
        // Ход навстречу линии (20.9) — по ветке, которую выбрала проекция
        // (`segmentHint` после project — её сегмент): на обратной ветке
        // маршрута-петли курс попутен, и правило молчит.
        guard !isRebuilding else {
            isOffRoute = deviation > AppConfig.rerouteDeviationMeters || rerouteGate.isWrongWay
            return
        }
        let rerouteLimit = variant.isOffline ? AppConfig.offlineRouteRerouteMeters
                                             : AppConfig.rerouteDeviationMeters
        let rebuild = rerouteGate.note(
            deviation: deviation, now: Date(), limit: rerouteLimit,
            drift: variant.isOffline ? nil : RerouteGate.driftLimit(accuracy: accuracy),
            heading: variant.isOffline ? nil : Self.routeHeading(along: along, segment: segmentHint,
                                                                 pts: variant.points,
                                                                 course: course, speedKmh: speedKmh))
        // Едем навстречу линии — остаток «по маршруту» до камер значит не
        // больше, чем после съезда: камеры за спиной заслоняли бы настоящую
        // впереди (S7). Пока перестраиваемся, его и так не берут.
        isOffRoute = deviation > AppConfig.rerouteDeviationMeters || rerouteGate.isWrongWay
        guard rebuild, isRoutingEnabled else { return }

        isRebuilding = true
        isRerouting = true
        let name = destinationName
        let gen = generation
        let via = stop   // ещё не заехали — объезд всё равно через остановку
        // Ехали своей дорогой — и перестраиваемся ею (24.4).
        let ownPlan = via == nil && variant.assessment.myRoad != nil
            ? myRoadInUse.flatMap { MyRoad.remaining($0, from: coordinate, course: course) } : nil
        Task {
            defer {
                isRebuilding = false
                isRerouting = false
            }
            // Перестраиваем без альтернатив — быстрее, и в движении выбор не нужен.
            let built: [BuiltVariant]
            let heading = course >= 0 ? course : nil
            let own = await rerouteMyRoad(ownPlan, from: coordinate, to: destination, heading: heading)
            do {
                // Курс — чтобы новый маршрут шёл туда, куда машина едет, а не
                // начинался с разворота за спиной (см. rerouteBearingRangeDegrees).
                if let own {
                    built = [own]
                } else {
                    built = try await calculate(from: coordinate, via: via, to: destination, alternatives: false,
                                                heading: heading)
                }
            } catch {
                rerouteGate.noteFailure()
                Log.route.error("перестроение маршрута не удалось (\(self.rerouteGate.failures, privacy: .public)-й раз): \(error.localizedDescription, privacy: .public) — остаёмся на старой линии")
                return
            }
            guard gen == generation else { return }   // маршрут успели сбросить/заменить
            rerouteGate.noteSuccess()
            myRoadInUse = own == nil ? nil : ownPlan
            await apply(built, name: name, destination: destination,
                        cameras: cameras, gen: gen, history: nil,
                        myRoad: own == nil ? nil : ownPlan.map { (0, $0) })
            onRerouted?()
        }
    }

    private func updateManeuvers(variant: Variant, along: CLLocationDistance, announce: Bool,
                                 speedKmh: Double = 0, cameraHolds: Bool = false) {
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
        var step = variant.steps[index]
        step.approachLanes = approachLanes(step: index, of: variant)
        let distance = step.distanceAlong - along
        // Присваиваем только смену: свойство наблюдаемое, а тик — раз в секунду.
        if nextStep != step { nextStep = step }
        nextStepDistance = distance

        guard announce else { return }
        let stage = announcedStage[index] ?? 3
        let advice = step.laneAdvice
        let calls = LaneAdvice.calls(earlyCall: step.kind?.deservesEarlyCall ?? true,
                                     hasAdvice: advice != nil, speedKmh: speedKmh,
                                     cameraHolds: cameraHolds)
        guard let next = Self.voiceStage(distance: distance, spoken: stage, calls: calls) else { return }
        announcedStage[index] = next
        // Ряд — один раз на манёвр, в первой фразе, которая его несёт.
        let said = LaneAdvice.attaches(stage: next, calls: calls,
                                       alreadySaid: laneAdviceSaid.contains(index))
            ? advice : nil
        if said != nil { laneAdviceSaid.insert(index) }
        // «Затем …» — один раз на манёвр (ManeuverThen). С хвостом фраза не
        // из записанных отрывков — её говорит синтезатор.
        let then = ManeuverThen.voiced(stage: next, alreadySaid: thenSaid.contains(index), cameraHolds: cameraHolds)
            ? ManeuverThen.following(index, in: variant.steps) : nil
        if then != nil { thenSaid.insert(index) }
        // Улика для разбора поездки: какая ступень, где и с рядом ли (фраза
        // целиком не пишется — в ней улица).
        Log.route.notice("манёвр голосом: ступень \(next, privacy: .public), \(Int(distance), privacy: .public) м, \(Int(speedKmh), privacy: .public) км/ч, ряд \(said?.logName ?? "-", privacy: .public), камера держит \(cameraHolds, privacy: .public)")
        if next == 0 {
            onManeuver?(then.map { ManeuverThen.spoken(step.text, then: $0) } ?? step.text,
                        then == nil ? step.voiceEvent(meters: nil) : nil)
        } else {
            let meters = Self.spokenMeters(distance, far: next == 2)
            let phrase = Self.withAdvice(String(format: String(localized: "Через %lld метров — %@"),
                                                meters, step.text), said)
            onManeuver?(then.map { ManeuverThen.spoken(phrase, then: $0) } ?? phrase,
                        then == nil ? step.voiceEvent(meters: meters, advice: said) : nil)
        }
        // Считаем манёвр один раз — при первом объявлении. Хранимые ступени
        // это 0…2, поэтому «было 3» означает «до сих пор не объявляли».
        if stage == 3 {
            onManeuverSpoken?(step.kind?.rawValue ?? "unknown")
        }
    }

    /// Полос в нашу сторону на подъезде к шагу — по своей сети, один раз на
    /// шаг. Не нашли дороги — спросим снова через laneApproachRetrySeconds:
    /// тайлы окрестности могли ещё ехать. Спрашиваем только шаг, которому
    /// край нужен и у которого нет полос OSRM.
    private func approachLanes(step index: Int, of variant: Variant) -> Int? {
        let step = variant.steps[index]
        guard step.lanes.isEmpty, step.edge != nil, let approachRoads else { return nil }
        if let known = approachLanesByStep[index] { return known }
        if let missed = approachMissedAt[index],
           Date().timeIntervalSince(missed) < AppConfig.laneApproachRetrySeconds { return nil }
        if selectedCumulative.count != variant.points.count {
            selectedCumulative = Self.cumulative(of: variant.points)
        }
        for back in AppConfig.laneApproachProbeMeters {
            guard let probe = Self.pointAndCourse(along: step.distanceAlong - back, pts: variant.points,
                                                  cum: selectedCumulative) else { continue }
            let roads = approachRoads(probe.coordinate, AppConfig.laneApproachMatchMeters)
            if let lanes = LaneAdvice.approachLanes(at: probe.coordinate, course: probe.course,
                                                    roads: roads) {
                approachLanesByStep[index] = lanes
                approachMissedAt[index] = nil
                Log.route.notice("полос на подъезде к манёвру \(index, privacy: .public): \(lanes, privacy: .public)")
                return lanes
            }
        }
        approachMissedAt[index] = Date()
        return nil
    }

    /// Голос манёвров старой линии во время перестроения — только если мы
    /// снова на ней: съехав, водитель ждёт новый маршрут, а не старый поворот.
    nonisolated static func voicesOldLine(rebuilding: Bool, deviation: CLLocationDistance) -> Bool {
        !rebuilding || deviation <= AppConfig.rerouteDeviationMeters
    }

    /// Какую ступень голоса манёвра пора произнести: 2 — далеко («через 800
    /// метров»), 1 — близко, 0 — сама команда; nil — молчать. `spoken` — уже
    /// произнесённая ступень (3 — ещё ни одной). Ступень произносится один
    /// раз и только «вниз»: проскочив дальнюю (въехали в маршрут уже у
    /// поворота), сразу говорим ближнюю, а не догоняем пропущенную.
    nonisolated static func voiceStage(distance: CLLocationDistance, spoken: Int,
                                       earlyCall: Bool) -> Int? {
        voiceStage(distance: distance, spoken: spoken, calls: .standard(earlyCall: earlyCall))
    }

    /// То же со ступенями, которые сдвинул совет о ряде (LaneAdvice.calls).
    nonisolated static func voiceStage(distance: CLLocationDistance, spoken: Int,
                                       calls: LaneAdvice.Calls) -> Int? {
        if distance < AppConfig.maneuverNowCallMeters, spoken > 0 { return 0 }
        if distance < calls.near, spoken > 1 { return 1 }
        if let far = calls.far, distance < far, spoken > 2 { return 2 }
        return nil
    }

    /// Расстояние во фразе: дальняя — до 100 м, ближняя — до 50 м, а от
    /// 400 м (ближняя, сдвинутая к окну ряда) — до 100, как у камер:
    /// «через 450 метров» записи нет, и фраза ушла бы синтезатору.
    nonisolated static func spokenMeters(_ distance: CLLocationDistance, far: Bool) -> Int {
        let step: Double = far || distance >= 400 ? 100 : 50
        return Int((distance / step).rounded() * step)
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
    /// Из двух левых рядов.», «…налево. Перестройтесь в левый ряд»). Только
    /// для ранних объявлений: на «сейчас» перестраиваться уже поздно, и
    /// лишние слова там мешают.
    nonisolated static func withAdvice(_ phrase: String, _ advice: LaneAdvice.Advice?) -> String {
        guard let advice else { return phrase }
        return phrase + ". " + LaneAdvice.spoken(advice)
    }

    // MARK: - Движки

    struct BuiltVariant {
        let points: [MKMapPoint]
        let distance: CLLocationDistance
        let travelTime: TimeInterval
        let steps: [RouteStep]
        var laneNotices: [LaneNotice] = []
        var laneProbes: [LaneProbe] = []
        var stopAlong: CLLocationDistance?
        var offline = false
        var timeline: RouteTimeline?
    }

    /// Маршрут без сети по своему графу трасс (OfflineRouteService, 12б.10).
    /// nil — графа нет (не скачан, не проверен) или точки далеко от трасс.
    @ObservationIgnored var offlinePath: ((CLLocationCoordinate2D, CLLocationCoordinate2D) async
                                          -> OfflineRouteGraph.Path?)? {
        didSet { Wiring.assertSingleAssignment(previous: oldValue, current: offlinePath,
                                               "RouteService.offlinePath") }
    }

    /// Выбранный маршрут построен без сети — сеть вернулась, пора заменить.
    var isOfflineRoute: Bool { selected?.isOffline ?? false }

    /// `heading` — курс машины на ходу (перестроение, с 20.9 и первый
    /// маршрут на ходу): OSRM начнёт маршрут в эту сторону. Попутной дороги
    /// рядом нет (NoSegment) или сервер отказал — повтор без курса: маршрут с
    /// разворотом лучше, чем никакого. Запрос не дошёл вовсе — без повтора:
    /// он ждал бы второй таймаут, и «Нет связи» приходило бы через 24 с.
    ///
    /// MKDirections курса не принимает: у `MKDirections.Request` есть только
    /// точки, вид транспорта, время и альтернативы. Внутри Узбекистана он не
    /// строит вовсе, и маршрут с курсом идёт через OSRM; там, где Apple
    /// строит (за границей), курс не учитывается.
    private func calculate(from source: CLLocationCoordinate2D,
                           via stop: Stop?,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool,
                           heading: CLLocationDirection? = nil) async throws -> [BuiltVariant] {
        // С остановкой — сразу OSRM: промежуточных точек MKDirections не знает.
        guard stop == nil else {
            return try await ownRoute(from: source, via: stop, to: destination, alternatives: alternatives,
                                      heading: heading)
        }
        // Apple и свой сервер — одновременно: внутри Узбекистана Apple не
        // строит, и ждать его отказа перед запросом OSRM значило прибавлять
        // круг по сети к каждому построению. Apple главнее, но готовый свой
        // ответ ждёт его не дольше `appleRouteWaitSeconds` (RouteRace).
        // Задачи неструктурные: решив, не ждём проигравшего — MKDirections
        // отмену задачи не слышит.
        let (events, sink) = AsyncStream.makeStream(of: RouteRace<[BuiltVariant]>.Event.self)
        let apple = Task {
            let routes = try? await appleRoute(from: source, to: destination, alternatives: alternatives)
            sink.yield(.apple(routes?.isEmpty == false ? routes : nil))
        }
        let own = Task {
            let result = await ownRouteResult(from: source, to: destination, alternatives: alternatives,
                                              heading: heading)
            let weak = (try? result.get())?.contains(where: \.offline) ?? false
            sink.yield(.own(result, weak: weak))
        }
        let wait = AppConfig.appleRouteWaitSeconds
        let deadline = Task {
            try? await Task.sleep(for: .seconds(wait))
            sink.yield(.deadline)
        }
        defer {
            apple.cancel()
            own.cancel()
            deadline.cancel()
            sink.finish()
        }
        return try await withTaskCancellationHandler {
            var race = RouteRace<[BuiltVariant]>()
            var seen = 0
            listening: for await event in events {
                try Task.checkCancellation()
                seen += 1
                switch race.note(event) {
                case .wait:               if seen >= 3 { break listening }
                case .take(let routes):   return routes
                case .fail(let error):    throw error
                }
            }
            try Task.checkCancellation()
            switch race.fallback() {
            case .take(let routes):   return routes
            case .fail(let error):    throw error
            case .wait:               throw RouteError.noRoute
            }
        } onCancel: {
            own.cancel()
            apple.cancel()
            sink.finish()
        }
    }

    private func ownRouteResult(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
                                alternatives: Bool,
                                heading: CLLocationDirection?) async -> Result<[BuiltVariant], Error> {
        do {
            return .success(try await ownRoute(from: source, via: nil, to: destination,
                                               alternatives: alternatives, heading: heading))
        } catch {
            return .failure(error)
        }
    }

    private func ownRoute(from source: CLLocationCoordinate2D, via stop: Stop?,
                          to destination: CLLocationCoordinate2D, alternatives: Bool,
                          heading: CLLocationDirection?) async throws -> [BuiltVariant] {
        do {
            if let heading {
                do {
                    return try await osrmRoute(from: source, via: stop, to: destination,
                                               alternatives: alternatives, heading: heading)
                } catch let error where Self.retriesWithoutHeading(after: error) {
                    Log.route.notice("маршрут по курсу не построен — повтор без курса: \(error.localizedDescription, privacy: .public)")
                }
            }
            return try await osrmRoute(from: source, via: stop, to: destination, alternatives: alternatives)
        } catch {
            // Отменили или ответ больше не нужен — свой граф трасс ни к чему.
            guard Self.fallsBackOffline(after: error, taskCancelled: Task.isCancelled) else { throw error }
            // Ни Apple, ни свой сервер — на трассе без связи. Последнее средство —
            // свой граф трасс: приблизительный маршрут лучше, чем никакого
            // (12б.10). С остановкой — нет: заезд по пути без сети не считаем.
            guard stop == nil, let path = await offlinePath?(source, destination), path.points.count >= 2 else {
                if error as? RouteError == .noConnection { throw RouteError.serverUnreachable }
                throw error
            }
            // Сервер только что не ответил — повтор замены не раньше своего срока.
            offlineReplaceAttemptAt = Date()
            Log.route.notice("маршрут без сети: свой граф трасс, \(Int(path.distance / 1000), privacy: .public) км")
            let arrive = RouteStep(distanceAlong: path.distance, text: String(localized: "Вы на месте"),
                                   icon: "flag.checkered", kind: .arrive)
            return [BuiltVariant(points: path.points.map(MKMapPoint.init), distance: path.distance,
                                 travelTime: path.travelTime, steps: [arrive], offline: true)]
        }
    }

    /// Сеть вернулась, а маршрут построен без неё — молча заменить серверным
    /// той же цели (без альтернатив: человек уже едет). Не вышло — остаётся
    /// приблизительный.
    func replaceOfflineRoute(from coordinate: CLLocationCoordinate2D?, heading: CLLocationDirection?,
                             cameras: [Camera]) {
        guard isOfflineRoute, !isRebuilding, let coordinate, let destination = destinationCoordinate else { return }
        offlineReplaceAttemptAt = Date()
        isRebuilding = true
        let name = destinationName
        let gen = generation
        Task {
            defer { isRebuilding = false }
            let built: [BuiltVariant]
            do {
                built = try await calculate(from: coordinate, via: nil, to: destination, alternatives: false,
                                            heading: heading)
            } catch {
                Log.route.notice("серверный маршрут вместо офлайнового не построен: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard built.contains(where: { !$0.offline }), gen == generation else { return }
            Log.route.notice("маршрут без сети заменён серверным")
            await apply(built, name: name, destination: destination, cameras: cameras, gen: gen, history: nil)
        }
    }

    /// Последняя попытка до сервера для маршрута без сети: его построение
    /// (сервер не ответил) или замена.
    @ObservationIgnored private var offlineReplaceAttemptAt = Date.distantPast

    /// Повтор замены без перехода «нет связи → есть»: для системы связь могла
    /// и не пропадать (слабый сигнал на трассе, лёг сервер маршрутов), и
    /// NetworkMonitor.onOnline тогда не придёт никогда — приблизительный
    /// маршрут без манёвров оставался до конца поездки (ревью 14.2). Зовётся
    /// на уже проснувшемся радио, не чаще `offlineRouteRetrySeconds`.
    /// Маршрут без сети и срок новой попытки серверного подошёл (без сети) —
    /// для планировщика сети (NetScheduler, 36B).
    func isOfflineRetryDue(now: Date = Date()) -> Bool {
        isOfflineRoute && now.timeIntervalSince(offlineReplaceAttemptAt) >= AppConfig.offlineRouteRetrySeconds
    }

    func retryOfflineRouteIfDue(from coordinate: CLLocationCoordinate2D?, heading: CLLocationDirection?,
                                cameras: [Camera], now: Date = Date()) {
        guard isOfflineRetryDue(now: now) else { return }
        replaceOfflineRoute(from: coordinate, heading: heading, cameras: cameras)
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
            // Линия, пройденная до шага, — для угла поворота (AppleTurn).
            var walked: [CLLocationCoordinate2D] = []
            let last = route.steps.count - 1
            // Шаг без текста тоже занимает дорогу: пропуская его, не прибавляли
            // и его длину — следующие манёвры съезжали назад по маршруту.
            for (index, step) in route.steps.enumerated() {
                let line = Self.coordinates(of: step.polyline)
                if !step.instructions.isEmpty {
                    if index == last, index > 0 {
                        steps.append(RouteStep(distanceAlong: along, text: step.instructions,
                                               icon: "flag.checkered", kind: .arrive))
                    } else {
                        // Тип — из угла между линиями; Apple его не отдаёт.
                        let modifier = index == 0 ? nil : AppleTurn.modifier(incoming: walked, outgoing: line)
                        steps.append(RouteStep(distanceAlong: along, text: step.instructions,
                                               icon: AppleTurn.icon(modifier: modifier),
                                               kind: modifier.map { ManeuverKind.fromOSRM(modifier: $0) }))
                    }
                }
                walked += line
                along += step.distance
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.expectedTravelTime, steps: steps)
        }
    }

    /// Точки линии MKPolyline как координаты.
    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&out, range: NSRange(location: 0, length: polyline.pointCount))
        return out
    }

    // MARK: - Своя дорога (24.4)

    /// Своя дорога через опорные точки линии (MyRoad). Тот же свой сервер
    /// маршрутов, что и всегда, без альтернатив. Не вышло — nil и строка в
    /// журнал: варианты движка остаются, просто без своей дороги.
    private func myRoadRoute(_ plan: MyRoad.Plan?, from source: CLLocationCoordinate2D,
                             to destination: CLLocationCoordinate2D,
                             heading: CLLocationDirection?) async -> BuiltVariant? {
        guard let plan, !plan.via.isEmpty, isRoutingEnabled else { return nil }
        do {
            return try await osrmRoute(from: source, via: nil, to: destination, alternatives: false,
                                       heading: heading, pass: plan.via).first
        } catch {
            Log.route.notice("своя дорога не построена (\(plan.via.count, privacy: .public) точек): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Перестроение своей дорогой: маршрут через оставшиеся опорные точки,
    /// если он прошёл ту же отбраковку петли, что и при выборе. nil — точек
    /// нет, сервер отказал или вышла петля: перестраивает движок.
    private func rerouteMyRoad(_ plan: MyRoad.Plan?, from source: CLLocationCoordinate2D,
                               to destination: CLLocationCoordinate2D,
                               heading: CLLocationDirection?) async -> BuiltVariant? {
        guard let plan, let mine = await myRoadRoute(plan, from: source, to: destination, heading: heading)
        else { return nil }
        let path = mine.points.map(\.coordinate)
        let distance = mine.distance
        guard await offMain({ MyRoad.accepts(distance: distance, path: path, plan: plan) }) else {
            Log.route.notice("перестроение своей дорогой отброшено: \(Int(distance), privacy: .public) м против \(Int(plan.lineLength + plan.startOffset), privacy: .public) м — ведёт движок")
            return nil
        }
        Log.route.notice("перестроение своей дорогой: точек \(plan.via.count, privacy: .public)")
        return mine
    }

    /// Варианты движка вместе со своей дорогой: вариант движка, который и
    /// так идёт своим путём, помечается сам; иначе маршрут через опорные
    /// точки — если он та же дорога, а не петля, — встаёт на место самого
    /// долгого. Без сети (свой граф трасс) — без своей дороги: там нет и
    /// выбора вариантов.
    nonisolated private static func merge(_ built: [BuiltVariant], mine: BuiltVariant?,
                                          plan: MyRoad.Plan?) -> (variants: [BuiltVariant], index: Int?) {
        guard let plan, !built.contains(where: \.offline) else { return (built, nil) }
        if let match = MyRoad.matching(built.map { $0.points.map(\.coordinate) }, plan: plan) {
            Log.route.notice("своя дорога: вариант движка \(match, privacy: .public) уже по ней")
            return (built, match)
        }
        guard let mine else { return (built, nil) }
        guard MyRoad.accepts(distance: mine.distance, path: mine.points.map(\.coordinate), plan: plan) else {
            Log.route.notice("своя дорога отброшена: \(Int(mine.distance), privacy: .public) м против линии \(Int(plan.lineLength + plan.startOffset), privacy: .public) м")
            return (built, nil)
        }
        var variants = built
        if let drop = MyRoad.slotToFree(times: variants.map(\.travelTime)) { variants.remove(at: drop) }
        variants.append(mine)
        return (variants, variants.count - 1)
    }

    private func osrmRoute(from source: CLLocationCoordinate2D,
                           via stop: Stop?,
                           to destination: CLLocationCoordinate2D,
                           alternatives: Bool,
                           heading: CLLocationDirection? = nil,
                           pass: [MyRoad.Via] = []) async throws -> [BuiltVariant] {
        let waypoints = [source] + (stop.map { [$0.coordinate] } ?? []) + pass.map(\.coordinate) + [destination]
        let path = waypoints
            .map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }
            .joined(separator: ";")

        // Отказ сервера на новые параметры (29.E) — один повтор прежним
        // запросом (OSRMQuery.send): маршрут обязан построиться.
        let answer = try await OSRMQuery.send { legacy in
            let query = pass.isEmpty
                ? Self.osrmQueryItems(alternatives: alternatives, heading: heading, waypoints: waypoints.count,
                                      legacy: legacy)
                : Self.osrmQueryItems(heading: heading, via: pass, legacy: legacy)
            do {
                let raw = try await osrm.getRaw("route/v1/driving/" + path, query: query, label: "osrm route",
                                                cachePolicy: .reloadIgnoringLocalCacheData)
                return OSRMQuery.Answer(status: raw.status, data: raw.data)
            } catch {
                throw Self.transportFailure(error)
            }
        }
        if answer.legacy {
            Log.route.notice("OSRM отверг новые параметры — маршрут прежним запросом")
        }
        // «Пути нет» (NoRoute/NoSegment) — «маршрут не найден»; прочий отказ —
        // сбой сервера, а не «дороги не существует».
        if let refusal = OSRMQuery.refusal(status: answer.status, data: answer.data) {
            Log.route.error("OSRM HTTP \(answer.status, privacy: .public): \(refusal == .noRoute ? "пути нет" : "сбой сервера", privacy: .public)")
            throw refusal == .noRoute ? RouteError.noRoute : RouteError.serverFailed
        }
        let data = answer.data

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
    nonisolated static func parseOSRM(_ data: Data, language: String,
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
            let path = route.geometry.coordinates.map {
                CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
            }
            let points = path.map(MKMapPoint.init)
            // Точка манёвра — вершина линии (location шага), а не сумма длин
            // шагов: та расходится с линией на сотни метров (ManeuverAnchor).
            let cumulative = TurnBend.cumulative(path)
            let flat = route.legs.flatMap(\.steps)
            let lineCumulative = Self.cumulative(of: points)
            let anchors = ManeuverAnchor.positions(locations: flat.map(\.maneuver.location),
                                                   distances: flat.map(\.distance),
                                                   path: path, cumulative: lineCumulative)
            var steps: [RouteStep] = []
            var notices: [LaneNotice] = []
            var probes = LaneProbeCollector(path: path)
            var stopAlong: CLLocationDistance?
            var position = 0
            for (legIndex, leg) in route.legs.enumerated() {
                let isLast = legIndex == route.legs.count - 1
                var currentName: String?
                // Начало плеча после первого — заезд.
                if legIndex == 1, anchors.indices.contains(position) { stopAlong = anchors[position].along }
                for step in leg.steps {
                    let anchor = anchors[position]
                    position += 1
                    let along = anchor.along
                    var bend: TurnBend.Measure?
                    if step.maneuver.type == "continue" || step.maneuver.type == "new name",
                       let index = anchor.vertex {
                        bend = TurnBend.measure(path: path, cumulative: cumulative, at: cumulative[index])
                    }
                    let built = maneuverStep(step, at: along, language: language,
                                             stopName: isLast ? nil : stopName,
                                             currentName: currentName, bend: bend)
                    currentName = step.name
                    probes.add(step, at: along, built: built, index: steps.count)
                    if let built { steps.append(built) }
                    notices += laneNotices(step, at: along, isManeuver: built != nil)
                }
            }
            return BuiltVariant(points: points, distance: route.distance,
                                travelTime: route.duration, steps: steps, laneNotices: notices,
                                laneProbes: probes.probes, stopAlong: stopAlong,
                                timeline: RouteTimeline(starts: anchors.map(\.along),
                                                        durations: flat.map(\.duration),
                                                        length: lineCumulative.last ?? 0))
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
            /// Секунды шага по графу — кумулятив времени (RouteTimeline).
            var duration: Double? = nil
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
            /// Курсы всех дорог узла — сколько их сходится (TurnBend, 29.E).
            var bearings: [Int]? = nil
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
    /// `currentName` — улица, по которой едем К манёвру (имя предыдущего
    /// шага OSRM): разворот на ней же — «развернитесь», а не «разворот на
    /// улицу Беруни», когда мы и так на Беруни (снимок 63, 21.10).
    nonisolated static func maneuverStep(_ step: OSRMResponse.Step,
                                         at along: CLLocationDistance,
                                         language: String,
                                         stopName: String? = nil,
                                         currentName: String? = nil,
                                         bend: TurnBend.Measure? = nil) -> RouteStep? {
        let m = step.maneuver
        let osrmType = spokenType(m.type)
        // «Остаёмся на дороге», а линия на перекрёстке ломается (29.E,
        // TurnBend): говорим как поворот — и в голосе, и в крае ряда.
        let bendTurn = TurnBend.voices(type: osrmType, modifier: m.modifier, bend: bend,
                                       roads: step.intersections?.first?.bearings?.count ?? 0)
        let type = bendTurn ? "turn" : osrmType
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

        switch osrmType {
        case "turn", "end of road":
            if let (phrase, symbol) = turnPhrase(m.modifier) { text = phrase; icon = symbol }
        case "continue":
            // `continue` у OSRM значит «ОСТАВАЙТЕСЬ на своей дороге», а
            // modifier описывает, куда эта дорога изгибается. Стоял он в одной
            // ветке с turn — и «дорога уходит правее» произносилось как
            // «поверните направо». Водитель едет прямо и слышит команду
            // свернуть; каждый такой шаг объявлялся ещё и трижды.
            //
            // Молчим. Разворот — исключение: он требует действия, как его ни
            // назови. И излом на перекрёстке (29.E): OSRM прислал continue, а
            // улица ломается на 60–90° среди других дорог — это поворот.
            if m.modifier == "uturn", let (phrase, symbol) = turnPhrase("uturn") {
                text = phrase; icon = symbol
            } else if bendTurn, let (phrase, symbol) = turnPhrase(m.modifier) {
                text = phrase; icon = symbol
            }
        case "new name":
            // Смена названия молчит — кроме того же излома на перекрёстке.
            if bendTurn, let (phrase, symbol) = turnPhrase(m.modifier) { text = phrase; icon = symbol }
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
            text = String(localized: "съезд на развязку"); icon = rampIcon(m.modifier)
        case "off ramp":
            text = String(localized: "сверните на съезд"); icon = rampIcon(m.modifier)
        case "roundabout", "rotary":
            // Номер съезда неизвестен — без номера: выдуманный «1-й» уводит
            // с кольца раньше нужного.
            if let exit = m.exit, exit > 0 {
                text = String(format: String(localized: "на кольце %lld-й съезд"), exit)
            } else {
                text = String(localized: "въезжайте на кольцо")
            }
            icon = "arrow.triangle.2.circlepath"
        case "arrive":
            if let stopName {
                text = String(format: String(localized: "заезд: %@"), stopName); icon = "mappin.circle.fill"
            } else {
                text = String(localized: "вы прибыли"); icon = "flag.checkered"
            }
        default:
            // depart; exit roundabout/rotary — съезд уже назван на въезде;
            // use lane — ряд скажут подсказки полос; notification — смена
            // свойств дороги без манёвра.
            break
        }

        // Разворот на той же улице: улицу не называем — водитель на ней и
        // стоит, «на улицу Беруни» звучит как поворот куда-то ещё.
        let uturnInPlace = m.modifier == "uturn" && ["turn", "continue", "end of road"].contains(osrmType)
            && sameStreet(step.name, currentName)
        if uturnInPlace { text = String(localized: "развернитесь") }
        guard var result = text else { return nil }
        let phrase = result
        // Излом на своей же улице: улицу не называем — «налево на улицу
        // Сеул», когда мы и так на Сеуле, звучит как поворот куда-то ещё.
        let bendInPlace = bendTurn && sameStreet(step.name, currentName)
        if !step.name.isEmpty, osrmType != "arrive", !uturnInPlace, !bendInPlace {
            // «на улицу Беруни», а не «на Beruniy shoh ko'chasi»: фраза просит
            // винительный падеж.
            let street = StreetName.display(step.name, language: language,
                                            grammaticalCase: .accusative)
            result += String(format: String(localized: " на %@"), street)
        }
        // Тип манёвра — отдельно от фразы. Фраза зависит ещё и от типа
        // развязки («держитесь правее» на развилке против «поверните направо»
        // на перекрёстке), а геометрия поворота — только от модификатора.
        let kind: ManeuverKind = osrmType == "arrive" ? .arrive
            : osrmType == "roundabout" || osrmType == "rotary" ? .roundabout
            : ManeuverKind.fromOSRM(modifier: m.modifier)
        // Тип команды для записанного голоса — только у фразы без имени
        // собственного: улицу и название остановки диктор не записывал.
        let voiceAction = result == phrase && stopName == nil
            ? VoiceEvent.Action(osrmType: type, modifier: m.modifier, exit: m.exit) : nil
        return RouteStep(distanceAlong: along, text: result, icon: icon,
                         kind: kind, lanes: lanes(of: step),
                         shortText: result == phrase ? nil : phrase,
                         voiceAction: voiceAction,
                         edge: LaneAdvice.edge(osrmType: type, modifier: m.modifier))
    }

    /// Тип OSRM, как его говорим: малое кольцо (`roundabout turn`) OSRM
    /// велит читать обычным поворотом, устаревший `ramp` — съездом.
    nonisolated static func spokenType(_ type: String) -> String {
        switch type {
        case "roundabout turn": "turn"
        case "ramp":            "off ramp"
        default:                type
        }
    }

    /// Стрелка съезда по стороне: съезд налево — не стрелка направо.
    nonisolated static func rampIcon(_ modifier: String?) -> String {
        switch modifier {
        case "left", "slight left", "sharp left": "arrow.up.left"
        default:                                  "arrow.up.right"
        }
    }

    /// Одна ли это улица: имена OSRM сравниваются без регистра и крайних
    /// пробелов. Пустое имя — не улица: «развернитесь» без доказательства
    /// не говорим (тогда фраза прежняя).
    nonisolated static func sameStreet(_ name: String, _ other: String?) -> Bool {
        let a = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty, let other else { return false }
        return a == other.trimmingCharacters(in: .whitespaces).lowercased()
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

    /// Где спросить слой полос (20.8): манёвры без полос OSRM и перекрёстки,
    /// которые маршрут проезжает прямо, тоже без них. Собирается при разборе
    /// — точки манёвров и перекрёстков есть только в ответе OSRM, — а сам слой
    /// прикладывается позже (`apply`, `laneOverlayChanged`): он может приехать
    /// и после построения.
    ///
    /// Кольцо и финиш не спрашиваем: ряд на кольце зависит от съезда, а не от
    /// стрелок подхода. Курс въезда — по линии маршрута (RoutePathCursor);
    /// точка без курса (старт маршрута, не у линии) — не спрашиваем: без
    /// курса встречный подход того же перекрёстка неотличим от нашего.
    nonisolated struct LaneProbeCollector {
        private var cursor: RoutePathCursor
        private(set) var probes: [LaneProbe] = []

        init(path: [CLLocationCoordinate2D]) {
            cursor = RoutePathCursor(path: path)
        }

        /// Шаг OSRM по порядку. `built` — манёвр, который из него вышел
        /// (nil — шаг не озвучивается), `index` — его место в `steps`.
        mutating func add(_ step: OSRMResponse.Step, at along: CLLocationDistance,
                          built: RouteStep?, index: Int) {
            if let built, built.lanes.isEmpty, let kind = built.kind,
               kind != .roundabout, kind != .arrive,
               let location = step.maneuver.location, location.count == 2 {
                probe(.step(index), lat: location[1], lon: location[0], along: along, maneuver: kind)
            }
            guard let intersections = step.intersections,
                  let start = step.maneuver.location, start.count == 2 else { return }
            for (position, intersection) in intersections.enumerated() {
                // Первый перекрёсток шага-манёвра — сам манёвр (выше).
                if position == 0, built != nil { continue }
                // Полосы OSRM есть (даже «подходят все») — OSRM главнее.
                guard intersection.lanes?.isEmpty ?? true,
                      let point = intersection.location, point.count == 2 else { continue }
                // Положение — как у ограничений OSRM (laneNotices): от начала шага по прямой.
                let offset = min(step.distance, GeoMath.fastDistance(start[1], start[0], point[1], point[0]))
                probe(.passage(along + offset), lat: point[1], lon: point[0], along: along + offset, maneuver: nil)
            }
        }

        private mutating func probe(_ target: LaneProbe.Target, lat: Double, lon: Double,
                                    along: CLLocationDistance, maneuver: ManeuverKind?) {
            let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            guard let bearing = cursor.approachBearing(to: point, estimatedAlong: along) else { return }
            probes.append(LaneProbe(target: target, latitude: lat, longitude: lon,
                                    approachBearing: bearing, maneuver: maneuver))
        }
    }

    // MARK: - Применение результата

    private func apply(_ built: [BuiltVariant], name: String,
                       destination: CLLocationCoordinate2D, cameras: [Camera],
                       gen: Int, history: RouteChoice.History?,
                       myRoad: (index: Int, plan: MyRoad.Plan)? = nil) async {
        // Камеры по коридору каждого варианта считаем ВНЕ главного потока —
        // длинные маршруты не должны дёргать UI даже на старых устройствах.
        let inputs = built.filter { $0.points.count >= 2 }
        guard !inputs.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        let traffic = trafficSnapshot?()
        let events = roadEvents?() ?? []
        let eventsNow = Date()
        // Обычные пробки часа (27.E) — файлы из памяти; каких нет — попросить,
        // время вариантов досчитает typicalTrafficArrived.
        let neededTypical = TrafficForecast.buckets(departure: eventsNow,
                                                    travelTime: inputs.map(\.travelTime).max() ?? 0)
        let typicalFiles = typicalFiles(neededTypical)
        if typicalFiles.count < neededTypical.count { prefetchTypical?(neededTypical) }
        let profile = trafficProfile?()
        prefetchProfile?()
        // Своя дорога — только когда её план передан: при выборе вариантов
        // (если «Учитывать мои поездки» включено) и при перестроении своей
        // дорогой — там ярлык и время по своей истории сохраняются.
        let mine = myRoad.flatMap { inputs.indices.contains($0.index) ? $0 : nil }

        // Там же — выбор варианта по своим поездкам: сравнение с сотней
        // треков стоит десятки миллисекунд, главному потоку они не нужны.
        let (variantCameras, verdict, trafficForecasts, variantSpots, choiceInputs) = await offMain {
            let found = inputs.map { variant -> [RouteCamera] in
                var bbox = MKMapRect.null
                for p in variant.points { bbox = bbox.union(MKMapRect(origin: p, size: MKMapSize())) }
                let centerLat = variant.points[variant.points.count / 2].coordinate.latitude
                return Self.camerasAlong(pts: variant.points, bbox: bbox,
                                         centerLat: centerLat, cameras: cameras)
            }
            // Пробки — к каждому варианту: «Быстрый» выбирается по времени
            // с пробками, а не по пустым дорогам графа. Живые — на ближние
            // полчаса пути, дальше и без них — обычные для часа (27.E).
            let forecasts = inputs.map { variant in
                Self.variantDelay(points: variant.points.map(\.coordinate), travelTime: variant.travelTime,
                                  now: eventsNow, live: traffic, profile: profile, typical: typicalFiles)
            }
            let delays = forecasts.map { $0?.seconds }
            // Своя дорога — со временем по своим поездкам этого часа (24.4).
            let personal = mine.map { mine -> RouteChoice.Personal in
                let estimate = MyRoad.estimate(mine.plan, now: eventsNow, snapshot: traffic)
                return RouteChoice.Personal(direction: mine.plan.direction, trips: mine.plan.trips,
                                            seconds: estimate?.seconds, jamSeconds: estimate?.jamSeconds ?? 0)
            }
            let choiceInputs = inputs.indices.map { index in
                RouteChoice.Input(path: inputs[index].points.map(\.coordinate),
                                  distance: inputs[index].distance,
                                  travelTime: inputs[index].travelTime + (delays[index] ?? 0),
                                  // Только свои (29.E): встречная камера проспекта
                                  // не делает путь «камерным».
                                  cameraIDs: found[index].filter { !$0.provenOncoming }.map(\.camera.id),
                                  hardManeuvers: RouteChoice.hardManeuvers(inputs[index].steps),
                                  closures: RoadEventRules.closures(on: inputs[index].points.map(\.coordinate),
                                                                    events: events, now: eventsNow),
                                  personal: index == mine?.index ? personal : nil)
            }
            let choice = RouteChoice.decide(choiceInputs, history: history)
            // Где рисовать камеры на линии — тем же проходом, раз на маршрут.
            let spots = inputs.indices.map { index in
                CameraOnLine.routeSpots(points: inputs[index].points,
                                        cameras: found[index].map { ($0.camera, $0.distanceAlong) })
            }
            return (found, choice, forecasts, spots, choiceInputs)
        }

        // Второй раз, и это не дублирование проверки у вызывающего: тот
        // сверял поколение ДО входа сюда, а внутри мы сами ушли в await на
        // время подсчёта камер по коридору. Успел человек за это время нажать
        // «отменить» или перестроить — generation вырос, и запись ниже вернула
        // бы на карту маршрут, который уже отменён. Правило 12: после каждого
        // await состояние перепроверяется, а не досчитывается по памяти.
        guard gen == generation else { return }

        // Слой полос — здесь, на главном, а не в фоне вместе с камерами: так
        // берётся слой, действующий СЕЙЧАС (приехавший за время подсчёта не
        // теряется), а стоит это микросекунды на точку (PerformanceBudgetTests).
        let overlay = laneOverlay?()
        var laneStats: [LaneOverlay.Stats] = []
        variants = inputs.enumerated().map { index, variant in
            let lanes = LaneOverlay.attach(steps: variant.steps, notices: variant.laneNotices,
                                           probes: variant.laneProbes, overlay: overlay)
            laneStats.append(lanes.stats)
            return Variant(id: index,
                           points: variant.points,
                           polyline: MKPolyline(points: variant.points, count: variant.points.count),
                           distance: variant.distance,
                           travelTime: variant.travelTime,
                           cameras: variantCameras[index],
                           steps: lanes.steps,
                           assessment: verdict.assessments[index],
                           laneNotices: lanes.notices,
                           laneProbes: variant.laneProbes,
                           stopAlong: variant.stopAlong,
                           isOffline: variant.offline,
                           trafficDelay: trafficForecasts[index]?.seconds,
                           trafficSource: trafficForecasts[index]?.source,
                           trafficLiveDelay: trafficForecasts[index]?.liveSeconds,
                           paceFactor: paceFactor?(PersonalPace.roadClass(distance: variant.distance,
                                                                          travelTime: variant.travelTime)) ?? 1,
                           cameraSpots: variantSpots[index],
                           timeline: variant.timeline)
        }
        selectedID = verdict.recommended
        // Новый набор: ярлыки могут подвинуться за поздними пробками, пока
        // водитель не коснулся выбора (ChoiceRelabelGate, решение 28.10).
        choiceBasis = (choiceInputs, history)
        choiceGate.shown()
        if isTripActive?() == true || choiceShownInCar { choiceGate.touch() }
        // Одна строка на маршрут — для разбора реальной поездки: сколько
        // рядов дал OSRM, сколько слой и где остался только край.
        if laneStats.indices.contains(selectedID) {
            let line = Self.laneLogLine(laneStats[selectedID], overlay: overlay)
            Log.route.notice("\(line, privacy: .public)")
        }
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
        // Профиль или «обычно» пришли, пока считали камеры, — время вариантов
        // досчитать сейчас, по уже записанным линиям.
        if trafficArrival.buildFinished() { recomputeVariantTraffic(now: Date()) }
    }

    // MARK: - Слой полос (20.8)

    /// Слой приехал, сменился или снят пультом — приложить к уже построенному
    /// маршруту сразу, а не со следующим перестроением. Перестроения может не
    /// быть до самого финиша, а первый маршрут после запуска строится раньше,
    /// чем слой поднимается с диска, — и молчал бы на всех поворотах поездки.
    /// Дёшево: точки спроса собраны при разборе, на каждую — поиск по сетке.
    /// Идущее построение не мешает: `apply` возьмёт действующий слой сам.
    func laneOverlayChanged() {
        guard isActive else { return }
        let overlay = laneOverlay?()
        var changed = false
        var stats: LaneOverlay.Stats?
        let updated = variants.map { variant -> Variant in
            let lanes = LaneOverlay.attach(steps: variant.steps, notices: variant.laneNotices,
                                           probes: variant.laneProbes, overlay: overlay)
            if variant.id == selectedID { stats = lanes.stats }
            guard lanes.steps != variant.steps || lanes.notices != variant.laneNotices else { return variant }
            changed = true
            var copy = variant
            copy.steps = lanes.steps
            copy.laneNotices = lanes.notices
            return copy
        }
        // Присваиваем только смену: варианты наблюдаемы.
        guard changed else { return }
        variants = updated
        if let stats {
            let line = Self.laneLogLine(stats, overlay: overlay)
            Log.route.notice("\(line, privacy: .public) — слой обновился")
        }
        // Ряд ближайшего манёвра — сразу, без голоса: озвучка — дело живого прогресса.
        if !isProgressFrozen, let variant = selected {
            updateManeuvers(variant: variant, along: progressAlong, announce: false)
        }
    }

    /// «полосы: OSRM 3, слой 5, край 9 (проезды: OSRM 1, слой 2), слой: 1200 подходов».
    nonisolated static func laneLogLine(_ stats: LaneOverlay.Stats, overlay: LaneOverlay?) -> String {
        stats.logLine + (overlay.map { ", слой: \($0.count) подходов" } ?? ", слоя нет")
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
        /// С какого момента предложение ждёт экрана (появилось или его
        /// вытеснил баннер камеры).
        var waitingSince: Date
        /// Когда водитель его УВИДЕЛ (карточка на телефоне или баннер в
        /// машине); nil — ещё нет. В машине баннер ждёт за камерой весь её
        /// подъезд (30–50 с), и 20 с от создания истекали раньше, чем он
        /// вставал: голос предлагал, а нажать было некуда, и истёкшее
        /// засчитывалось отказом с 10 минутами тишины (сценарий D1, 20.10).
        var shownAt: Date?

        /// Без ответа до этого момента — «остаёмся» (показано) или тихо
        /// снимаем (так и не показали).
        var expires: Date {
            shownAt.map { $0.addingTimeInterval(AppConfig.detourOfferSeconds) }
                ?? waitingSince.addingTimeInterval(AppConfig.detourOfferUnseenSeconds)
        }

        /// «Есть путь быстрее на 8 мин» — и на телефоне, и в машине.
        var title: String {
            String(format: String(localized: "Есть путь быстрее на %@"),
                   Formatting.unbreakable(Formatting.duration(saving)))
        }
        /// Для узкого экрана машины: «Быстрее на 8 мин».
        var shortTitle: String {
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
    /// Предложение истекло, так и не дойдя до экрана: голос молчит, открытие — нет.
    @ObservationIgnored private var detourUnseenAt: Date?
    @ObservationIgnored private var detourOpenedAt: Date?
    @ObservationIgnored private var detourOffers = 0
    @ObservationIgnored private var detourSearching = false

    /// На каждом фиксе поездки — и стоя: в пробке машина не сдвигается, и
    /// updateProgress (он ждёт смещения) молчит ровно тогда, когда объезд нужен.
    /// Кроме фиксов — открытие приложения или экрана машины и новый файл
    /// пробок: стоящему телефону фиксов может не прийти минутами.
    /// `course` — достоверный курс (−1 — нет): объезд начинается туда, куда
    /// машина едет, как и перестроение, а не с разворота на встречную.
    func considerDetour(coordinate: CLLocationCoordinate2D, speedKmh: Double, course: CLLocationDirection = -1,
                        now: Date = Date(), trigger: DetourAdvisor.Trigger = .fix) {
        if trigger == .opened { detourOpenedAt = now }
        // Истекло — показанное: это «остаёмся», те же 10 минут тишины. Так и не
        // показанное считается в лимит и глушит голос, но открывшему приложение
        // водителю выгоду показать можно (ревью 20.10: без этого невиданное
        // предложение звучало снова через 3 мин всю пробку).
        if let offer = detourOffer, now >= offer.expires {
            if offer.shownAt == nil {
                detourOffer = nil
                detourVariant = nil
                detourUnseenAt = now
                Log.route.notice("объезд: так и не показано")
            } else {
                declineDetour(now: now, reason: "нет ответа")
            }
        }
        let crawl = detourCrawl.update(speedKmh: speedKmh, at: now)
        // Пульт выключил маршруты (OSRM лёг) — поиск объезда не ходит (S24).
        // Ниже истечения и счёта «ползём»: открытое предложение должно истечь,
        // а не висеть до конца маршрута (ревью S24).
        guard isRoutingEnabled else { return }
        let reason = DetourAdvisor.effective(trigger, sinceOpened: detourOpenedAt.map { now.timeIntervalSince($0) })
        guard let variant = selected, let destination = destinationCoordinate,
              !isBuilding, !isRebuilding, detourOffer == nil, !detourSearching,
              let snapshot = trafficSnapshot?(), snapshot.isFresh(now: now),
              DetourAdvisor.shouldSearch(remainingDistance: remainingDistance,
                                         delayAhead: remainingTrafficDelay,
                                         currentRemaining: engineRemaining,
                                         sinceLastSearch: detourSearchAt.map { now.timeIntervalSince($0) },
                                         sinceDecline: detourDeclinedAt.map { now.timeIntervalSince($0) },
                                         offersOnRoute: detourOffers,
                                         sinceUnseen: detourUnseenAt.map { now.timeIntervalSince($0) },
                                         trigger: reason) else { return }
        detourSearching = true
        detourSearchAt = now
        let gen = generation
        let points = variant.points
        let along = progressAlong
        // Той же меркой, что варианты: движок + пробки, не личный остаток (8.8.11).
        let currentRemaining = engineRemaining
        let via = stop
        let heading = course >= 0 ? course : nil
        Log.route.notice("объезд: ищу (\(String(describing: reason), privacy: .public)) — впереди +\(Int(self.remainingTrafficDelay), privacy: .public) с, ползём \(Int(crawl), privacy: .public) с")
        Task {
            defer { detourSearching = false }
            let built: [BuiltVariant]
            do {
                built = try await calculate(from: coordinate, via: via, to: destination, alternatives: true,
                                            heading: heading)
            } catch {
                Log.route.notice("объезд: варианты не построены — \(error.localizedDescription, privacy: .public)")
                return
            }
            guard gen == generation else { return }
            let found = built
            let offer = await Task.detached(priority: .utility) { () -> DetourAdvisor.Offer? in
                let current = Self.remaining(points, after: along)
                let scored = found.map { variant in
                    let path = variant.points.map(\.coordinate)
                    return DetourAdvisor.Candidate(points: path,
                                                   expectedTime: variant.travelTime + snapshot.delay(along: path),
                                                   steps: variant.steps)
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
            // Срок на ответ пойдёт, когда предложение встанет на экран. Телефон
            // заблокирован, машины нет — услышав голос, водитель успеет открыть
            // приложение: до 09.11 предложение тут же считалось отказом.
            let shown = DetourOffer(id: detourCounter, saving: offer.saving, via: offer.via, waitingSince: Date())
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

    /// Предложение на экране — карточка на телефоне или баннер в машине:
    /// отсюда отсчитывается время на ответ.
    func noteDetourShown(id: Int, now: Date = Date()) {
        guard var offer = detourOffer, offer.id == id, offer.shownAt == nil else { return }
        offer.shownAt = now
        detourOffer = offer
    }

    /// Баннер предложения вытеснен (камера впереди) — время на ответ начнётся
    /// заново, когда он снова встанет на экран.
    func noteDetourHidden(id: Int, now: Date = Date()) {
        guard var offer = detourOffer, offer.id == id, offer.shownAt != nil else { return }
        offer.shownAt = nil
        offer.waitingSince = now
        detourOffer = offer
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
        detourOffer = DetourOffer(id: detourCounter, saving: 8 * 60, via: "Шота Руставели", waitingSince: Date())
    }

    /// Скриншот-хук `-demoMyRoad` (24.4): варианты движка и своя дорога без
    /// сети — пути подставные, а выбор, ярлыки и время по своим поездкам
    /// идут настоящим путём (`merge` → `apply`).
    func seedDemoMyRoad(name: String, destination: CLLocationCoordinate2D,
                        engine: [(path: [CLLocationCoordinate2D], seconds: TimeInterval)],
                        mine: (path: [CLLocationCoordinate2D], seconds: TimeInterval),
                        plan: MyRoad.Plan, cameras: [Camera]) async {
        func built(_ path: [CLLocationCoordinate2D], _ seconds: TimeInterval) -> BuiltVariant {
            let points = path.map(MKMapPoint.init)
            let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let arrive = RouteStep(distanceAlong: length, text: String(localized: "Вы на месте"),
                                   icon: "flag.checkered", kind: .arrive)
            return BuiltVariant(points: points, distance: length, travelTime: seconds, steps: [arrive])
        }
        generation += 1
        let gen = generation
        let merged = Self.merge(engine.map { built($0.path, $0.seconds) }, mine: built(mine.path, mine.seconds),
                                plan: plan)
        await apply(merged.variants, name: name, destination: destination, cameras: cameras, gen: gen,
                    history: personalHistory?() ?? RouteChoice.History(tracks: [], overspeedCameraIDs: []),
                    myRoad: merged.index.map { ($0, plan) })
    }

    /// Тестовый хук (37): маршрут по готовой линии без сети — тот же `apply`,
    /// что у настоящего построения. Сквозной тест часов прибытия.
    func seedRoute(name: String, path: [CLLocationCoordinate2D], seconds: TimeInterval) async {
        await seedRoutes(name: name, variants: [(path, seconds)])
    }

    /// Тестовый хук (40I): несколько вариантов без сети — выбор и ярлыки тем
    /// же `apply`; цель — конец первого.
    func seedRoutes(name: String, variants: [(path: [CLLocationCoordinate2D], seconds: TimeInterval)]) async {
        guard let first = variants.first?.path, !first.isEmpty else { return }
        let built = variants.map { variant -> BuiltVariant in
            let points = variant.path.map(MKMapPoint.init)
            let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let arrive = RouteStep(distanceAlong: length, text: String(localized: "Вы на месте"),
                                   icon: "flag.checkered", kind: .arrive)
            return BuiltVariant(points: points, distance: length, travelTime: variant.seconds, steps: [arrive])
        }
        generation += 1
        await apply(built, name: name, destination: first.last ?? first[0], cameras: [], gen: generation,
                    history: nil, myRoad: nil)
    }
    #endif

    private func resetDetour() {
        detourOffer = nil
        detourVariant = nil
        detourSearchAt = nil
        detourDeclinedAt = nil
        detourUnseenAt = nil
        detourOpenedAt = nil
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
            var bestSegment = 0
            var bestT = 0.0
            for i in 0..<(n - 1) {
                let (closest, t) = closestPoint(mp, pts[i], pts[i + 1])
                let d = mp.distance(to: closest)
                if d < bestMeters {
                    bestMeters = d
                    bestAlong = cum[i] + t * pts[i].distance(to: pts[i + 1])
                    bestSegment = i
                    bestT = t
                }
            }
            if bestMeters <= AppConfig.routeCorridorMeters {
                // За концом линии — не на нашем пути: без этого позади старта
                // прижималась к его точке и звучала как «0 м» (RouteLineEnds).
                if RouteLineEnds.isBeyond(camera, along: bestAlong, points: pts, length: cum[n - 1]) {
                    continue
                }
                // Встречная при доказанно поделённых сторонах — в коридоре, но
                // не наша (27.J); недоказанное — наше, как было.
                let oncoming = RouteCameraDirection.isProvenOncoming(camera, on: pts,
                                                                     segment: bestSegment, t: bestT)
                result.append(RouteCamera(camera: camera, distanceAlong: bestAlong,
                                          provenOncoming: oncoming))
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

    /// Стрелка на линии маршрута: точка `on` (nil — дальше `routeSnapMeters`),
    /// только пока наш курс с линией согласен (`routeSnapMaxCourseDegrees`).
    /// Курс неизвестен (`-1`) — согласие не проверяем: стоим или едем без
    /// доказанного курса, и линия — лучшее, что есть.
    nonisolated static func displaySnap(deviation: CLLocationDistance,
                                        on snap: (coordinate: CLLocationCoordinate2D, course: CLLocationDirection)?,
                                        course: CLLocationDirection)
    -> (coordinate: CLLocationCoordinate2D, course: CLLocationDirection)? {
        guard deviation <= AppConfig.routeSnapMeters, let snap else { return nil }
        if course >= 0, course.isFinite,
           GeoMath.angleDifference(course, snap.course) > AppConfig.routeSnapMaxCourseDegrees {
            return nil
        }
        return snap
    }

    /// Параметры запроса OSRM — `OSRMQuery` (29.E: число альтернатив,
    /// подъезд к цели с её стороны; `legacy` — запрос до 29.E).
    nonisolated static func osrmQueryItems(alternatives: Bool, heading: CLLocationDirection?,
                                           waypoints: Int, legacy: Bool = false) -> [URLQueryItem] {
        OSRMQuery.items(alternatives: alternatives, heading: heading, waypoints: waypoints, legacy: legacy)
    }

    /// Параметры запроса своей дороги (24.4) — `OSRMQuery.viaItems`.
    nonisolated static func osrmQueryItems(heading: CLLocationDirection?, via: [MyRoad.Via],
                                           legacy: Bool = false) -> [URLQueryItem] {
        OSRMQuery.viaItems(heading: heading, via: via, legacy: legacy)
    }

    /// Курс для маршрута, построенного сейчас (20.9): только на ходу (не
    /// медленнее `directionalMinSpeedKmh`) и с достоверным курсом (`course`
    /// ≥ 0 — его выдаёт LocationFilter). Стоя — nil: водитель может поехать в
    /// любую сторону, и маршрут с разворотом там честен; курс, выдержанный у
    /// светофора, его бы отнял.
    nonisolated static func requestHeading(course: CLLocationDirection,
                                           speedKmh: Double) -> CLLocationDirection? {
        guard course >= 0, course.isFinite, speedKmh >= AppConfig.directionalMinSpeedKmh else { return nil }
        return course
    }

    /// Повторять ли запрос по курсу без курса. Сервер ответил отказом —
    /// да (NoSegment: попутной дороги в радиусе нет); запрос не дошёл — нет:
    /// второй ждал бы тот же таймаут.
    nonisolated static func retriesWithoutHeading(after error: Error) -> Bool {
        !isCancellation(error) && error as? RouteError != .noConnection
    }

    /// Запрос оборвали мы сами (сменили цель, «Отмена»), а не сеть.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if case APIClient.Failure.transport(let inner) = error { return isCancellation(inner) }
        return error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Чем считать сбой запроса к OSRM: отмена остаётся отменой, остальное —
    /// «запрос не дошёл». До 76 отмена уходила как `noConnection`.
    nonisolated static func transportFailure(_ error: Error) -> Error {
        isCancellation(error) ? CancellationError() : RouteError.noConnection
    }

    /// Пробовать ли свой граф трасс после сбоя сервера: после отмены — нет;
    /// сервер ответил «пути нет» — граф трасс знает не больше.
    nonisolated static func fallsBackOffline(after error: Error, taskCancelled: Bool) -> Bool {
        !taskCancelled && !isCancellation(error) && error as? RouteError != .noRoute
    }

    /// Ход по линии для RerouteGate (20.9): курс ветки, которую выбрала
    /// проекция (`segment` — её сегмент), против нашего курса.
    nonisolated static func routeHeading(along: CLLocationDistance, segment: Int, pts: [MKMapPoint],
                                         course: CLLocationDirection,
                                         speedKmh: Double) -> RerouteGate.Heading {
        RerouteGate.Heading(along: along,
                            against: RerouteGate.isAgainst(course: course, speedKmh: speedKmh,
                                                           routeCourse: segmentCourse(pts, at: segment)))
    }

    /// Направление сегмента `index` (0–360°) — по сетке MKMapPoint, как у
    /// штрафа встречным сегментам: Меркатор углы сохраняет. Сегмент нулевой
    /// длины (повтор точки) направления не имеет — берём соседний.
    nonisolated static func segmentCourse(_ pts: [MKMapPoint], at index: Int) -> CLLocationDirection? {
        guard index >= 0, index + 1 < pts.count else { return nil }
        if let course = mercatorBearing(pts[index], pts[index + 1]) { return course }
        for i in (index + 1)..<(pts.count - 1) {
            if let course = mercatorBearing(pts[i], pts[i + 1]) { return course }
        }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let course = mercatorBearing(pts[i], pts[i + 1]) { return course }
        }
        return nil
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
        // Назад — от начала сегмента подсказки, вперёд — от его КОНЦА (20.9):
        // машина где-то на нём, и окно вперёд обязано начинаться за ней.
        // От начала сегмент длиннее окна (прямая трассы, 400+ м между
        // узлами) не пускал в окно следующий: за его концом отклонение росло
        // до 200 м, пока не включится полный перебор, — и снос 20.6 (50 м
        // четыре фикса) перестраивал маршрут посреди ровной трассы.
        let anchor = cum[min(max(hint, 0), n - 1)]
        let anchorEnd = cum[min(max(hint, 0) + 1, n - 1)]
        let lo = max(0, lowerBound(cum, anchor - AppConfig.routeProjectBackMeters) - 1)
        let hi = min(n - 1, max(lo + 1,
                                lowerBound(cum, anchorEnd + AppConfig.routeProjectAheadMeters)))
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
        guard course >= 0, let bearing = mercatorBearing(a, b) else { return 0 }
        var diff = abs(bearing - course).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff > 90 ? AppConfig.routeWrongWayPenaltyMeters : 0
    }

    /// Направление A→B по сетке MKMapPoint (0–360°, север — минус y); nil —
    /// точки совпали.
    nonisolated private static func mercatorBearing(_ a: MKMapPoint, _ b: MKMapPoint) -> CLLocationDirection? {
        let dx = b.x - a.x, dy = b.y - a.y
        guard dx != 0 || dy != 0 else { return nil }
        return (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
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
