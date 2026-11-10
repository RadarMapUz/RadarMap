//
//  EngineMapView.swift
//  RadarMap
//
//  Карта, которую рисует ДВИЖОК (MapLibre Native), а не наш холст.
//
//  Зачем. Самописный рендер упёрся не в скорость, а в картографию: ленты
//  разной ширины встык, срезанные торцы, тёмные пятна оболочек перекрёстков,
//  подписи без расстановки, порядок отрисовки, ломающийся на границе тайлов.
//  Всё это движок делает сам, и делает так же, как большие карты, потому что
//  это ровно тот же движок и тот же формат стиля.
//
//  Данные — НАШИ. Те же тайлы, что собирает build_roads.py, только в MVT, и
//  тот же стиль, который уже год работает в панели модератора. Ни одного
//  чужого источника: ни подложки, ни спутника, ни шрифтов из сети.
//
//  Вся обвязка под `canImport(MapLibre)`: пока пакет не добавлен в проект,
//  файл компилируется в пустоту, а экран остаётся на прежней схеме. Это и
//  есть выключатель на случай, если движок не выживет на живом телефоне.
//

#if canImport(MapLibre)
import CoreLocation
import MapLibre
import MapKit
import SwiftUI
import os

private final class EngineNativeMapView: MLNMapView {
    var onLayout: ((MLNMapView) -> Void)?
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != previousSize else { return }
        previousSize = bounds.size
        onLayout?(self)
    }
}

struct EngineMapView: UIViewRepresentable {

    /// Где мы (уже прижатые к оси координаты — те же, что у схемы).
    var coordinate: CLLocationCoordinate2D
    /// Курс, градусы. Отрицательный — курса нет, карту не крутим.
    var courseDegrees: Double
    /// Охват по высоте вида, метры.
    var spanMeters: Double
    var anchorY: Double = MapViewport.meY
    /// Наклон, градусы.
    var pitchDegrees: Double
    var daylight: Bool
    /// Видимость домов. Геометрия уже входит в общий векторный тайл.
    var houses: Bool = false
    /// Камеры окрестности; `alert` — та, о которой сейчас предупреждаем.
    var cameras: [Camera]
    var cameraRevision: Int = 0
    var limitRevision: Int = 0
    /// Камеры области и бюджет выборки: при переполнении — ближайшие к
    /// центру области (CameraRepository.cameras(in:limit:)).
    var cameraProvider: ((MKCoordinateRegion, Int) -> [Camera])?
    var limitProvider: ((Camera) -> Int?)?
    var alertCameraID: Int?
    /// Камеры на нашем пути (CameraMarkerLook): только у них цвет типа.
    var pathCameraIDs: Set<Int> = []
    /// Камеры не на своей координате — на линии маршрута или на оси нашей
    /// дороги (CameraOnLine, 27.B). Только картинка; подпись — там же.
    var cameraPoints: [Int: CameraOnLine.Point] = [:]
    /// Зона камеры на асфальте (CameraZone, 28.B): участок её проезжей части
    /// перед ней у камеры, к которой едем. nil — не рисуем. Только картинка.
    var cameraZone: CameraZone.Band?
    /// Свои камеры — голос о них молчит, на значке галочка.
    var familiarCameraIDs: Set<Int> = []
    /// Свои свежие отметки водителя — без «?» (CameraMarkerLook.isGhost).
    var ownReportIDs: Set<Int> = []
    /// Подпись «400 м» у значка алерт-камеры — только в машине
    /// (CarPlayCameraCue); на телефоне nil, там расстояние в своём HUD.
    var cameraLabel: CarPlayCameraCue.Label?
    var cameraLimits: [Int: Int] = [:]
    var route: [CLLocationCoordinate2D]
    var routeObject: MKPolyline?
    var routeProgress: Double = 0
    var maneuverAlong: Double?
    /// Ряд стрелок полос у ближайшего манёвра (28.C, LaneFocus); nil — полос нет.
    var laneFocus: LaneFocus.Step? = nil
    /// Тип ближайшего манёвра — для стрелки на линии (29.G, ManeuverArrow).
    var maneuverKind: ManeuverKind? = nil
    /// Выноска манёвра на карте (29.G, ManeuverCallout) и экран для неё;
    /// nil — выноски нет (машина: ряд полос — в карточке манёвра системы).
    var maneuverCallout: ManeuverCallout.Content? = nil
    var calloutFrame: ManeuverCallout.Frame? = nil
    var recenterToken: Int = 0
    /// Новая карта: основа OpenMapTiles + наши слои (EngineModernStyle) по
    /// выпуску тайлов. Выключено или выпуска нет — прежний стиль.
    var modernStyle: Bool = false
    /// Тепловой режим и энергосбережение: частота кадров и порог сдвига.
    var performance: PerformanceMode = .full
    var lowPower: Bool = false
    /// Север вверху (режим «следить»); иначе карта крутится по курсу.
    var northUp: Bool = false
    /// Кнопки «+ / −»: счётчик нажатий и шаг — для свободной карты.
    var zoomCommand: Int = 0
    var zoomDelta: Double = 0
    /// Без связи внутри скачанного региона — его локальные файлы.
    var offline: OfflineFiles?
    /// Общие POI на новой карте (тумблер «Места»).
    var places: Bool = true
    /// Режим «в поездке»: без общих POI, номеров домов и подписей дорожек,
    /// дома тише цветом поездки (EngineModernStyle.drivingLayers, map_drive_*).
    var driving: Bool = false
    /// Карту накрыло полноэкранное предупреждение о камере (градиент до 96 %):
    /// рисовать её на полной частоте незачем (аудит 11.10).
    var covered: Bool = false
    /// Метров до следующего манёвра маршрута (nil — нет): у развилки карта
    /// рисует на полной частоте (EngineFrames, 36A).
    var maneuverMeters: Double?
    /// Что показывать сейчас (MapDetailPolicy, 29.H): декор, заведения,
    /// номера домов, заправки и парковки — видимостью слоёв, на смене
    /// решения; вне поездки на телефоне — всё, как было.
    var detail: MapDetailPolicy.Decision = .browse
    /// Наши значки, разрешённые решением (MapDetailPlaces.marks): заправки по
    /// пути, парковки у цели, ближайшие из «По пути».
    var detailMarks: [MapDetailPlaces.Mark] = []
    /// Пунктир от конца маршрута к цели в режиме прибытия; nil — не рисуем.
    var destinationApproach: [CLLocationCoordinate2D]?
    /// Можно ли трогать карту. Плитка главного экрана машины — только для
    /// взгляда: касание по ней открывает приложение, а случайный жест движка
    /// снимал слежение навсегда (у плитки нет «к себе»).
    var interactive: Bool = true
    /// Метка журнала здоровья карты («машина», «плитка»): раз в 10 с (релиз — 30) строка
    /// с состоянием приложения, кадрами, поворотом и камерами. nil — молчим.
    var healthTag: String?
    /// Карта в машине (экран, плитка, приборка): на потолке памяти видимая
    /// не отдаёт ничего (MemoryPressure.release, 40I).
    var inCar: Bool = false
    /// Пробки (TrafficService): линии улиц, сшитые из рёбер (TrafficLines,
    /// 33H). Пишутся в источник только на смене `trafficRevision` — раз в
    /// пару минут, а не на тике.
    var trafficLines: [TrafficLines.Line] = []
    /// Ревизия линий (TrafficService.linesRevision) — живые и «обычно».
    var trafficLinesRevision: Int = 0
    var trafficRevision: Int = 0
    /// Тот же набор пробок с сеткой поиска — для цвета САМОЙ линии маршрута
    /// (RouteTraffic, 25.D). nil — линия одного цвета (Theme.route).
    var trafficSnapshot: TrafficSnapshot?
    /// Язык подписей новой карты («ru» / «uz»). Меняется только с языком
    /// приложения, а тот применяется после перезапуска — перезагрузка стиля
    /// ради него не нужна.
    var labelLanguage: String = "ru"
    /// Значок «я» (настройка «Значок на карте»). Смена — это замена ОДНОЙ
    /// картинки в живом стиле, а не перезагрузка стиля: перезагрузка
    /// сбрасывает слои, маршрут и камеры ради значка в сорок пунктов.
    var cursorStyle: CursorStyle = .arrow
    /// Кольцо компаса N/E/S/W вокруг машины (29.B) — в поездке.
    var compass: Bool = false
    /// Облик кольца: с буквами (телефон) или с меткой севера (машина, 40J).
    var compassLook: CompassRing.Look = .phone
    /// Смена лимита на снижение впереди — знак «200 м · 40» у машины (29.B,
    /// LimitAhead.visual); nil — знака нет. Расстояние карта считает сама.
    var limitAhead: LimitAhead.Notice?
    /// «Весь маршрут»: счётчик нажатий — вписать линию маршрута в экран.
    var overviewCommand: Int = 0
    /// Поля вписывания: на телефоне — под панели сверху и снизу, в машине —
    /// слева под карточку выбора маршрута.
    var overviewPadding = UIEdgeInsets(top: 150, left: 40, bottom: 240, right: 90)
    /// Варианты маршрута на экране выбора (27.D): не выбранные — бледной
    /// линией под выбранной, у каждого — подпись времени; касание выбирает.
    /// Пусто (в ведении, один вариант) — слоёв выбора не видно.
    var variants: [RouteVariantLine] = []
    var selectedVariantID: Int?
    var onSelectVariant: (Int) -> Void = { _ in }
    /// Сдвиг карты командой, а не пальцем: в машине касания до вида не
    /// доходят, панораму присылает шаблон CarPlay (перетаскивание, стрелки
    /// крутилки). Сумма ВСЕХ сдвигов содержимого в точках экрана: карта берёт
    /// разницу с прошлой суммой, поэтому два шага, пришедшие между кадрами,
    /// оба доезжают (последний не затирает первый).
    var panTotal: CGSize = .zero
    /// Флаг цели маршрута и точка долгого тапа (бар действий открыт).
    var destination: CLLocationCoordinate2D?
    var pressedPoint: CLLocationCoordinate2D?
    /// Перекрытия и ремонт (12б.5): точка и вид — «radar-closure»/«radar-roadwork».
    var roadEvents: [RoadEvent] = []
    /// Метан на АГНКС (12б.4): статусы станций — только у машины на метане.
    var cngStations: [CngStation] = []
    /// «Где машина» (ParkedCar): метка машины, пока подсказка показана.
    var parkedCar: CLLocationCoordinate2D?
    /// Зоны «здесь часто ставят треногу»: пустые — слоя нет.
    var hotspots: [CLLocationCoordinate2D] = []
    /// Подпись зоны того же индекса: «чаще вечером» (82); пусто — без подписи.
    var hotspotLabels: [String] = []
    /// Перенести центр в точку (счётчик, как у остальных команд): нужно
    /// крестику постановки камеры, который встаёт на точку долгого тапа.
    var centerCommand: Int = 0
    var centerTarget: CLLocationCoordinate2D?
    var onHeading: (Double) -> Void = { _ in }
    var onBrowse: () -> Void = {}
    var onSelectCamera: (Camera) -> Void = { _ in }
    /// Касание линии пробок (33H): лист «Пробка · 2,4 км · 12 км/ч · +7 мин».
    var onSelectTraffic: (TrafficTap) -> Void = { _ in }
    /// Долгий тап по карте — координата под пальцем.
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    /// Видимая область после каждого движения карты — для крестика
    /// постановки камеры (центр) и зума точек/кластеров.
    var onRegion: (MKCoordinateRegion) -> Void = { _ in }
    /// Каждый шаг жеста пальцем, а не только первый (как `onBrowse`): выбор
    /// точки поднимает булавку, пока карту тянут, и опускает на `onRegion`.
    var onGesture: () -> Void = {}
    /// Куда смотрит следящая камера вместо `coordinate`: выбор места
    /// открывается на сохранённом месте, а стрелка «я» остаётся там, где
    /// человек на самом деле. nil — камера следит за `coordinate`.
    var lookAt: CLLocationCoordinate2D?
    /// Стрелка «я» видна. false — положение неизвестно: стрелка в запасной
    /// точке (центр Ташкента) говорила бы «вы здесь» о чужом месте.
    var showsPosition: Bool = true
    /// Последний фикс для значка «я» (LocationService.markerMotion): скорость,
    /// время и линия маршрута. Стрелка и точка следящей камеры идут по оценке
    /// «где машина сейчас» (MarkerPredictor), а не по фиксу, — иначе значок
    /// всегда на фикс позади. nil или фикс другой точки — без предсказания.
    var markerMotion: MarkerPredictor.Fix?
    /// Плашка улицы (29.F): имя ленты под значком «я» в поездке, только на
    /// смене. nil — карта не спрашивает вовсе (выбор места, плитка).
    var onStreetName: ((String?) -> Void)?
    /// Экран машины и плитка (29.F, 40J): подписи и линия маршрута крупнее
    /// телефонных (EngineCarScale) — раз на загрузку стиля. nil — как в стиле.
    var carScale: CarMapStyle.Scale?
    /// Стиль карты в машине (CarMapStyle, 40J): своя разница стиля, линия
    /// маршрута, слои на ходу, плашка улицы. nil — телефон и приборка.
    var carStyle: CarMapStyle?
    /// «Вождение 3D» (43, Drive3D): светлый тихий мир, лента маршрута во всю
    /// нашу сторону и сужение к полосам у манёвра. nil — выключено (настройка,
    /// вне поездки на телефоне, приборка). Поверх разницы машины: на экране
    /// машины и плитке кладётся разница 3D, масштаб подписей машины остаётся.
    var drive3D: Drive3D.Surface?
    /// Лента маршрута в «Вождении 3D»: false — только палитра (плитка на
    /// горячем телефоне, Drive3D.ribbon(surface:tile:)).
    var drive3DRibbon = true

    func makeUIView(context: Context) -> MLNMapView {
        // Сторож тайлов — ДО первой карты: движок начинает качать сразу, и
        // поставить проверку после значило бы пропустить первые тайлы без неё.
        // Там же — потолок кэша, один раз за процесс (EngineTileGuard.configureCacheOnce).
        EngineTileGuard.install()
        let view = EngineNativeMapView(frame: .zero)
        view.isUserInteractionEnabled = interactive
        // Осмотр не меняет GPS и маршрут; вернуться к слежению можно кнопкой.
        view.isScrollEnabled = true
        view.isZoomEnabled = true
        view.isRotateEnabled = true
        // Наклон двумя пальцами — как у навигаторов, не круче потолка поездки
        // (58°, AppConfig.engineMapPitchDegrees: там же — про #3029).
        view.isPitchEnabled = true
        view.maximumPitch = AppConfig.engineMapPitchDegrees
        view.compassView.isHidden = true
        view.logoView.isHidden = true
        // Своя кнопка движка («ⓘ») не показывается: подпись данных рисует
        // MapAttribution поверх карты — пять секунд при показе, затем тает
        // (правила OSMF это разрешают), а лицензия — в настройках.
        view.attributionButton.isHidden = true
        view.delegate = context.coordinator
        let selection = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.selectCamera(_:)))
        for tap in (view.gestureRecognizers ?? []).compactMap({ $0 as? UITapGestureRecognizer })
            where tap.numberOfTapsRequired > 1 {
            selection.require(toFail: tap)
        }
        view.addGestureRecognizer(selection)
        let hold = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.longPress(_:)))
        hold.minimumPressDuration = AppConfig.mapLongPressSeconds
        view.addGestureRecognizer(hold)
        context.coordinator.view = view
        #if DEBUG
        // Касание без пальца для снимков 27.D: `-tapVariant <id>` — по подписи
        // варианта, `-tapMapAt x,y` — в точку вида; через `-tapAfter N` секунд.
        // Идёт тем же путём, что настоящее касание (handleTap).
        if interactive { context.coordinator.scheduleDebugTap() }
        #endif
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator, let model = coordinator.current else { return }
            coordinator.lastCameraModel = nil
            coordinator.apply(model, to: view)
        }
        // Система предупреждает о памяти ПЕРЕД тем, как убить приложение;
        // до сих пор это предупреждение не слушал никто (см. MemoryPressure).
        // С 36A — ещё уход телефона в фон с поездкой и потолок следа.
        MemoryPressure.onTrim(context.coordinator) { $0.releaseMemory($1) }
        // Стиль сразу (живые слои рисуются и без тайлов), а подписанный
        // индекс нужного стиля догружается и перезагружает стиль сам —
        // в обход сторожа тайлы не грузятся никогда (prepareTiles).
        context.coordinator.loadStyle(self, in: view)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.apply(self, to: view)
    }

    static func dismantleUIView(_ view: MLNMapView, coordinator: Coordinator) {
        coordinator.routeLine.cancel()
        coordinator.driveRibbon.release()
        coordinator.stopMarkerLink()
        view.delegate = nil
        (view as? EngineNativeMapView)?.onLayout = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей:
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor изолирует КАЖДЫЙ класс, а не
    /// только помеченный @MainActor, и синтезированный isolated deinit ведёт
    /// в свободу указателя, который никто не выделял (см. MapState).
    nonisolated deinit {}
        weak var view: MLNMapView?
        private var cameraPlaced = false
        private var styleReady = false
        private var lastDaylight: Bool?
        private var lastHouses: Bool?
        private var lastPlaces: Bool?
        private var lastOffline: OfflineFiles?
        private var themeLayers: [[String: Any]] = []
        private var lastCameras: [Camera]?
        private var lastLimits: [Int: Int] = [:]
        private var lastAlertID: Int?
        private var lastPathIDs: Set<Int> = []
        private var lastCameraPoints: [Int: CameraOnLine.Point] = [:]
        private var lastFamiliarIDs: Set<Int> = []
        private var lastOwnReportIDs: Set<Int> = []
        /// Тема, в которой собраны точки камер (графит спокойных — свой днём и ночью).
        private var camerasDaylight: Bool?
        /// Линия маршрута и срез пройденного под значком (27.A).
        fileprivate let routeLine = EngineRouteLine()
        /// «Нужная полоса» на асфальте у манёвра (28.C).
        private let laneFocusLayers = EngineLaneFocus()
        /// Зона камеры на асфальте (28.B).
        private let cameraZone = EngineCameraZone()
        /// Стрелка манёвра на линии и выноска у точки манёвра (29.G).
        private let maneuverArrow = EngineManeuverArrow()
        private let maneuverCallout = EngineManeuverCallout()
        /// Асфальт поездки и тема линии маршрута (29.B).
        private let driveAsphalt = EngineDriveAsphalt()
        /// Лента маршрута «Вождения 3D» (43).
        fileprivate let driveRibbon = EngineDriveRibbon()
        /// Кольцо компаса и знак лимита у машины (29.B).
        private let carDecor = EngineCarDecor()
        /// Значки «нужного сейчас» и цель в режиме прибытия (29.H).
        private let mapDetail = EngineMapDetail()
        /// Дымка у горизонта наклонной карты и имя улицы под значком (29.F).
        private let haze = EngineHorizonHaze()
        private let streetProbe = EngineStreetProbe()
        private var positionHeading = 0.0
        /// Значок между фиксами: где машина СЕЙЧАС (MarkerPredictor). До 21.10
        /// стрелка плыла к последнему фиксу за интервал между фиксами и всегда
        /// была на фикс позади («машина опаздывает»). Такт кадров — только
        /// пока значок движется; камера едет к оценке на момент конца своего хода.
        private var markerLink: CADisplayLink?
        private var predictor = MarkerPredictor()
        /// Последний фикс, отданный предсказателю.
        private var fedFix: MarkerPredictor.Fix?
        /// Когда пришёл последний фикс и сколько было между двумя последними
        /// (часы CACurrentMediaTime): камера едет до ожидаемого следующего.
        private var fixArrival: CFTimeInterval = 0
        private var fixGap: CFTimeInterval = AppConfig.engineCameraDuration
        /// Курс модели, по которому стрелка повёрнута на последнем фиксе.
        private var lastMarkerCourse: Double?
        private var cameraWindow: EngineMapPresentation.CameraWindow?
        private var cachedCameras: [Camera] = []
        private var cachedLimits: [Int: Int] = [:]
        private var cameraRevision = -1
        private var limitRevision = -1
        private var lastFollowTime: CFTimeInterval?
        private static var iconCache: [String: UIImage] = [:]
        /// Битмапы курсора — по значку: выбор в настройках меняет картинку в
        /// стиле, а не рисует её заново на каждой перезагрузке стиля.
        private static var cursorCache: [CursorStyle: UIImage] = [:]
        /// Какой значок сейчас лежит в стиле под именем "radar-user".
        private var lastCursor: CursorStyle?
        private let performanceLog = OSLog(subsystem: "uz.radarmap", category: "MapPerformance")
        fileprivate var lastCameraModel: EngineMapView?
        private var browsing = false
        /// Наклон из модели на прошлом обновлении (см. наклон на свободной карте).
        private var lastModelPitch: Double?
        /// Последний кадр нарисован со всеми тайлами — лента 3D может щупать карту.
        private var framesComplete = false
        private var lastRecenterToken = 0
        /// Выпуск тайлов новой карты (подписанный корень) и что сейчас в стиле.
        private var release: TileRelease?
        private var lastModern: Bool?
        private var modernLoaded = false
        private var preparing = false
        private var attemptedModern = false
        private var attemptedLegacy = false
        /// Стиль новой карты не собрался (битый ресурс): до конца жизни экрана
        /// работаем как прежняя карта — со своим индексом, а не пустой.
        private var modernBroken = false
        private var lastFPS: Int?
        /// Ровный ход (EngineFrames.Pace, 36A): решение о частоте в поездке.
        private var pace = EngineFrames.Pace()
        private var steady = false
        /// Почему ход не ровный (журнал смены частоты, 36A).
        private var paceReason = ""
        private var lastBusyStep: EngineFrames.CameraStep?
        /// Кадров движка на текущей частоте и с какого момента (журнал 36A).
        private var framesAtRate = 0
        private var rateSince: CFTimeInterval = 0
        /// Последний шаг следящей камеры заметно менял картинку (поворот,
        /// масштаб, наклон) — держится до следующего шага.
        private var cameraBusy = false
        /// Что отдали движку прошлым шагом камеры: масштаб, наклон, поворот, когда.
        private var lastStep: (zoom: Double, pitch: Double, heading: Double, at: CFTimeInterval)?
        /// Режим карты и когда он сменился (первые секунды — полная частота).
        private var modeKey: ModeKey?
        private var modeChangedAt: CFTimeInterval = 0
        private var lastZoomCommand = 0
        private var lastOverviewCommand = 0
        /// Варианты маршрута на экране выбора (27.D).
        private let routeVariants = EngineRouteVariants()
        /// Кадр «весь маршрут» держится, пока человек не тронул карту: меняются
        /// поля (карточка выбора выросла, строка «почему» в две строки), набор
        /// вариантов или выбор — кадр плавно переезжает (RoutePreview.fit).
        private var overviewHeld = false
        private var overviewKey: [Double] = []
        /// До какого момента идёт вход в ведение (CACurrentMediaTime): одна
        /// плавная дуга от обзора к машине вместо двух рывков.
        private var entryUntil: CFTimeInterval = 0
        private var lastPanTotal = CGSize.zero
        /// Первое применение модели запоминает счётчики, но не исполняет их:
        /// иначе повторный монтаж карты вписывал бы маршрут сам по старому нажатию.
        private var commandsSeen = false

        /// Частота таймера кадров движка по модели, покою карты и ровному
        /// ходу (EngineFrames, 36A).
        private func applyFramesPerSecond(_ model: EngineMapView, in view: MLNMapView) {
            let fps = EngineFrames.framesPerSecond(EngineFrames.Situation(
                browsing: browsing, settled: settled, covered: model.covered,
                performance: model.performance, lowPower: model.lowPower,
                driving: model.driving, steady: steady))
            guard fps != lastFPS else { return }
            // Только на смене (несколько раз в минуту): журнал замера 36A —
            // сколько кадров движок на деле нарисовал на прежней частоте и
            // что подняло частоту (debug: в журнал не пишется, пока не смотрят).
            let now = CACurrentMediaTime()
            let step = paceReason == "камера" ? lastBusyStep : nil
            Log.app.debug("карта \(model.healthTag ?? "телефон", privacy: .public): кадров/с \(self.lastFPS ?? -1, privacy: .public) → \(fps, privacy: .public) [\(self.paceReason, privacy: .public)\(step.map { String(format: " масштаб %.2f наклон %.1f° поворот %.1f° за %.2f с", $0.zoom, $0.pitch, $0.heading, $0.seconds) } ?? "", privacy: .public)], нарисовано \(self.framesAtRate, privacy: .public) за \(now - self.rateSince, format: .fixed(precision: 1), privacy: .public) с")
            framesAtRate = 0
            rateSince = now
            lastFPS = fps
            view.preferredFramesPerSecond = fps > 0
                ? MLNMapViewPreferredFramesPerSecond(rawValue: fps)
                : .default
            syncMarkerLink()
        }

        /// Режим карты: его смена — первые секунды на полной частоте.
        struct ModeKey: Equatable {
            var driving: Bool
            var browsing: Bool
            var covered: Bool
            var northUp: Bool
            var route: Bool
            var lookAt: Bool
        }

        /// Ровный ли ход сейчас (EngineFrames.Pace): пишется на каждом
        /// применении модели, читается частотой кадров.
        private func updatePace(_ model: EngineMapView, now: CFTimeInterval) {
            let key = ModeKey(driving: model.driving, browsing: browsing, covered: model.covered,
                              northUp: model.northUp, route: !model.route.isEmpty, lookAt: model.lookAt != nil)
            if key != modeKey {
                if modeKey != nil { modeChangedAt = now }
                modeKey = key
            }
            let signals = EngineFrames.Signals(
                cameraBusy: cameraBusy, maneuverMeters: model.maneuverMeters,
                speedMps: model.markerMotion?.speedMps ?? 0,
                sinceModeChange: modeChangedAt > 0 ? now - modeChangedAt : nil,
                entering: entryUntil > now)
            let busy = !model.driving || EngineFrames.busy(signals)
            steady = pace.steady(busy: busy, now: now)
            paceReason = !model.driving ? "не поездка"
                : signals.cameraBusy ? "камера"
                : signals.entering ? "вход"
                : (signals.sinceModeChange ?? .infinity) < AppConfig.engineSteadyModeSeconds ? "режим"
                : busy ? "манёвр"
                : steady ? "ровно" : "выдержка"
        }

        /// Шаг следящей камеры: заметно ли он меняет картинку.
        private func noteCameraStep(zoom: Double, pitch: Double, heading: Double, at now: CFTimeInterval) {
            if let last = lastStep {
                let step = EngineFrames.CameraStep(
                    zoom: zoom - last.zoom, pitch: pitch - last.pitch,
                    heading: GeoMath.angleDifference(last.heading, heading), seconds: now - last.at)
                cameraBusy = EngineFrames.cameraBusy(step)
                if cameraBusy { lastBusyStep = step }
            }
            lastStep = (zoom, pitch, heading, now)
        }

        /// Карта дорисована и стоит. Таймер кадров MapLibre при этом не
        /// останавливается (6.29: такт идёт, кадров ноль) — редкий такт вместо
        /// 30 пробуждений в секунду (AppConfig.engineSettledFPS).
        private var settled = false

        private func settle(_ mapView: MLNMapView) {
            guard !settled, let current else { return }
            settled = true
            applyFramesPerSecond(current, in: mapView)
        }

        /// Камера тронулась (ведение, жест, команда) или движок начал кадр
        /// (тайлы, источники) — обычная частота сразу.
        private func wake(_ mapView: MLNMapView) {
            guard settled else { return }
            settled = false
            if let current { applyFramesPerSecond(current, in: mapView) }
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            #if DEBUG
            reportRendering()
            #endif
            settle(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
            wake(mapView)
        }

        func mapViewWillStartRenderingFrame(_ mapView: MLNMapView) {
            wake(mapView)
        }

        // MapLibre invokes this for every native camera gesture, including tap zoom.
        func mapView(_ mapView: MLNMapView, shouldChangeFrom oldCamera: MLNMapCamera,
                     to newCamera: MLNMapCamera) -> Bool {
            wake(mapView)
            if !browsing {
                browsing = true
                current?.onBrowse()
            }
            overviewHeld = false
            entryUntil = 0
            current?.onGesture()
            return true
        }

        /// Каждый кадр движения камеры (ведение, жест, вписывание): стрелка —
        /// вид поверх карты, и её экранную точку пересчитываем сами.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            layoutPositionView(in: mapView)
            haze.update(pitchDegrees: mapView.camera.pitch, daylight: current?.daylight ?? true,
                        hidden: hazeHidden(current), in: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            layoutPositionView(in: mapView)
            haze.update(pitchDegrees: mapView.camera.pitch, daylight: current?.daylight ?? true,
                        hidden: hazeHidden(current), in: mapView)
            if let current, styleReady { updateCameras(current, in: mapView) }
            // Масштаб меняет видимый ранг стрелок — и порог фильтра за срезом.
            if styleReady { routeLine.regionChanged(in: mapView) }
            current?.onHeading(mapView.direction)
            current?.onRegion(Self.region(of: mapView))
        }

        static func region(of view: MLNMapView) -> MKCoordinateRegion {
            let bounds = view.visibleCoordinateBounds
            return MKCoordinateRegion(center: CLLocationCoordinate2D(
                latitude: (bounds.ne.latitude + bounds.sw.latitude) / 2,
                longitude: (bounds.ne.longitude + bounds.sw.longitude) / 2), span: MKCoordinateSpan(
                latitudeDelta: abs(bounds.ne.latitude - bounds.sw.latitude),
                longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude)))
        }

        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view, let current else { return }
            let point = gesture.location(in: view)
            current.onLongPress(view.convert(point, toCoordinateFrom: view))
        }

        /// Кадр нарисован — счётчик для журнала здоровья (одно сложение на кадр).
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool,
                                           frameEncodingTime: Double, frameRenderingTime: Double) {
            framesRendered &+= 1
            framesAtRate &+= 1
            framesComplete = fullyRendered
            #if DEBUG
            guard frameEncodingTime.isFinite, frameRenderingTime.isFinite else { return }
            encodingSamples.append(frameEncodingTime)
            renderingSamples.append(frameRenderingTime)
            if encodingSamples.count >= AppConfig.engineMetricsSampleCount { reportRendering() }
            #endif
        }

        #if DEBUG
        private var encodingSamples: [Double] = []
        private var renderingSamples: [Double] = []

        private func reportRendering() {
            guard !encodingSamples.isEmpty else { return }
            let encode = encodingSamples.sorted(), render = renderingSamples.sorted()
            let p95 = min(encode.count - 1, Int(Double(encode.count) * 0.95))
            os_log("Map frames=%d encoding_p95_ms=%.2f rendering_p95_ms=%.2f",
                   log: performanceLog, type: .info, encode.count, encode[p95], render[p95])
            encodingSamples.removeAll(keepingCapacity: true)
            renderingSamples.removeAll(keepingCapacity: true)
        }
        #endif

        /// Курсор «я» — картинка вида-стрелки поверх карты (см. «Стрелка»).
        private func installCursor(_ cursor: CursorStyle) {
            lastCursor = cursor
            // Новый значок — поставить заново, а «Машине 3D» — выбрать кадр.
            shownCarFrame = nil
            shownPosition = nil
            guard let image = Self.cursorImage(cursor) else {
                Log.network.error("MapLibre: курсор \(cursor.rawValue, privacy: .public) не отрисовался")
                return
            }
            positionView?.image = image
            positionView?.bounds = CGRect(origin: .zero, size: image.size)
        }

        /// Тот же MeCursor, что у схемы и карты Apple, — растром ×3. Рамка та
        /// же, что была у стрелки: значки вписаны в неё сами, а поля — под тень.
        private static func cursorImage(_ cursor: CursorStyle) -> UIImage? {
            if let cached = cursorCache[cursor] { return cached }
            let frame = cursor.frameSize
            let renderer = ImageRenderer(content: MeCursor(scale: 1, style: cursor)
                .frame(width: frame.width, height: frame.height).padding(8))
            renderer.scale = 3
            let image = renderer.uiImage
            cursorCache[cursor] = image
            return image
        }

        /// Пометка поверх значка: «?» у отметки водителей, галочка у своей.
        private static func badgeIcon(fill: UInt32, text: String?) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
                let disc = CGRect(x: 0.75, y: 0.75, width: 14.5, height: 14.5)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: disc).fill()
                Theme.rgb(fill).setFill()
                UIBezierPath(ovalIn: disc.insetBy(dx: 1.5, dy: 1.5)).fill()
                if let text {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: UIColor.white]
                    let size = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(at: CGPoint(x: 8 - size.width / 2, y: 8 - size.height / 2),
                                            withAttributes: attributes)
                } else {
                    let check = UIBezierPath()
                    check.move(to: CGPoint(x: 4.8, y: 8.2))
                    check.addLine(to: CGPoint(x: 7.0, y: 10.4))
                    check.addLine(to: CGPoint(x: 11.3, y: 5.8))
                    check.lineWidth = 1.9
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    UIColor.white.setStroke()
                    check.stroke()
                }
            }
        }

        /// Стрелка направления вдоль линии маршрута: шеврон носом вправо
        /// (движок сам кладёт ось картинки вдоль линии), белый с каймой цвета
        /// каймы линии — читается и на синем теле, и на янтаре/красном пробки,
        /// и на светлой середине. 16×14 pt; размер по масштабу — в стиле.
        static func routeArrowIcon(rim: UInt32) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 14)).image { _ in
                let chevron = UIBezierPath()
                chevron.move(to: CGPoint(x: 4.5, y: 2.5))
                chevron.addLine(to: CGPoint(x: 11.5, y: 7))
                chevron.addLine(to: CGPoint(x: 4.5, y: 11.5))
                chevron.lineCapStyle = .round
                chevron.lineJoinStyle = .round
                chevron.lineWidth = 4.8
                Theme.rgb(rim).setStroke()
                chevron.stroke()
                chevron.lineWidth = 2.8
                Theme.rgb(RouteColors.arrow).setStroke()
                chevron.stroke()
            }
        }

        /// Указатель направления пробки (33H, «у них с указателями»):
        /// наконечник стрелы острием по ходу (+x — вдоль линии при
        /// symbol-placement line), как у Яндекса — вдвое шире линии
        /// (`trafficArrowScale`), светлее её и с тёмным контуром: читается и
        /// поверх линии, и рядом с асфальтом. Сдвиг к правой стороне — В САМОМ
        /// РАСТРЕ: растр выше наконечника, и наконечник нарисован ниже середины
        /// на долю, равную сдвигу линии, — при любом icon-size он ложится ровно
        /// на сдвинутую линию (icon-offset у линейной раскладки вёл себя иначе,
        /// чем line-offset, и знак съезжал на край линии).
        static func trafficChevronIcon(level: Int, daylight: Bool, usual: Bool = false) -> UIImage {
            let side = EngineMapStyle.trafficChevronSide
            // Наконечник — `trafficArrowScale` толщин своей линии; сдвиг — от
            // живой линии, поэтому у «обычно» (линия тоньше) он больше.
            let share = usual ? TrafficPalette.usualWidthShare : 1
            let lift = side * EngineMapStyle.trafficOffsetShare / (EngineMapStyle.trafficArrowScale * share)
            let height = side + 2 * lift
            let pair = usual ? TrafficPalette.usual(TrafficPalette.level(level)) : TrafficPalette.level(level)
            let look = TrafficPalette.arrow(on: daylight ? pair.day : pair.night, daylight: daylight)
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: height)).image { _ in
                let top = lift * 2
                let head = UIBezierPath()
                head.move(to: CGPoint(x: side * 0.16, y: top + side * 0.1))
                head.addLine(to: CGPoint(x: side * 0.9, y: top + side * 0.5))
                head.addLine(to: CGPoint(x: side * 0.16, y: top + side * 0.9))
                head.addLine(to: CGPoint(x: side * 0.36, y: top + side * 0.5))
                head.close()
                head.lineJoinStyle = .round
                head.lineWidth = side * 0.09
                Theme.rgb(look.rim).withAlphaComponent(look.rimAlpha).setStroke()
                head.stroke()
                Theme.rgb(look.fill).setFill()
                head.fill()
            }
        }

        /// Значок светофора: капсула 10×20 pt, графит с белой кромкой, три точки.
        static func trafficLightIcon() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20)).image { _ in
                let shell = UIBezierPath(roundedRect: CGRect(x: 0.75, y: 0.75, width: 8.5, height: 18.5),
                                         cornerRadius: 4.25)
                UIColor(red: 0.23, green: 0.25, blue: 0.28, alpha: 1).setFill()
                shell.fill()
                UIColor.white.withAlphaComponent(0.9).setStroke()
                shell.lineWidth = 1.2
                shell.stroke()
                UIColor(red: 0.85, green: 0.87, blue: 0.90, alpha: 1).setFill()
                for y in [3.6, 8.3, 13.0] {
                    UIBezierPath(ovalIn: CGRect(x: 3.2, y: y, width: 3.6, height: 3.6)).fill()
                }
            }
        }

        /// Значки, что кладутся в стиль: по одному на глиф — у всех камер один
        /// (29.C2), свои у поста ДПС, ДТП и «прочего».
        static let markerGlyphs = CameraGlyph.allCases

        /// Имена картинок камер в стиле — всё, что может назвать точка камеры
        /// (cameraAttributes → CameraMarkerLook.icon/badge). Имени, которого
        /// нет в стиле, движок не рисует вовсе — молча (EngineCameraMarkersTests).
        static var cameraImageNames: [String] {
            markerGlyphs.flatMap { glyph in
                CameraMarkerLook.rasters.map { CameraMarkerLook.imageBase(glyph) + $0.suffix }
            }
                + [CameraMarkerLook.ghostBadge, CameraMarkerLook.ownBadge]
        }

        private func installCameraIcons(in style: MLNStyle) {
            installCursor(current?.cursorStyle ?? .arrow)
            if !Self.iconCache.isEmpty {
                for (name, image) in Self.iconCache { style.setImage(image, forName: name) }
                return
            }
            // Значок «Монета» (29.C, CameraIconArt) в обликах «Спокойной карты»
            // (вариант B, владелец, 12.10; CameraMarkerLook): красный — только
            // у камер на нашем пути и у тревоги, остальные — графитовый круг
            // поменьше; пост ДПС и ДТП отличаются глифом. Все типы камер — один
            // значок (29.C2). Цвет запекается в пиксели: движок не применяет к
            // картинке стиля template-режим UIKit. Ореол тревоги — слой camera-halo.
            for glyph in Self.markerGlyphs {
                for look in CameraMarkerLook.rasters {
                    style.setImage(CameraIconArt.marker(glyph, look: look),
                                   forName: CameraMarkerLook.imageBase(glyph) + look.suffix)
                }
            }
            style.setImage(Self.badgeIcon(fill: 0x46525E, text: "?"), forName: CameraMarkerLook.ghostBadge)
            style.setImage(Self.badgeIcon(fill: 0x177A41, text: nil), forName: CameraMarkerLook.ownBadge)
            // Светофор — минималистично (владелец, 12.10: «красиво, по-другому,
            // задевает камеры»): маленькая графитовая капсула с тремя светлыми
            // точками, без красно-жёлто-зелёных огней — фазу тайл всё равно не
            // знает, а цветные огни спорили с красным значком камеры. Этим же
            // значком рисует светофоры и новая карта: её слой получает своё имя
            // при сборке стиля (EngineModernStyle.ownTrafficLight) — спрайт
            // выпуска, пришедший позже, его не перебьёт. make_arrows.py рисует
            // ту же форму для спрайта; прежний стиль берёт «radar-signal».
            let signal = Self.trafficLightIcon()
            style.setImage(signal, forName: "radar-signal")
            style.setImage(signal, forName: EngineModernStyle.trafficLightImage)
            let stop = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
                UIImage(systemName: "octagon.fill")?.withTintColor(
                    UIColor(red: 0.64, green: 0.23, blue: 0.22, alpha: 1), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 1, y: 1, width: 24, height: 24))
                ("STOP" as NSString).draw(at: CGPoint(x: 3, y: 9), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: UIColor.white])
            }
            style.setImage(stop, forName: "radar-stop")
            // Флаг цели и точка долгого тапа — те же, что были на карте Apple:
            // акцентный диск с белым кольцом и булавка.
            let flag = UIGraphicsImageRenderer(size: CGSize(width: 34, height: 34)).image { _ in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 32, height: 32)).fill()
                Theme.rgb(0x2563D9).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 28, height: 28)).fill()
                UIImage(systemName: "flag.checkered",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(at: CGPoint(x: 8, y: 9))
            }
            style.setImage(flag, forName: "radar-flag")
            let pin = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
                UIImage(systemName: "mappin.circle.fill",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .bold))?
                    .withTintColor(Theme.rgb(0x2563D9), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 2, y: 2, width: 28, height: 28))
            }
            style.setImage(pin, forName: "radar-pin")
            // Перекрытие и ремонт: диск своего цвета с белым знаком и белым
            // кольцом — как маркер, но не красный (красный — камера).
            for (name, symbol, hex) in [("radar-closure", "nosign", UInt32(0xC2410C)),
                                        ("radar-roadwork", "cone.fill", UInt32(0x9C5300))] {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
                    UIColor.white.setFill()
                    UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 28, height: 28)).fill()
                    Theme.rgb(hex).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24)).fill()
                    if let glyph = UIImage(systemName: symbol,
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                        .withTintColor(.white, renderingMode: .alwaysOriginal) {
                        glyph.draw(at: CGPoint(x: 15 - glyph.size.width / 2, y: 15 - glyph.size.height / 2))
                    }
                }
                style.setImage(image, forName: name)
            }
            // Машина — синий диск с белой машиной и белым кольцом, как флаг
            // цели: «P» спутали бы с парковками карты (их значок — тоже «P»).
            let parked = UIGraphicsImageRenderer(size: CGSize(width: 34, height: 34)).image { _ in
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 32, height: 32)).fill()
                Theme.rgb(0x2563D9).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 28, height: 28)).fill()
                if let car = UIImage(systemName: "car.fill",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    car.draw(at: CGPoint(x: 17 - car.size.width / 2, y: 17 - car.size.height / 2))
                }
            }
            style.setImage(parked, forName: "radar-parked")
            // Стрелки вдоль линии маршрута: обе темы — имя выбирает стиль.
            for daylight in [true, false] {
                style.setImage(Self.routeArrowIcon(rim: daylight ? RouteColors.casing.day : RouteColors.casing.night),
                               forName: EngineMapStyle.routeArrowImage(daylight: daylight))
            }
            for place in EnginePlaceIcons.all { style.setImage(place.image, forName: place.name) }
            // Шевроны пробок (33H): по уровню, теме и источнику — цвет от линии.
            let chevrons = [true, false].flatMap { daylight in
                [false, true].flatMap { usual in
                    (1...4).map { level -> String in
                        let name = EngineMapStyle.trafficChevronImage(level: level, daylight: daylight, usual: usual)
                        style.setImage(Self.trafficChevronIcon(level: level, daylight: daylight, usual: usual),
                                       forName: name)
                        return name
                    }
                }
            }
            let names = chevrons + ["radar-signal", EngineModernStyle.trafficLightImage, "radar-stop", "radar-flag",
                         "radar-pin", "radar-parked", "radar-closure", "radar-roadwork",
                         EngineMapStyle.routeArrowImage(daylight: true), EngineMapStyle.routeArrowImage(daylight: false)]
                + EnginePlaceIcons.all.map(\.name)
                + Self.cameraImageNames
            for name in names { Self.iconCache[name] = style.image(forName: name) }
        }

        /// Уборка по просьбе системы. Освобождается только то, что строится
        /// заново из живых данных: выборка камер видимой области и разобранные
        /// слои темы. Ни стиль, ни подписанный индекс, ни окно слежения за
        /// камерами не трогаются — от них зависит предупреждение.
        ///
        /// Тайлы движка (36A): кэш тайлов в памяти (виденные, но не на
        /// экране) — это мегабайты разобранной геометрии, которые движок
        /// поднимет заново из своей базы на диске, без сети и без сторожа
        /// (тайл в базе уже прошёл sha256 при скачивании). Отдаём его на
        /// потолке и когда наша карта не видна; на системное предупреждение
        /// движок отвечает сам (MLNMapView слушает то же уведомление).
        func releaseMemory(_ reason: MemoryPressure.Reason) {
            // Карта на экране машины — на виду: ни на уход телефона в фон, ни
            // на потолок ей ничего не отдаём, она едет (MemoryPressure.release).
            let release = MemoryPressure.release(reason, hidden: isHidden, inCar: current?.inCar ?? false)
            guard release != .nothing else { return }
            cachedCameras = []
            cachedLimits = [:]
            cameraWindow = nil          // следующий кадр соберёт выборку заново
            themeLayers = []            // перечитается из EngineMapStyle при смене темы
            // Корзины индекса выпуска поднимутся с диска, не с сети.
            Task { await TileReleaseStore.shared.releaseMemory() }
            if release == .selectionAndEngine, let view { Self.trimEngine(view) }
        }

        /// Карту не видно: окна нет или её сцена в фоне.
        private var isHidden: Bool {
            guard let scene = view?.window?.windowScene else { return true }
            return scene.activationState == .background
        }

        /// Попросить движок отдать кэш тайлов и неиспользуемые ресурсы GPU —
        /// тот же путь, которым MLNMapView отвечает на предупреждение системы
        /// (`didReceiveMemoryWarning` → reduceMemoryUse). Публичного вызова у
        /// 6.29 нет; селектор проверяется, как KVC в строке здоровья.
        static func trimEngine(_ view: MLNMapView) {
            let selector = NSSelectorFromString("didReceiveMemoryWarning")
            guard view.responds(to: selector) else {
                Log.app.error("карта: у движка нет didReceiveMemoryWarning — кэш тайлов не отдан")
                return
            }
            view.perform(selector)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            Log.network.info("MapLibre: стиль загружен")
            installCameraIcons(in: style)
            routeVariants.styleLoaded()
            lastCameras = nil
            routeLine.styleLoaded()
            laneFocusLayers.styleLoaded()
            cameraZone.styleLoaded()
            driveAsphalt.styleLoaded()
            driveRibbon.styleLoaded()
            framesComplete = false
            mapDetail.styleLoaded()
            streetProbe.styleLoaded()
            if let scale = (pending ?? current)?.carScale { EngineCarScale.apply(scale, in: style) }
            EngineLaneArrowsOrder.raise(in: style)
            stopDetail.styleLoaded(style)
            maneuverArrow.styleLoaded()
            hiddenLayers = nil
            hotShown = nil
            modernDrivingLayerIDs = nil
            lastTrafficRevision = -1
            // Источники нового стиля пусты: флаг цели, машина, треноги и
            // события дороги — заново (до этого после смены дня и ночи они
            // пропадали, пока что-то в них не менялось).
            lastMarksKey = []
            lastHotspotsKey = -1
            shownCameraLabel = nil
            cameraLabelWritten = false
            lastRoadEventsKey = -1
            lastCngKey = -1
            cngImageNames = []
            fedFix = nil
            cameraWindow = nil
            style.layer(withIdentifier: "houses")?.isVisible = current?.houses ?? false
            styleReady = true
            // Последняя модель — заново, даже если ждущей нет. Стиль грузится
            // ДВАЖДЫ (сразу — без индекса, потом — с подписанным набором), и
            // после второй загрузки камеры, маршрут и пробки в новом стиле
            // пусты, а `pending` уже снят первой. Пока SwiftUI не пришлёт
            // следующее обновление, карта стояла пустой — у стоящей машины и
            // на плитке панели (ни фиксов, ни касаний) это навсегда: «камер
            // нет» (CarPlay, 12.10). То же после смены дня/ночи и старта
            // поездки на стоянке.
            (pending ?? current).map { apply($0, to: mapView) }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Log.network.error("MapLibre: ошибка загрузки: \(error.localizedDescription, privacy: .public)")
        }

        private var pending: EngineMapView?
        fileprivate var current: EngineMapView?

        @objc func selectCamera(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view else { return }
            handleTap(at: gesture.location(in: view))
        }

        /// Касание карты: камера под пальцем, иначе вариант маршрута (27.D).
        func handleTap(at point: CGPoint) {
            guard let view, let current else { return }
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = view.visibleFeatures(in: rect, styleLayerIdentifiers: ["camera-dot", "camera-icons"])
            let ids = Set(features.compactMap { ($0.attribute(forKey: "id") as? NSNumber)?.intValue })
            let nearest = cachedCameras.filter { ids.contains($0.id) }.min { a, b in
                let pa = view.convert(a.coordinate, toPointTo: view)
                let pb = view.convert(b.coordinate, toPointTo: view)
                return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
            }
            if let nearest {
                current.onSelectCamera(nearest)
            } else if let id = routeVariants.variant(at: point, in: view), id != current.selectedVariantID {
                // Касание линии или подписи другого варианта — выбор (27.D).
                current.onSelectVariant(id)
            } else if let tap = trafficTap(at: point, in: view) {
                // Линия пробок под пальцем — лист о ней (33H). Камера и вариант
                // маршрута главнее: они проверены выше.
                current.onSelectTraffic(tap)
            }
        }

        /// Ближайшая к пальцу линия пробок в квадрате касания (44 pt).
        private func trafficTap(at point: CGPoint, in view: MLNMapView) -> TrafficTap? {
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = view.visibleFeatures(in: rect, styleLayerIdentifiers: [EngineMapStyle.trafficLayerIDs.line])
            let nearest = features.compactMap { $0 as? MLNPolylineFeature }.min { a, b in
                Self.distance(from: point, to: a, in: view) < Self.distance(from: point, to: b, in: view)
            }
            return nearest.flatMap { TrafficTap(attributes: $0.attributes) }
        }

        /// Расстояние на экране от точки до ломаной, pt.
        private static func distance(from point: CGPoint, to line: MLNPolylineFeature, in view: MLNMapView) -> CGFloat {
            let count = Int(line.pointCount)
            guard count > 0 else { return .infinity }
            var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: count)
            line.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
            let points = coordinates.map { view.convert($0, toPointTo: view) }
            var best = CGFloat.infinity
            for (a, b) in zip(points, points.dropFirst()) {
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / len2)) : 0
                best = min(best, hypot(a.x + dx * t - point.x, a.y + dy * t - point.y))
            }
            return points.count == 1 ? hypot(points[0].x - point.x, points[0].y - point.y) : best
        }

        func loadStyle(_ model: EngineMapView, in view: MLNMapView) {
            // Keep pending state ready before the asynchronous style callback.
            // The delegate is already installed when the first style is set.
            current = model
            pending = model
            styleReady = false
            routeLine.cancel()
            lastDaylight = model.daylight
            lastHouses = model.houses
            lastPlaces = model.places
            lastOffline = model.offline
            lastModern = model.modernStyle
            os_signpost(.event, log: performanceLog, name: "Style replacement")
            if model.modernStyle, release == nil { release = TileReleaseStore.restoredFromDisk() }
            if model.modernStyle, !modernBroken, let release {
                if let json = EngineModernStyle.json(daylight: model.daylight, base: AppConfig.syncBaseURL,
                                                     release: release, houses: model.houses,
                                                     places: model.places, driving: false,
                                                     offline: model.offline,
                                                     labelLanguage: model.labelLanguage) {
                    modernLoaded = true
                    view.styleJSON = json
                    themeLayers = []
                    prepareTiles(model, in: view)
                    return
                }
                Log.network.error("стиль новой карты не собрался — работаем на прежнем")
                modernBroken = true
            }
            modernLoaded = false
            view.styleJSON = EngineMapStyle.json(daylight: model.daylight,
                                                 base: AppConfig.syncBaseURL,
                                                 houses: true,
                                                 tilesReady: EngineTileGuard.isReady)
            themeLayers = Self.layers(daylight: model.daylight)
            prepareTiles(model, in: view)
        }

        /// Подписанный индекс для выбранного стиля: корень выпуска для новой
        /// карты, прежний индекс MVT — для старой. Готово — стиль
        /// перезагружается сам. Новая карта без выпуска (сервер недоступен, а
        /// на диске пусто) честно откатывается на прежний стиль, а не на
        /// пустой экран. Каждая попытка — одна на экран: повтор в цикле бил
        /// бы по сети без связи.
        private func prepareTiles(_ model: EngineMapView, in view: MLNMapView) {
            let modern = model.modernStyle && !modernBroken
            if modern {
                // Корень переспрашивается раз на экран даже при корне с диска:
                // выпуск мог смениться, пока приложение спало.
                guard !attemptedModern, !preparing else { return }
                attemptedModern = true
            } else {
                guard !EngineTileGuard.isReady, !attemptedLegacy, !preparing else { return }
                attemptedLegacy = true
            }
            preparing = true
            Task { @MainActor [weak self, weak view] in
                var changed = false
                if modern {
                    let before = self?.release
                    if let fresh = await TileReleaseStore.shared.prepare() {
                        self?.release = fresh
                    }
                    changed = self?.release != before
                    if self?.release == nil {
                        Log.network.error("выпуска тайлов нет — новая карта остаётся на прежнем стиле")
                        self?.attemptedLegacy = true
                        await EngineTileGuard.prepare()
                        changed = EngineTileGuard.isReady
                    }
                } else {
                    await EngineTileGuard.prepare()
                    changed = EngineTileGuard.isReady
                }
                guard let self else { return }
                self.preparing = false
                guard let view, let current = self.current else { return }
                let wantsModern = current.modernStyle && !self.modernBroken
                if wantsModern != modern {
                    self.prepareTiles(current, in: view)
                } else if changed {
                    // Перезагрузка — только если правда пришло новое: тот же
                    // выпуск с сети после корня с диска стиль не трогает.
                    self.loadStyle(current, in: view)
                }
            }
        }

        private static func layers(daylight: Bool) -> [[String: Any]] {
            let json = EngineMapStyle.json(daylight: daylight, base: AppConfig.syncBaseURL, houses: true)
            guard let data = json.data(using: .utf8) else { return [] }
            do {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                return object?["layers"] as? [[String: Any]] ?? []
            } catch {
                Log.app.error("слои стиля карты не разобрались: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }

        /// UIColor constants avoid Foundation's unsupported CAST(hex, UIColor).
        static func colorExpression(_ value: Any) -> NSExpression? {
            if let hex = value as? String, hex.hasPrefix("#"), hex.count == 7,
               let rgb = UInt32(hex.dropFirst(), radix: 16) {
                return NSExpression(forConstantValue: UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1))
            }
            guard let match = value as? [Any], match.count >= 5, match.count % 2 == 1,
                  match[0] as? String == "match", let get = match[1] as? [String],
                  get.count == 2, get[0] == "get", var expression = colorExpression(match.last!) else { return nil }
            for i in stride(from: match.count - 3, through: 2, by: -2) {
                guard let color = colorExpression(match[i + 1]) else { return nil }
                let predicate = NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: get[1]),
                    rightExpression: NSExpression(forConstantValue: match[i]), modifier: .direct,
                    type: .equalTo, options: [])
                expression = NSExpression(forConditional: predicate, trueExpression: color, falseExpression: expression)
            }
            return expression
        }

        private func updateAppearance(_ model: EngineMapView, in style: MLNStyle) {
            if lastDaylight != model.daylight {
                let layers = Self.layers(daylight: model.daylight)
                for item in layers {
                    guard let id = item["id"] as? String, let layer = style.layer(withIdentifier: id),
                          let paint = item["paint"] as? [String: Any] else { continue }
                    let old = themeLayers.first { $0["id"] as? String == id }?["paint"] as? [String: Any] ?? [:]
                    for (key, value) in paint where key.hasSuffix("color") {
                        if let previous = old[key], NSDictionary(dictionary: [key: previous]).isEqual(to: [key: value]) { continue }
                        guard let expression = Self.colorExpression(value) else { continue }
                        switch (layer, key) {
                        case (let layer as MLNBackgroundStyleLayer, "background-color"): layer.backgroundColor = expression
                        case (let layer as MLNFillStyleLayer, "fill-color"): layer.fillColor = expression
                        case (let layer as MLNFillStyleLayer, "fill-outline-color"): layer.fillOutlineColor = expression
                        case (let layer as MLNLineStyleLayer, "line-color"): layer.lineColor = expression
                        case (let layer as MLNSymbolStyleLayer, "text-color"): layer.textColor = expression
                        case (let layer as MLNSymbolStyleLayer, "text-halo-color"): layer.textHaloColor = expression
                        default: break
                        }
                    }
                }
                themeLayers = layers
                lastDaylight = model.daylight
            }
            style.layer(withIdentifier: "houses")?.isVisible = model.houses
            lastHouses = model.houses
        }

        func apply(_ model: EngineMapView, to view: MLNMapView) {
            os_signpost(.begin, log: performanceLog, name: "Map apply")
            defer { os_signpost(.end, log: performanceLog, name: "Map apply") }
            current = model
            // Смена стиля тумблером — перезагрузка целиком: у основы свои слои.
            if let lastModern, lastModern != model.modernStyle {
                loadStyle(model, in: view)
                return
            }
            guard styleReady, view.bounds.width > 0, view.bounds.height > 0 else {
                pending = model
                return
            }
            pending = nil
            if lastCursor != model.cursorStyle {
                installCursor(model.cursorStyle)
            }
            if view.isUserInteractionEnabled != model.interactive {
                view.isUserInteractionEnabled = model.interactive
            }
            applyHiddenLayers(model, in: view)
            applyCount &+= 1
            logHealthIfDue(model, in: view)
            checkMemoryIfDue(model)
            if lastRecenterToken != model.recenterToken {
                lastRecenterToken = model.recenterToken
                // Из обзора или осмотра — к машине одним плавным ходом
                // (27.D): «Поехали», «Ко мне».
                if browsing, cameraPlaced, !UIAccessibility.isReduceMotionEnabled {
                    entryUntil = CACurrentMediaTime() + AppConfig.routeEntrySeconds
                }
                browsing = false
                overviewHeld = false
                lastCameraModel = nil
            }

            // `driving` больше не перезагружает стиль (аудит 11.10, п. 3):
            // старт и стоп поездки — пик и сброс тайлов ровно в момент,
            // когда карта должна ехать. Слои поездки прячутся видимостью
            // (applyHiddenLayers), дома приглушаются свойством слоя.
            if modernLoaded, lastPlaces != model.places || lastOffline != model.offline {
                Log.network.notice("карта \(model.healthTag ?? "телефон", privacy: .public): стиль заново — офлайн \(self.lastOffline != nil, privacy: .public) → \(model.offline != nil, privacy: .public)")
                loadStyle(model, in: view)
                return
            }
            if lastDaylight != model.daylight || lastHouses != model.houses {
                // Новая карта меняет тему перезагрузкой: у основы сотня своих
                // цветов, и перекрашивать её по слою незачем — день и ночь
                // сменяются дважды в сутки.
                if modernLoaded {
                    Log.network.notice("карта \(model.healthTag ?? "телефон", privacy: .public): стиль заново — день \(model.daylight, privacy: .public), дома \(model.houses, privacy: .public)")
                    loadStyle(model, in: view)
                    return
                }
                if let style = view.style { updateAppearance(model, in: style) }
            }

            // Точка зрения. «Я» стоит не в центре, а ниже — впереди должно
            // быть видно больше, чем позади. contentInset для этого НЕ
            // используем осознанно: связка «слежение за курсом + наклон +
            // contentInset» — известная беда движка (issue #3029, до 400 %
            // процессора и перегрев). Смещаем саму точку взгляда вперёд по
            // курсу: та же картинка, обычной арифметикой — с перспективой
            // (DriveCamera.centreAhead): формула вида сверху на наклоне ставила
            // машину заметно выше задуманного места.
            // Только [0, 360): отрицательный курс движок молча не применяет,
            // и карта застывала после поворота налево через север (21.10).
            let heading = model.northUp ? 0
                : EngineMapPresentation.cameraHeading(model.courseDegrees, current: view.direction)
            let ahead = DriveCamera.centreAhead(spanMeters: model.spanMeters, anchorY: model.anchorY,
                                                pitchDegrees: model.pitchDegrees)
            // Значок и камера — по оценке «где машина сейчас», а не по фиксу.
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let wall = Date().timeIntervalSinceReferenceDate
            let fix = Self.markerFix(model)
            let fixChanged = fix != fedFix
            if fixChanged {
                let media = CACurrentMediaTime()
                if fedFix != nil {
                    fixGap = min(AppConfig.engineCameraDuration, max(0, media - fixArrival))
                }
                fixArrival = media
                predictor.update(fix, now: wall, immediate: !cameraPlaced || reduceMotion || fedFix == nil)
                fedFix = fix
            }
            // Ход камеры — столько, сколько прошло с прошлого хода, и не
            // меньше, чем осталось до ожидаемого фикса: обновление между
            // фиксами (масштаб, наклон) не обрывает ход на полпути. Цель —
            // оценка на КОНЕЦ хода: камера приходит туда же и тогда же, что и значок.
            let followNow = CACurrentMediaTime()
            let sinceFollow = lastFollowTime.map { min(AppConfig.engineCameraDuration, max(0, followNow - $0)) }
                ?? AppConfig.engineCameraDuration
            let untilFix = min(AppConfig.engineCameraDuration, max(0, fixArrival + fixGap - followNow))
            var followDuration = cameraPlaced && !reduceMotion ? max(sinceFollow, untilFix) : 0
            // Вход в ведение: ход не короче остатка входа и с мягким концом —
            // смена полей (панель выбора → панель поездки) и первый наклон
            // DriveCamera продолжают ту же дугу, а не обрывают её коротким
            // линейным шагом. Точка — оценка «где машина» на конец хода.
            let entering = entryUntil > followNow
            if entering { followDuration = max(followDuration, entryUntil - followNow) }
            let followPoint = predictor.pose(at: wall + followDuration)?.coordinate ?? model.coordinate
            let centre = GeoMath.destination(from: model.lookAt ?? followPoint,
                                              bearing: heading,
                                              distanceMeters: ahead)
            let zoom = Self.zoom(spanMeters: model.spanMeters, height: view.bounds.height,
                                 latitude: centre.latitude)
            let altitude = MLNAltitudeForZoomLevel(zoom, model.pitchDegrees,
                                                  centre.latitude, view.bounds.size)
            let camera = MLNMapCamera(lookingAtCenter: centre, altitude: altitude,
                                      pitch: model.pitchDegrees,
                                      heading: heading)
            let changed = lastCameraModel.map { previous in
                GeoMath.fastDistance(previous.coordinate.latitude, previous.coordinate.longitude,
                                     model.coordinate.latitude, model.coordinate.longitude)
                    >= (model.performance == .full ? AppConfig.engineCameraMoveThreshold
                                                   : AppConfig.engineCameraMoveThresholdWarm)
                || GeoMath.angleDifference(previous.courseDegrees, model.courseDegrees) >= AppConfig.engineCameraHeadingThreshold
                || abs(log2(max(1, previous.spanMeters) / max(1, model.spanMeters)))
                    >= AppConfig.engineCameraZoomThreshold
                || previous.pitchDegrees != model.pitchDegrees || previous.anchorY != model.anchorY
                || previous.northUp != model.northUp
                || previous.lookAt?.latitude != model.lookAt?.latitude
                || previous.lookAt?.longitude != model.lookAt?.longitude
            } ?? true
            // Частота кадров по ситуации (EngineFrames, 36A): шаг камеры,
            // который сейчас уйдёт движку, уже входит в решение — поворот
            // поднимает частоту в тот же кадр, а не фиксом позже.
            if !browsing && changed {
                noteCameraStep(zoom: zoom, pitch: model.pitchDegrees, heading: heading, at: followNow)
            }
            updatePace(model, now: followNow)
            applyFramesPerSecond(model, in: view)
            // «Весь маршрут»: вписать линию с отступами под панели сверху и
            // снизу; дальше карта свободна до «моего местоположения».
            if !commandsSeen {
                commandsSeen = true
                lastOverviewCommand = model.overviewCommand
                lastZoomCommand = model.zoomCommand
                lastPanTotal = model.panTotal
            }
            if model.overviewCommand != lastOverviewCommand {
                lastOverviewCommand = model.overviewCommand
                overviewHeld = true
                overviewKey = []
                entryUntil = 0
            }
            if overviewHeld { fitOverview(model, in: view) }
            // «+ / −» на свободной карте приближают сам вид; при слежении масштаб
            // уже учтён в охвате (spanMeters).
            if model.zoomCommand != lastZoomCommand {
                lastZoomCommand = model.zoomCommand
                overviewHeld = false
                if browsing {
                    view.setZoomLevel(min(19, max(5, view.zoomLevel + model.zoomDelta)), animated: true)
                }
            }
            // Панорама командой: содержимое едет вслед за пальцем — центр
            // карты уходит в обратную сторону. Это осмотр, как и жест.
            if model.panTotal != lastPanTotal {
                let step = CGSize(width: model.panTotal.width - lastPanTotal.width,
                                  height: model.panTotal.height - lastPanTotal.height)
                lastPanTotal = model.panTotal
                overviewHeld = false
                if !browsing {
                    browsing = true
                    model.onBrowse()
                }
                let target = CGPoint(x: view.bounds.midX - step.width,
                                     y: view.bounds.midY - step.height)
                view.setCenter(view.convert(target, toCoordinateFrom: view), animated: false)
            }
            // Наклон выключили или включили на свободной карте: следование её не
            // двигает, и переключатель казался мёртвым.
            if browsing, let shownPitch = lastModelPitch, (shownPitch == 0) != (model.pitchDegrees == 0) {
                let tilted = view.camera
                tilted.pitch = model.pitchDegrees
                view.setCamera(tilted, withDuration: 0.35,
                               animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
            }
            lastModelPitch = model.pitchDegrees
            if !browsing && changed {
                lastFollowTime = followNow
                os_signpost(.event, log: performanceLog, name: "Follow camera")
                view.setCamera(camera, withDuration: followDuration,
                           animationTimingFunction: CAMediaTimingFunction(name: entering ? .easeOut : .linear))
                lastCameraModel = model
                followCount &+= 1
            }
            if !cameraPlaced {
                Log.network.info("MapLibre: камера установлена, zoom \(view.zoomLevel, privacy: .public)")
            }
            cameraPlaced = true
            // Курс модели — на фиксе; между фиксами по линии маршрута значок
            // крутит сам (stepMarker). Сравнение с прошлым курсом МОДЕЛИ, а не
            // с нарисованным: иначе каждое обновление SwiftUI между фиксами
            // возвращало бы поворот к курсу фикса, и стрелка дрожала бы.
            if fixChanged || model.courseDegrees != lastMarkerCourse {
                lastMarkerCourse = model.courseDegrees
                positionHeading = EngineMapPresentation.heading(model.courseDegrees, near: positionHeading)
                stepMarker(at: wall, in: view)
                if !reduceMotion, predictor.isMoving(at: wall) {
                    startMarkerLink(in: view)
                } else {
                    stopMarkerLink()
                }
            }
            if let marker = positionView, marker.isHidden == model.showsPosition {
                marker.isHidden = !model.showsPosition
            }
            updateCameras(model, in: view)
            updateMarks(model, in: view)
            updateCameraLabel(model.cameraLabel, in: view)
            updateTraffic(model, in: view)
            // Подписи «24 мин» сторонятся значков камер: значок лежит выше и
            // съедал первую цифру (снимки App Store, 22.10).
            var spots: [EngineRouteVariants.CameraSpot] = []
            if model.variants.count > 1 {
                spots = cachedCameras.map { camera -> EngineRouteVariants.CameraSpot in
                    let drawn = model.cameraPoints[camera.id]
                    return EngineRouteVariants.CameraSpot(latitude: drawn?.latitude ?? camera.coordinate.latitude,
                                                          longitude: drawn?.longitude ?? camera.coordinate.longitude)
                }
            }
            routeVariants.update(model.variants, selected: model.selectedVariantID,
                                 daylight: model.daylight, avoid: spots, in: view)
            let asphalt = DriveAsphalt.isActive(driving: model.driving, modernStyle: modernLoaded)
            let threeD = drive3DActive(model)
            if let style = view.style {
                driveAsphalt.update(active: asphalt, daylight: model.daylight, car: model.carStyle,
                                    drive3D: threeD, in: style)
            }
            let routeDaylight = threeD ? Drive3D.routeDaylight(daylight: model.daylight)
                : model.carStyle?.routeDaylight(daylight: model.daylight, active: asphalt)
                ?? DriveAsphalt.routeDaylight(daylight: model.daylight, active: asphalt)
            routeLine.update(model, routeDaylight: routeDaylight, in: view)
            // Щупать тайлы — только при слежении, с 15-го и на дорисованном
            // кадре (Drive3D.canCompute): обзор и осмотр не дают лент дорог.
            let probeAllowed = Drive3D.canCompute(following: !browsing, zoom: view.zoomLevel,
                                                  tilesComplete: framesComplete)
            driveRibbon.update(model, on: threeD, probeAllowed: probeAllowed, cut: routeLine.paintedCutAlong,
                               traffic: routeLine.trafficPieces, trafficVersion: routeLine.trafficVersion,
                               routeDaylight: routeDaylight, in: view)
            laneFocusLayers.update(model, routeDaylight: routeDaylight, in: view)
            cameraZone.update(model.cameraZone, daylight: model.daylight, in: view)
            mapDetail.update(EngineMapDetail.Content(
                marks: model.detailMarks,
                halo: model.detail.destination == .arrival ? model.destination : nil,
                approach: model.detail.destination == .arrival ? model.destinationApproach : nil),
                daylight: model.daylight, in: view)
            haze.update(pitchDegrees: view.camera.pitch, daylight: model.daylight, hidden: hazeHidden(model), in: view)
            streetProbe.update(model, at: displayedPosition ?? model.coordinate, in: view)
            updateManeuverMarks(model, routeDaylight: routeDaylight, in: view)
        }

        /// «Вождение 3D» на этой карте: поверхность, поездка и новая карта.
        private func drive3DActive(_ model: EngineMapView) -> Bool {
            Drive3D.isActive(surface: model.drive3D, driving: model.driving, modernStyle: modernLoaded)
        }

        /// Дымка гаснет на горячем телефоне в «Вождении 3D» — вместе с домами и тенями.
        private func hazeHidden(_ model: EngineMapView?) -> Bool {
            guard let model, drive3DActive(model) else { return false }
            return !Drive3D.hazeShown(hot: model.performance != .full)
        }

        /// Стрелка манёвра на линии и выноска у точки манёвра (29.G): данные —
        /// раз на применение модели, место выноски — на кадре (layoutPositionView).
        private func updateManeuverMarks(_ model: EngineMapView, routeDaylight: Bool, in view: MLNMapView) {
            maneuverArrow.update(route: model.route, routeObject: model.routeObject, progress: model.routeProgress,
                                 along: model.maneuverAlong, kind: model.maneuverKind,
                                 routeDaylight: routeDaylight,
                                 shown: Drive3D.maneuverArrowShown(ribbonEnd: driveRibbon.shownEnd,
                                                                   maneuver: model.maneuverAlong),
                                 in: view)
            guard let content = model.maneuverCallout, model.calloutFrame != nil else {
                maneuverCallout.update(nil)
                maneuverCallout.layout(cursor: nil, visible: false, in: view)
                return
            }
            let anchor = maneuverArrow.point(along: content.along, route: model.route)
            var avoid: [CLLocationCoordinate2D] = []
            var approach: [CLLocationCoordinate2D] = []
            if let anchor {
                for camera in cachedCameras where model.pathCameraIDs.contains(camera.id) || camera.id == model.alertCameraID {
                    let drawn = model.cameraPoints[camera.id]
                    let point = CLLocationCoordinate2D(latitude: drawn?.latitude ?? camera.coordinate.latitude,
                                                       longitude: drawn?.longitude ?? camera.coordinate.longitude)
                    guard GeoMath.fastDistance(point.latitude, point.longitude, anchor.latitude, anchor.longitude)
                            <= AppConfig.maneuverCalloutCameraNearMeters else { continue }
                    avoid.append(point)
                }
                avoid += model.cameraZone?.points.map(\.coordinate) ?? []
                // Подъезд к повороту — стоп-линия и стрелки полос на асфальте
                // (28.C): выноска их не закрывает, а встаёт сбоку.
                for back in AppConfig.maneuverCalloutApproachMeters {
                    if let point = maneuverArrow.point(along: content.along - back, route: model.route) {
                        approach.append(point)
                    }
                }
            }
            maneuverCallout.update(EngineManeuverCallout.Input(
                content: content, anchor: anchor, distance: content.along - model.routeProgress,
                speedKmh: (model.markerMotion?.speedMps ?? 0) * 3.6, daylight: model.daylight,
                frame: model.calloutFrame, avoid: avoid, approach: approach))
            maneuverCallout.layout(cursor: shownPosition?.point, visible: model.showsPosition, in: view)
        }

        /// Объёмные украшения и размытые тени — первое, что уходит на горячем
        /// телефоне: деревья и ограждения выдавливаются на близком масштабе
        /// ведения (охват манёвра ~z17), тени зданий рисуются line-blur до 22.
        /// Видимость слоя, а не новый стиль: перезагрузка стиля — сама по
        /// себе пик, и она сбросила бы тайлы ровно тогда, когда процессор уже
        /// режут (аудит 11.10).
        /// С 21.10 (25.D) — и объёмные дома: под наклоном они главный
        /// украшатель кадра, но горячий телефон и так идёт плоско, а объём —
        /// лишний проход глубины. Вместо них — плоские (`hotShownLayers`).
        /// С 29.F сюда же — свечения (линии маршрута и ночной магистрали):
        /// размытые широкие линии — украшение, а не информация. С 33H —
        /// шевроны пробок.
        static let hotHiddenLayers = ["radar-tree-3d", "radar-barrier-3d", "radar-tree-shadow",
                                      "building-ground-shadow", "building-3d", "radar-trunk-glow",
                                      "route-glow", EngineMapStyle.routeNearLayers.glow,
                                      // Шевроны пробок (33H): цвет линии остаётся, направление
                                      // на горячем телефоне — лишняя раскладка символов.
                                      EngineMapStyle.trafficLayerIDs.chevrons]
        /// Видны ТОЛЬКО на горячем телефоне: плоские дома вместо объёмных —
        /// город не пустеет (в стиле выключены, make_style «building-flat»).
        static let hotShownLayers = ["building-flat"]
        private var hiddenLayers: Set<String>?
        /// Значки заведений стоя (29.D): порядок слоёв и круг у машины.
        private let stopDetail = EngineStopDetail()
        /// Плоские дома горячего телефона показаны (nil — после загрузки стиля).
        private var hotShown: Bool?
        /// Слои нового стиля, гасимые в поездке, — один раз на загрузку
        /// стиля. До 19.10 `style.layers.map(\.identifier)` по сотням
        /// ObjC-слоёв шёл дважды на КАЖДЫЙ фикс поездки (в машине — всегда),
        /// главный кандидат CPU в CarPlay по аудиту энергии.
        private var modernDrivingLayerIDs: [String]?

        private func drivingLayerIDs(_ style: MLNStyle) -> [String] {
            if let ids = modernDrivingLayerIDs { return ids }
            let ids = style.layers.map(\.identifier).filter(EngineModernStyle.hiddenWhileDriving)
            modernDrivingLayerIDs = ids
            return ids
        }

        /// Видимость, а не новый стиль: перезагрузка стиля — сама по себе пик и
        /// сброс тайлов, а на ходу слои меняются на каждой остановке.
        private func applyHiddenLayers(_ model: EngineMapView, in view: MLNMapView) {
            guard let style = view.style else { return }
            // Решение «что нужно сейчас» (29.H): декор, заведения, номера
            // домов, заправки, парковки. Своих значков парковок у цели нет —
            // значки тайлов остаются (MapDetailLayers.shown).
            let parkingsKnown = model.detailMarks.contains { $0.kind == .parking }
            // Входы решения не менялись — множества не пересчитываются: это
            // зовётся на каждом фиксе, а меняется на смене решения.
            let key = LayerKey(detail: model.detail, parkingsKnown: parkingsKnown, driving: model.driving,
                               modern: modernLoaded, hot: model.performance != .full, car: model.carStyle != nil,
                               drive3D: drive3DActive(model))
            if key != layerKey || hiddenLayers == nil {
                layerKey = key
                applyLayerVisibility(model, parkingsKnown: parkingsKnown, in: style)
            }
            // Значки заведений, вернувшиеся в поездке (стоим, у цели), — не под
            // «я» и кольцом компаса (29.D, EngineStopDetail): фильтр меняется
            // на входе в остановку и на сдвиге машины, не на тике. Вне поездки
            // телефона — как было, без круга.
            stopDetail.update(layers: MapDetailLayers.tripPlaceRows(model.detail), car: model.coordinate, in: style)
        }

        private struct LayerKey: Equatable {
            var detail: MapDetailPolicy.Decision
            var parkingsKnown: Bool
            var driving: Bool
            var modern: Bool
            var hot: Bool
            var car: Bool
            var drive3D: Bool
        }
        private var layerKey: LayerKey?

        private func applyLayerVisibility(_ model: EngineMapView, parkingsKnown: Bool, in style: MLNStyle) {
            var wanted = MapDetailLayers.hidden(model.detail, destinationParkingsKnown: parkingsKnown)
            // Режим «в поездке» новой карты: заведения, номера домов, подписи
            // дорожек — те же слои, что раньше вырезал drivingLayers при сборке.
            // Что решение разрешило (номера домов у цели, значки стоя), он не гасит.
            if model.driving, modernLoaded {
                wanted.formUnion(drivingLayerIDs(style))
                wanted.subtract(MapDetailLayers.shown(model.detail, destinationParkingsKnown: parkingsKnown))
            }
            // Горячий телефон — поверх решения: объёмный декор не возвращается
            // и стоя.
            if model.performance != .full { wanted.formUnion(Self.hotHiddenLayers) }
            // Экран машины (40J): без переходов и дорожек и стоя, стрелки
            // одностороннего — только стоя (MapDetailLayers.carHidden).
            if model.carStyle != nil { wanted.formUnion(MapDetailLayers.carHidden(model.detail)) }
            // «Вождение 3D» (43): тихий мир — без украшений на ходу и стоя.
            if drive3DActive(model) { wanted.formUnion(Drive3D.hiddenLayers) }
            let hot = model.performance != .full
            if wanted != hiddenLayers || hot != hotShown {
                hiddenLayers = wanted
                hotShown = hot
                let managed = Set(Self.hotHiddenLayers).union(MapDetailLayers.managed)
                    .union(MapDetailLayers.carManaged)
                    .union(Drive3D.hiddenLayers)
                    .union(drivingLayerIDs(style))
                for id in managed {
                    style.layer(withIdentifier: id)?.isVisible = !wanted.contains(id)
                }
                for id in Self.hotShownLayers {
                    style.layer(withIdentifier: id)?.isVisible = hot
                }
            }
        }

        // MARK: - Память и здоровье карты (журнал)

        /// Потолок следа в поездке (36A): на своём такте применения модели,
        /// не чаще engineMemoryCheckSeconds — таймера для этого нет.
        private var lastMemoryCheck: CFTimeInterval = 0
        private func checkMemoryIfDue(_ model: EngineMapView) {
            guard model.driving else { return }
            let now = CACurrentMediaTime()
            guard now - lastMemoryCheck >= AppConfig.engineMemoryCheckSeconds else { return }
            lastMemoryCheck = now
            MemoryPressure.checkCeiling(now: now)
        }

        private var applyCount = 0
        private var followCount = 0
        private var framesRendered = 0
        private var lastHealthLog: CFTimeInterval = 0

        /// Раз в 10 с, только с меткой: на машине карта рывками, не крутится
        /// и не показывает камеры (12.10, плитка главного экрана), а у
        /// симулятора плитки нет. Строка отвечает на главный вопрос — рисует
        /// ли движок вообще: сколько кадров, жив ли его таймер кадров, спит
        /// ли он, в каком состоянии приложение и на каком экране окно.
        private func logHealthIfDue(_ model: EngineMapView, in view: MLNMapView) {
            guard let tag = model.healthTag else { return }
            let now = CACurrentMediaTime()
            guard now - lastHealthLog >= AppConfig.engineHealthLogSeconds else { return }
            let seconds = lastHealthLog > 0 ? now - lastHealthLog : 0
            lastHealthLog = now
            let app = switch UIApplication.shared.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "?"
            }
            let scene = switch view.window?.windowScene?.activationState {
            case .foregroundActive: "fgActive"
            case .foregroundInactive: "fgInactive"
            case .background: "bg"
            case .unattached: "unattached"
            case nil: "нет окна"
            @unknown default: "?"
            }
            let onMain = view.window?.screen == UIScreen.main
            // Внутреннее состояние MapLibre 6.29–6.31 (MLNMapView.mm): спит ли
            // движок и тикает ли его таймер кадров. Через KVC и только при
            // наличии селектора — другая версия движка просто даст «?».
            let dormant = view.responds(to: NSSelectorFromString("isDormant"))
                ? ((view.value(forKey: "dormant") as? Bool).map { $0 ? "да" : "нет" } ?? "?") : "?"
            let link: String
            if view.responds(to: NSSelectorFromString("displayLink")) {
                let displayLink = view.value(forKey: "displayLink") as? CADisplayLink
                link = displayLink.map { $0.isPaused ? "стоит" : "идёт" } ?? "нет"
            } else {
                link = "?"
            }
            let bounds = view.visibleCoordinateBounds
            let inView = cachedCameras.filter { MLNCoordinateInCoordinateBounds($0.coordinate, bounds) }.count
            let course = model.courseDegrees
            Log.carplay.notice("карта \(tag, privacy: .public): приложение \(app, privacy: .public), сцена \(scene, privacy: .public), экран телефона \(onMain, privacy: .public), спит \(dormant, privacy: .public), таймер кадров \(link, privacy: .public), кадров \(self.framesRendered, privacy: .public) за \(Int(seconds), privacy: .public) с, обновлений \(self.applyCount, privacy: .public), ходов камеры \(self.followCount, privacy: .public), осмотр \(self.browsing, privacy: .public), поворот \(Int(view.direction), privacy: .public)° наклон \(Int(view.camera.pitch), privacy: .public)° курс \(Int(course), privacy: .public)°, масштаб \(view.zoomLevel, format: .fixed(precision: 1), privacy: .public), камер в источнике \(self.cachedCameras.count, privacy: .public), в кадре \(inView, privacy: .public), кадров/с \(self.lastFPS ?? 0, privacy: .public)")
            framesRendered = 0
            applyCount = 0
            followCount = 0
        }

        private var lastTrafficRevision = -1
        /// Пробки — только на новом наборе: тысяча рёбер по городу в источник
        /// раз в две минуты, а не на каждом фиксе.
        private func updateTraffic(_ model: EngineMapView, in view: MLNMapView) {
            guard model.trafficLinesRevision != lastTrafficRevision else { return }
            guard let source = view.style?.source(withIdentifier: "traffic") as? MLNShapeSource else {
                Log.network.error("MapLibre: источника пробок нет в стиле")
                return
            }
            Log.network.debug("MapLibre: пробки в источник, линий \(model.trafficLines.count, privacy: .public)")
            lastTrafficRevision = model.trafficLinesRevision
            let lines = model.trafficLines.map { traffic -> MLNPolylineFeature in
                var coordinates = traffic.coordinates
                let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                // Длина и скорости — для листа по касанию (TrafficTap).
                line.attributes = ["level": traffic.level, "src": traffic.source.rawValue, "tier": traffic.tier,
                                   "len": traffic.length.rounded(), "kmh": traffic.kmh.rounded(),
                                   "model": traffic.modelKmh.rounded()]
                return line
            }
            source.shape = MLNShapeCollectionFeature(shapes: lines)
        }

        /// Флаг цели, точка долгого тапа, зоны треног — только на изменение:
        /// запись в источник будит перерисовку слоя.
        private var lastMarksKey: [Double] = []
        private var lastRoadEventsKey: Int = -1
        private var lastCngKey: Int = -1

        /// Картинки пилюль, лежащие в стиле: лишние убираются, иначе каждая
        /// новая ступень возраста копила бы картинку до перезагрузки стиля.
        private var cngImageNames: Set<String> = []

        /// Статусы метана — пилюлей «● 15 мин назад» / «● очередь ~15».
        /// Картинки рисуются по мере надобности: статус × очередь × ступень
        /// возраста × язык — не больше нескольких десятков.
        private func updateCng(_ stations: [CngStation], in view: MLNMapView) {
            let names = stations.map(Self.cngIconName)
            var hasher = Hasher()
            for (station, name) in zip(stations, names) {
                hasher.combine(station.lat)
                hasher.combine(station.lon)
                hasher.combine(name)
                // Подтверждение меняет только прозрачность, не картинку: без
                // него в ключе подтверждённый статус до часа оставался
                // бледным «слухом» (ревью 14.2), как у событий дороги ниже.
                hasher.combine(station.confirmed)
            }
            let key = hasher.finalize()
            guard key != lastCngKey, let style = view.style,
                  let source = style.source(withIdentifier: "cng-status") as? MLNShapeSource else { return }
            lastCngKey = key
            for (station, name) in zip(stations, names) where style.image(forName: name) == nil {
                style.setImage(Self.cngIcon(station), forName: name)
            }
            source.shape = MLNShapeCollectionFeature(shapes: zip(stations, names).map { station, name in
                let mark = MLNPointFeature()
                mark.coordinate = station.coordinate
                mark.attributes = ["icon": name, "confirmed": station.status == nil || station.confirmed]
                return mark
            })
            let current = Set(names)
            for stale in cngImageNames.subtracting(current) { style.removeImage(forName: stale) }
            cngImageNames = current
        }

        /// Возраст ступенями: 5, 15, 30 мин, 1, 2, 3 ч.
        static func cngAgeBucket(_ minutes: Int) -> Int {
            [5, 15, 30, 60, 120, 180].first { minutes <= $0 } ?? 180
        }

        static func cngIconName(_ station: CngStation) -> String {
            let age = cngAgeBucket(station.statusAge ?? station.queueAge ?? 5)
            return "radar-cng-\(station.status?.rawValue ?? "none")-\(station.queue ?? 0)-\(age)-"
                + Formatting.numberLocale.identifier
        }

        /// Белая пилюля: кружок цвета статуса (зелёный — газ есть, графит —
        /// газа нет: красный на этой карте — камера; янтарь — известна только
        /// очередь) и «15 мин назад» или «очередь ~15».
        static func cngIcon(_ station: CngStation) -> UIImage {
            let fill: UInt32
            let glyph: String
            switch station.status {
            case .gas?: fill = 0x1E8E3E; glyph = "checkmark"
            case .nogas?: fill = 0x4B5563; glyph = "xmark"
            case nil: fill = 0xB45309; glyph = "clock"
            }
            let text = station.queue.map(CngRules.queueText)
                ?? CngRules.ago(cngAgeBucket(station.statusAge ?? 5))
            let font = UIFont.systemFont(ofSize: 10, weight: .bold)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: ceil(textSize.width) + 30, height: 20)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let pill = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                        cornerRadius: 10)
                UIColor.white.setFill(); pill.fill()
                UIColor(white: 0, alpha: 0.18).setStroke(); pill.lineWidth = 1; pill.stroke()
                Theme.rgb(fill).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 14, height: 14)).fill()
                if let icon = UIImage(systemName: glyph,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .black))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    icon.draw(at: CGPoint(x: 10 - icon.size.width / 2, y: 10 - icon.size.height / 2))
                }
                (text as NSString).draw(at: CGPoint(x: 21, y: (size.height - textSize.height) / 2),
                                        withAttributes: [.font: font, .foregroundColor: UIColor(white: 0.12, alpha: 1)])
            }
        }

        /// Перекрытия и ремонт — свой источник под камерами (12б.5). Ключ —
        /// id, вид и подтверждение: уточнение «перекрыто → ремонт» не меняет
        /// id, и по одному id значок оставался бы прежним.
        private func updateRoadEvents(_ events: [RoadEvent], in view: MLNMapView) {
            var hasher = Hasher()
            for event in events {
                hasher.combine(event.id)
                hasher.combine(event.kind.rawValue)
                hasher.combine(event.confirmed)
            }
            let key = hasher.finalize()
            guard key != lastRoadEventsKey,
                  let source = view.style?.source(withIdentifier: "road-events") as? MLNShapeSource else { return }
            lastRoadEventsKey = key
            source.shape = MLNShapeCollectionFeature(shapes: events.map { event in
                let mark = MLNPointFeature()
                mark.coordinate = event.coordinate
                mark.attributes = ["icon": event.kind == .closure ? "radar-closure" : "radar-roadwork",
                                   "confirmed": event.confirmed]
                return mark
            })
        }
        private var lastHotspotsKey: Int = -1
        private var lastCenterCommand = 0

        private var shownCameraLabel: CarPlayCameraCue.Label?
        private var cameraLabelWritten = false
        private var cameraLabelAt = Date.distantPast

        /// Подпись расстояния у алерт-камеры: смена камеры — сразу, новая
        /// цифра — не чаще раза в секунду (CarPlayCameraCue.shouldRefreshLabel).
        private func updateCameraLabel(_ label: CarPlayCameraCue.Label?, in view: MLNMapView) {
            let now = Date()
            if cameraLabelWritten {
                guard CarPlayCameraCue.shouldRefreshLabel(shown: shownCameraLabel, new: label,
                                                          sinceLast: now.timeIntervalSince(cameraLabelAt))
                else { return }
            } else if label == nil {
                // Источник после загрузки стиля и так пуст.
                cameraLabelWritten = true
                return
            }
            guard let source = view.style?.source(withIdentifier: "camera-label") as? MLNShapeSource else { return }
            var points: [MLNPointFeature] = []
            if let label {
                let point = MLNPointFeature()
                point.coordinate = label.coordinate
                point.attributes = ["text": label.text]
                points.append(point)
            }
            source.shape = MLNShapeCollectionFeature(shapes: points)
            shownCameraLabel = label
            cameraLabelWritten = true
            cameraLabelAt = now
        }

        private func updateMarks(_ model: EngineMapView, in view: MLNMapView) {
            let key = [model.destination?.latitude ?? .nan, model.destination?.longitude ?? .nan,
                       model.pressedPoint?.latitude ?? .nan, model.pressedPoint?.longitude ?? .nan,
                       model.parkedCar?.latitude ?? .nan, model.parkedCar?.longitude ?? .nan]
            if key.map({ $0.isNaN ? 0 : $0 }) != lastMarksKey.map({ $0.isNaN ? 0 : $0 }) || lastMarksKey.isEmpty {
                lastMarksKey = key
                var points: [MLNPointFeature] = []
                if let destination = model.destination {
                    let flag = MLNPointFeature(); flag.coordinate = destination
                    flag.attributes = ["icon": "radar-flag"]; points.append(flag)
                }
                if let parked = model.parkedCar {
                    let mark = MLNPointFeature(); mark.coordinate = parked
                    mark.attributes = ["icon": "radar-parked"]; points.append(mark)
                }
                if let pressed = model.pressedPoint {
                    let pin = MLNPointFeature(); pin.coordinate = pressed
                    pin.attributes = ["icon": "radar-pin"]; points.append(pin)
                }
                (view.style?.source(withIdentifier: "marks") as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: points)
            }
            updateRoadEvents(model.roadEvents, in: view)
            updateCng(model.cngStations, in: view)
            var hasher = Hasher()
            for spot in model.hotspots { hasher.combine(spot.latitude); hasher.combine(spot.longitude) }
            hasher.combine(model.hotspotLabels)
            let hotspotsKey = hasher.finalize()
            if hotspotsKey != lastHotspotsKey {
                lastHotspotsKey = hotspotsKey
                let zones = model.hotspots.enumerated().map { index, centre -> MLNPolygonFeature in
                    let ring = (0..<36).map { step -> CLLocationCoordinate2D in
                        GeoMath.destination(from: centre, bearing: Double(step) * 10,
                                            distanceMeters: AppConfig.hotspotZoneRadiusMeters)
                    }
                    let zone = MLNPolygonFeature(coordinates: ring, count: UInt(ring.count))
                    let label = model.hotspotLabels.indices.contains(index) ? model.hotspotLabels[index] : ""
                    zone.attributes = ["label": label]
                    return zone
                }
                (view.style?.source(withIdentifier: "hotspots") as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: zones)
            }
            if model.centerCommand != lastCenterCommand {
                lastCenterCommand = model.centerCommand
                if let target = model.centerTarget {
                    browsing = true
                    model.onBrowse()
                    view.setCenter(target, zoomLevel: max(view.zoomLevel, AppConfig.mapCenterZoom),
                                   animated: true)
                }
            }
        }

        private func updateCameras(_ model: EngineMapView, in view: MLNMapView) {
            let region = Self.region(of: view)
            // Урезанная бюджетом выборка (обзор маршрута, первый кадр карты —
            // вид всего мира) повторяется на любом сдвиге вида, а не только на
            // выходе из области: см. EngineMapPresentation.CameraWindow (20.1).
            if EngineMapPresentation.needsCameraQuery(cameraWindow, view: region)
                || cameraRevision != model.cameraRevision || limitRevision != model.limitRevision {
                os_signpost(.event, log: performanceLog, name: "Camera viewport query")
                let padded = EngineMapPresentation.padded(region)
                let limit = AppConfig.engineCameraViewportLimit
                cachedCameras = model.cameraProvider?(padded, limit) ?? model.cameras
                cachedLimits = Dictionary(uniqueKeysWithValues: cachedCameras.compactMap { camera in
                    (model.limitProvider?(camera) ?? model.cameraLimits[camera.id]).map { (camera.id, $0) }
                })
                // Без поставщика список камер один на любой вид — он полон.
                cameraWindow = EngineMapPresentation.CameraWindow(
                    view: region, found: model.cameraProvider == nil ? 0 : cachedCameras.count, limit: limit)
                cameraRevision = model.cameraRevision
                limitRevision = model.limitRevision
            }
            guard cachedCameras != lastCameras || model.alertCameraID != lastAlertID || cachedLimits != lastLimits
                    || model.pathCameraIDs != lastPathIDs || model.familiarCameraIDs != lastFamiliarIDs
                    || model.ownReportIDs != lastOwnReportIDs
                    || model.cameraPoints != lastCameraPoints
                    || model.daylight != camerasDaylight else { return }
            lastCameras = cachedCameras
            lastAlertID = model.alertCameraID
            lastLimits = cachedLimits
            lastPathIDs = model.pathCameraIDs
            lastCameraPoints = model.cameraPoints
            lastFamiliarIDs = model.familiarCameraIDs
            lastOwnReportIDs = model.ownReportIDs
            camerasDaylight = model.daylight
            let points = cachedCameras.map { camera in
                let point = MLNPointFeature()
                // Камера на пути — на линии маршрута (27.B); остальные — где стоят.
                point.coordinate = model.cameraPoints[camera.id]?.coordinate ?? camera.coordinate
                point.attributes = Self.cameraAttributes(camera, alert: model.alertCameraID,
                                                         path: model.pathCameraIDs,
                                                         familiar: model.familiarCameraIDs,
                                                         own: model.ownReportIDs,
                                                         daylight: model.daylight,
                                                         limit: cachedLimits[camera.id])
                return point
            }
            (view.style?.source(withIdentifier: "cameras") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: points)
        }

        /// Рамка маршрута для «Весь маршрут»; nil — линии нет.
        #if DEBUG
        func scheduleDebugTap() {
            let args = ProcessInfo.processInfo.arguments
            func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.dropFirst($0 + 1).first } }
            let variant = value("-tapVariant").flatMap(Int.init)
            let at = value("-tapMapAt")?.split(separator: ",").compactMap { Double($0) }
            guard variant != nil || at?.count == 2 else { return }
            let delay = value("-tapAfter").flatMap(Double.init) ?? 12
            Task { @MainActor [weak self] in
                await Task.pause(seconds: delay)
                guard let self, let view = self.view else { return }
                if let at, at.count == 2 {
                    self.handleTap(at: CGPoint(x: at[0], y: at[1]))
                } else if let variant, let coordinate = self.routeVariants.labelCoordinate(of: variant) {
                    self.handleTap(at: view.convert(coordinate, toPointTo: view))
                }
            }
        }
        #endif

        /// Кадр «весь маршрут» (27.D): все варианты (иначе линия маршрута)
        /// между панелями — RoutePreview.fit, север вверху, без наклона, одним
        /// плавным ходом. До 27.D карта сперва рывком ложилась плашмя, а
        /// вписывание шло с постоянными полями 150/240 pt — линия уходила под
        /// карточку выбора. Повторяется, пока кадр держится, только на смене
        /// входа: полей, вида, набора вариантов или выбора.
        private func fitOverview(_ model: EngineMapView, in view: MLNMapView) {
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            func add(_ rect: MKMapRect) {
                minX = min(minX, rect.minX); minY = min(minY, rect.minY)
                maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
            }
            for variant in model.variants { add(variant.polyline.boundingMapRect) }
            if minX > maxX, let line = model.routeObject { add(line.boundingMapRect) }
            if minX > maxX {
                for coordinate in model.route { add(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize())) }
            }
            let size = view.bounds.size
            guard minX <= maxX, size.width > 0, size.height > 0 else { return }
            let rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let pad = model.overviewPadding
            let key = [rect.minX, rect.minY, rect.width, rect.height, Double(size.width), Double(size.height),
                       Double(pad.top), Double(pad.left), Double(pad.bottom), Double(pad.right)].map { $0.rounded() }
                + [Double(model.selectedVariantID ?? -1)]
            guard key != overviewKey else { return }
            overviewKey = key
            let padding = RoutePreview.Padding(top: Double(pad.top), left: Double(pad.left),
                                               bottom: Double(pad.bottom), right: Double(pad.right))
            guard let fit = RoutePreview.fit(rect, width: Double(size.width), height: Double(size.height),
                                             padding: padding) else { return }
            browsing = true
            let altitude = MLNAltitudeForZoomLevel(fit.zoom, 0, fit.center.latitude, size)
            let camera = MLNMapCamera(lookingAtCenter: fit.center, altitude: altitude, pitch: 0, heading: 0)
            view.setCamera(camera,
                           withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : AppConfig.routeOverviewSeconds,
                           animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        }

        // MARK: - Стрелка

        /// Где стрелка нарисована сейчас (оценка на последнем кадре).
        private var displayedPosition: CLLocationCoordinate2D?
        /// Стрелка «я» — обычный вид поверх карты, а не символ в источнике.
        ///
        /// Раньше каждый шаг плавного хода (до 30 раз в секунду, всю поездку)
        /// писал точку в GeoJSON-источник `position`: движок заново строил его
        /// тайл на воркерах и заново расставлял все символьные слои карты на
        /// главном потоке, а стрелка ещё и отставала от камеры на кадр — тайл
        /// приходит асинхронно (аудит 11.10). Аннотация MapLibre не спасает:
        /// под видом аннотации движок держит невидимый символ и так же
        /// перетайливает его на каждом сдвиге. Вид поверх карты стоит только
        /// пересчёта экранной точки: на каждом кадре движения камеры
        /// (`mapViewRegionIsChanging`) и на каждом шаге хода. Источник и слой
        /// `user-location` в стиле остаются пустыми — их ждёт шаблон выпуска.
        private var positionView: UIImageView?

        private func setPosition(_ coordinate: CLLocationCoordinate2D, in view: MLNMapView) {
            displayedPosition = coordinate
            layoutPositionView(in: view)
        }

        /// Точка и поворот стрелки по текущей камере. Поворот — курс минус
        /// направление карты: как у прежнего символа с `icon-rotation-alignment:
        /// map`. Вид стоит лицом к экрану при наклоне — как `icon-pitch-alignment:
        /// viewport`.
        /// Стрелка «я» на экране. Зовётся дважды за кадр (кадр камеры и шаг
        /// глайда) — второй раз с тем же результатом, поэтому сдвиг меньше
        /// четверти пункта и поворот меньше 0,2° пропускаются. Ставится слоем,
        /// а не `center`/`transform` вида: UIKit на них пересобирает раскладку
        /// карты (`layoutSubviews` движка — половина кода приложения на main
        /// в замере 19.10, perf_audit_2026-10-19.md).
        private func layoutPositionView(in view: MLNMapView) {
            guard let coordinate = displayedPosition else { return }
            #if DEBUG
            if MarkerLagLog.enabled {
                let now = CACurrentMediaTime()
                if now - lastMarkerLog >= 0.2 {
                    lastMarkerLog = now
                    Log.location.notice("МЕТКА знак \(Date().timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public) \(coordinate.latitude, format: .fixed(precision: 7), privacy: .public) \(coordinate.longitude, format: .fixed(precision: 7), privacy: .public) \(view.centerCoordinate.latitude, format: .fixed(precision: 7), privacy: .public) \(view.centerCoordinate.longitude, format: .fixed(precision: 7), privacy: .public)")
                    if let cut = routeLine.paintedCutCoordinate {
                        Log.location.notice("МЕТКА линия \(Date().timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public) \(coordinate.latitude, format: .fixed(precision: 7), privacy: .public) \(coordinate.longitude, format: .fixed(precision: 7), privacy: .public) \(cut.latitude, format: .fixed(precision: 7), privacy: .public) \(cut.longitude, format: .fixed(precision: 7), privacy: .public)")
                    }
                }
            }
            #endif
            let marker = positionView ?? makePositionView(in: view)
            let point = view.convert(coordinate, toPointTo: view)
            let angle = (positionHeading - view.direction) * .pi / 180
            let pitch = (current?.pitchDegrees ?? 0).rounded()
            // Кольцо компаса и знак лимита (29.B) — до пропуска повтора: карта
            // крутится вслед за курсом при неподвижной стрелке, а расстояние
            // до смены лимита идёт, пока стрелка стоит на месте экрана.
            carDecor.layout(at: point, coordinate: coordinate, mapDirection: view.direction,
                            pitchDegrees: pitch, compass: current?.compass ?? false,
                            look: current?.compassLook ?? .phone,
                            limit: current?.limitAhead, visible: current?.showsPosition ?? true, in: view)
            maneuverCallout.layout(cursor: point, visible: current?.showsPosition ?? true, in: view)
            if let shown = shownPosition,
               abs(shown.point.x - point.x) < 0.25, abs(shown.point.y - point.y) < 0.25,
               abs(shown.angle - angle) < 0.0035, shownPitch == pitch { return }
            shownPosition = (point, angle)
            shownPitch = pitch
            // «Машина 3D» (29.B): кадр модели по ракурсу, поворот картинки —
            // только остаток до кадра, без наклона (он уже в кадре).
            var transform = Self.cursorTransform(angle: angle, pitchDegrees: pitch)
            if lastCursor == .car3D {
                let pick = Car3DModel.frame(relativeYaw: angle * 180 / .pi, pitch: pitch)
                if pick.frame != shownCarFrame, let image = Car3DSprites.image(pick.frame) {
                    shownCarFrame = pick.frame
                    marker.image = image
                    marker.bounds = CGRect(origin: .zero, size: image.size)
                }
                transform = Self.car3DTransform(residualDegrees: pick.residual, pitchDegrees: pitch)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marker.layer.position = point
            marker.layer.transform = transform
            CATransaction.commit()
        }
        #if DEBUG
        private var lastMarkerLog: CFTimeInterval = 0
        #endif
        /// Что стрелка показывает сейчас (точка и угол) — для пропуска повторов.
        private var shownPosition: (point: CGPoint, angle: Double)?
        /// Наклон, под который посажена стрелка (целые градусы).
        private var shownPitch: Double?
        /// Кадр «Машины 3D», что сейчас в виде стрелки (nil — не она или не ставили).
        private var shownCarFrame: Car3DModel.Frame?

        /// «Машина 3D»: ракурс уже нарисован в кадре — картинка только
        /// докручивается на остаток до кадра (≤ полшага) и чуть растёт с
        /// наклоном, как плоские значки (engineCursorPitchGrow).
        static func car3DTransform(residualDegrees: Double, pitchDegrees: Double) -> CATransform3D {
            let share = min(max(0, pitchDegrees), AppConfig.engineMapPitchDegrees) / AppConfig.engineMapPitchDegrees
            let grow = 1 + AppConfig.engineCursorPitchGrow * share
            return CATransform3DRotate(CATransform3DMakeScale(grow, grow, 1), residualDegrees * .pi / 180, 0, 0, 1)
        }

        /// Посадка значка «я» на наклонную карту (25.D): курс в плоскости
        /// карты, затем наклон к горизонту — ДОЛЯ наклона карты, чтобы значок
        /// лёг на дорогу, но не сплющился в блин, — с лёгкой перспективой и
        /// чуть крупнее (как машина у Яндекса под наклоном). Сверху — прежний
        /// плоский поворот. Тень — в самом значке (MeCursor), без сдвига.
        static func cursorTransform(angle: Double, pitchDegrees: Double) -> CATransform3D {
            let pitch = min(max(0, pitchDegrees), AppConfig.engineMapPitchDegrees)
            guard pitch >= 1 else { return CATransform3DMakeRotation(angle, 0, 0, 1) }
            let share = pitch / AppConfig.engineMapPitchDegrees
            var transform = CATransform3DIdentity
            transform.m34 = -1 / AppConfig.engineCursorPerspectivePoints
            let grow = 1 + AppConfig.engineCursorPitchGrow * share
            transform = CATransform3DScale(transform, grow, grow, 1)
            // CATransform3DRotate применяет поворот ПЕРЕД уже собранным:
            // итог — курс, затем наклон, затем масштаб и перспектива.
            transform = CATransform3DRotate(transform, pitch * AppConfig.engineCursorTiltShare * .pi / 180, 1, 0, 0)
            return CATransform3DRotate(transform, angle, 0, 0, 1)
        }

        private func makePositionView(in view: MLNMapView) -> UIImageView {
            let marker = UIImageView()
            marker.isUserInteractionEnabled = false
            marker.isAccessibilityElement = false
            marker.isHidden = !(current?.showsPosition ?? true)
            // Под наклоном значок поворачивается в глубину (cursorTransform):
            // без запаса по z его дальняя половина уходила ЗА слой карты и
            // нос срезало ровно по середине (снимок 25.D).
            marker.layer.zPosition = AppConfig.engineCursorZPosition
            view.addSubview(marker)
            positionView = marker
            shownPosition = nil   // новый вид — поставить заново, а не «уже стоит»
            shownPitch = nil
            installCursor(current?.cursorStyle ?? lastCursor ?? .arrow)
            return marker
        }

        /// Фикс для предсказателя: свой, если LocationService дал его для ЭТОЙ
        /// точки; иначе (выбор места, грубая точка, нет поездки) — точка без
        /// скорости: значок туда доедет поправкой, но вперёд не уедет.
        static func markerFix(_ model: EngineMapView) -> MarkerPredictor.Fix {
            if let motion = model.markerMotion,
               motion.coordinate.latitude == model.coordinate.latitude,
               motion.coordinate.longitude == model.coordinate.longitude {
                return motion
            }
            return MarkerPredictor.Fix(coordinate: model.coordinate, courseDegrees: model.courseDegrees,
                                       speedMps: 0, time: 0)
        }

        /// Кадр значка: оценка на сейчас; по линии маршрута — и её курс.
        private func stepMarker(at wall: TimeInterval, in view: MLNMapView) {
            guard let pose = predictor.pose(at: wall) else { return }
            if pose.courseDegrees >= 0 {
                positionHeading = EngineMapPresentation.heading(pose.courseDegrees, near: positionHeading)
            }
            setPosition(pose.coordinate, in: view)
            // Граница пройденного — под той же точкой и в тот же кадр (27.A).
            routeLine.frame(pose: pose.coordinate,
                            course: pose.courseDegrees >= 0 ? pose.courseDegrees : (current?.courseDegrees ?? -1),
                            speedMps: fedFix?.speedMps ?? 0, in: view)
        }

        private func startMarkerLink(in view: MLNMapView) {
            guard markerLink == nil else { return }
            // Такт — от экрана, на котором карта. В машине это экран
            // магнитолы, а экран телефона спит в кармане: связка с ним
            // не тикала, и стрелка стояла, пока камера уезжала.
            let link = view.window?.screen.displayLink(withTarget: self, selector: #selector(markerFrame))
                ?? CADisplayLink(target: self, selector: #selector(markerFrame))
            link.preferredFrameRateRange = markerFrameRange()
            link.add(to: .main, forMode: .common)
            markerLink = link
        }

        /// Та же частота, что у карты: ход стрелки не должен будить экран
        /// чаще, чем рисует сам движок (нагрев, батарея), и не должен идти
        /// РЕЖЕ или чаще карты — на 20 к/с под картой 30 к/с стрелка
        /// дрожала бы относительно дороги. Редкий такт покоя карты (settled)
        /// к стрелке не относится: она едет и над стоящей картой.
        private func markerFrameRange() -> CAFrameRateRange {
            let mapFPS = settled ? 0 : (lastFPS ?? 0)
            let fps = max(15, mapFPS > 0 ? mapFPS : AppConfig.engineFollowFPS)
            return CAFrameRateRange(minimum: 10, maximum: Float(fps), preferred: Float(fps))
        }

        /// Частота карты сменилась на ходу стрелки (ровный ход, поворот) —
        /// стрелка переходит на неё же сразу, а не со следующего старта.
        private func syncMarkerLink() {
            guard let markerLink else { return }
            let range = markerFrameRange()
            if markerLink.preferredFrameRateRange.preferred != range.preferred { markerLink.preferredFrameRateRange = range }
        }

        @objc private func markerFrame() {
            guard let view else { return stopMarkerLink() }
            let wall = Date().timeIntervalSinceReferenceDate
            stepMarker(at: wall, in: view)
            #if DEBUG
            // Замер плавности (27.A): каждый кадр — значок, граница линии, камера.
            if MarkerLagLog.enabled, let shown = displayedPosition {
                let cut = routeLine.paintedCutCoordinate ?? shown
                let centre = view.centerCoordinate
                Log.location.notice("МЕТКА кадр \(Date().timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public) \(shown.latitude, format: .fixed(precision: 7), privacy: .public) \(shown.longitude, format: .fixed(precision: 7), privacy: .public) \(cut.latitude, format: .fixed(precision: 7), privacy: .public) \(cut.longitude, format: .fixed(precision: 7), privacy: .public) \(centre.latitude, format: .fixed(precision: 7), privacy: .public) \(centre.longitude, format: .fixed(precision: 7), privacy: .public) \(Double(view.convert(shown, toPointTo: view).x), format: .fixed(precision: 2), privacy: .public) \(Double(view.convert(shown, toPointTo: view).y), format: .fixed(precision: 2), privacy: .public)")
            }
            #endif
            // Встали, горизонт исчерпан, поправка догашена — такт до фикса не нужен.
            if !predictor.isMoving(at: wall) { stopMarkerLink() }
        }

        func stopMarkerLink() {
            markerLink?.invalidate()
            markerLink = nil
        }

        static func zoom(spanMeters: Double, height: Double, latitude: Double) -> Double {
            let circumference = 40_075_016.686 * cos(latitude * .pi / 180)
            return min(19, max(11, log2(circumference * max(1, height)
                                       / (512 * max(1, spanMeters)))))
        }

        /// Свойства точки камеры для слоёв стиля — облик варианта B
        /// (CameraMarkerLook): уровень, значок, пометка, цвет точки.
        static func cameraAttributes(_ camera: Camera, alert: Int?, path: Set<Int>, familiar: Set<Int>,
                                     own: Set<Int> = [], daylight: Bool, limit: Int?) -> [String: Any] {
            let tier = CameraMarkerLook.tier(id: camera.id, alert: alert, path: path)
            // Свежесть (82): приглушена и неподтверждённая, и та, о которой сказали «Уже нет».
            let faded = camera.mobileFresh.map(TripodFreshness.isFaded) ?? camera.isUnconfirmedMobile
            let ghost = CameraMarkerLook.isGhost(unconfirmed: faded, own: own.contains(camera.id))
            return ["id": camera.id, "alert": tier == .alert, "tier": tier.rawValue,
                    "sort": CameraMarkerLook.sortKey(tier),
                    "color": CameraMarkerLook.dotColor(typeHex: EngineMapStyle.typeHex(camera.kind),
                                                       tier: tier, daylight: daylight),
                    "icon": CameraMarkerLook.icon(glyph: camera.kind.glyph, tier: tier, daylight: daylight),
                    "badge": CameraMarkerLook.badge(tier: tier,
                                                    unconfirmed: ghost && camera.isUnconfirmedMobile,
                                                    familiar: familiar.contains(camera.id)),
                    "limit": limit.map(String.init) ?? "",
                    "fresh": camera.mobileFresh.map(TripodFreshness.mapLabel) ?? "",
                    "unconfirmed": ghost]
        }

        static func cameraFeatures(_ cameras: [Camera], alert: Int?, path: Set<Int> = [],
                                   familiar: Set<Int> = [], daylight: Bool = true,
                                   limits: [Int: Int] = [:]) -> [String: Any] {
            [
                "type": "FeatureCollection",
                "features": cameras.map { camera in
                    [
                        "type": "Feature",
                        "properties": cameraAttributes(camera, alert: alert, path: path, familiar: familiar,
                                                       daylight: daylight, limit: limits[camera.id]),
                        "geometry": ["type": "Point",
                                     "coordinates": [camera.lon, camera.lat]],
                    ]
                },
            ]
        }

        static func lineFeature(_ points: [CLLocationCoordinate2D]) -> [String: Any] {
            guard points.count >= 2 else {
                return ["type": "FeatureCollection", "features": []]
            }
            return [
                "type": "FeatureCollection",
                "features": [[
                    "type": "Feature",
                    "properties": [:],
                    "geometry": ["type": "LineString",
                                 "coordinates": points.map { [$0.longitude, $0.latitude] }],
                ]],
            ]
        }
    }
}
#endif
