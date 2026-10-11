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
    var anchorY: Double = RoadSketch.meY
    /// Наклон, градусы.
    var pitchDegrees: Double
    var daylight: Bool
    /// Видимость домов. Геометрия уже входит в общий векторный тайл.
    var houses: Bool = false
    /// Камеры окрестности; `alert` — та, о которой сейчас предупреждаем.
    var cameras: [Camera]
    var cameraRevision: Int = 0
    var limitRevision: Int = 0
    var cameraProvider: ((MKCoordinateRegion) -> [Camera])?
    var limitProvider: ((Camera) -> Int?)?
    var alertCameraID: Int?
    var cameraLimits: [Int: Int] = [:]
    var route: [CLLocationCoordinate2D]
    var routeObject: MKPolyline?
    var routeProgress: Double = 0
    var maneuverAlong: Double?
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
    /// дома приглушены (EngineModernStyle.drivingLayers).
    var driving: Bool = false
    /// Карту накрыло полноэкранное предупреждение о камере (градиент до 96 %):
    /// рисовать её на полной частоте незачем (аудит 11.10).
    var covered: Bool = false
    /// Язык подписей новой карты («ru» / «uz»). Меняется только с языком
    /// приложения, а тот применяется после перезапуска — перезагрузка стиля
    /// ради него не нужна.
    var labelLanguage: String = "ru"
    /// Значок «я» (настройка «Значок на карте»). Смена — это замена ОДНОЙ
    /// картинки в живом стиле, а не перезагрузка стиля: перезагрузка
    /// сбрасывает слои, маршрут и камеры ради значка в сорок пунктов.
    var cursorStyle: CursorStyle = .arrow
    /// «Весь маршрут»: счётчик нажатий — вписать линию маршрута в экран.
    var overviewCommand: Int = 0
    /// Сдвиг карты командой, а не пальцем: в машине касания до вида не
    /// доходят, панораму присылает шаблон CarPlay (перетаскивание, стрелки
    /// крутилки). Сумма ВСЕХ сдвигов содержимого в точках экрана: карта берёт
    /// разницу с прошлой суммой, поэтому два шага, пришедшие между кадрами,
    /// оба доезжают (последний не затирает первый).
    var panTotal: CGSize = .zero
    /// Кнопка атрибуции не нажимается там, где нет касаний (экран машины):
    /// ссылку на OSM тогда показывает вызывающий — текстом.
    var hidesAttribution: Bool = false
    /// Поворот карты (градусы от севера) — компасу экрана.
    /// Флаг цели маршрута и точка долгого тапа (бар действий открыт).
    var destination: CLLocationCoordinate2D?
    var pressedPoint: CLLocationCoordinate2D?
    /// Зоны «здесь часто ставят треногу»: пустые — слоя нет.
    var hotspots: [CLLocationCoordinate2D] = []
    /// Перенести центр в точку (счётчик, как у остальных команд): нужно
    /// крестику постановки камеры, который встаёт на точку долгого тапа.
    var centerCommand: Int = 0
    var centerTarget: CLLocationCoordinate2D?
    var onHeading: (Double) -> Void = { _ in }
    var onBrowse: () -> Void = {}
    var onSelectCamera: (Camera) -> Void = { _ in }
    /// Долгий тап по карте — координата под пальцем.
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    /// Видимая область после каждого движения карты — для крестика
    /// постановки камеры (центр) и зума точек/кластеров.
    var onRegion: (MKCoordinateRegion) -> Void = { _ in }

    func makeUIView(context: Context) -> MLNMapView {
        // Сторож тайлов — ДО первой карты: движок начинает качать сразу, и
        // поставить проверку после значило бы пропустить первые тайлы без неё.
        EngineTileGuard.install()
        // Кэш тайлов — это ОФЛАЙН, а не ускорение. Связи в поездке по стране
        // нет часами, а карта обязана рисоваться: движок держит уже виденные
        // тайлы в своей базе и берёт их оттуда, пока они не протухли. Двести
        // мегабайт — примерно область, по которой человек ездит каждый день;
        // полноценные offline-паки на регион — отдельная работа.
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(
            UInt(AppConfig.engineMapCacheBytes)) { _ in }
        let view = EngineNativeMapView(frame: .zero)
        // Осмотр не меняет GPS и маршрут; вернуться к слежению можно кнопкой.
        view.isScrollEnabled = true
        view.isZoomEnabled = true
        view.isRotateEnabled = true
        // Наклон двумя пальцами — как у навигаторов, но не круче 45°: выше
        // начинается известная беда движка (#3029, перегрев), см.
        // AppConfig.engineMapPitchDegrees.
        view.isPitchEnabled = true
        view.maximumPitch = AppConfig.engineMapPitchDegrees
        view.compassView.isHidden = true
        view.logoView.isHidden = true
        // Ссылка на источник данных обязана остаться: тайлы построены по OSM.
        view.attributionButtonPosition = .bottomLeft
        view.attributionButton.isHidden = hidesAttribution
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
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator, let model = coordinator.current else { return }
            coordinator.lastCameraModel = nil
            coordinator.apply(model, to: view)
        }
        // Система предупреждает о памяти ПЕРЕД тем, как убить приложение;
        // до сих пор это предупреждение не слушал никто (см. MemoryPressure).
        MemoryPressure.onWarning(context.coordinator) { $0.releaseMemory() }
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
        coordinator.routeTask?.cancel()
        coordinator.routeGeneration += 1
        coordinator.stopPositionGlide()
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
        private var lastDriving: Bool?
        private var lastOffline: OfflineFiles?
        private var themeLayers: [[String: Any]] = []
        private var lastCameras: [Camera]?
        private var lastLimits: [Int: Int] = [:]
        private var lastAlertID: Int?
        private var lastRouteObject: MKPolyline?
        private var routeInitialized = false
        private var routeIndex: EngineMapPresentation.RouteIndex?
        fileprivate var routeTask: Task<Void, Never>?
        fileprivate var routeGeneration = 0
        private var lastPosition: CLLocationCoordinate2D?
        private var positionHeading = 0.0
        /// Плавный ход стрелки между фиксами — синхронно с камерой. Камера
        /// ехала к новой точке за интервал между фиксами, а стрелка прыгала
        /// туда сразу: она убегала вперёд, камера её догоняла, и стрелка
        /// дёргалась по экрану (поездка 07.10.2026).
        private var glideLink: CADisplayLink?
        private var glideFrom: CLLocationCoordinate2D?
        private var glideTo: CLLocationCoordinate2D?
        private var glideStart: CFTimeInterval = 0
        private var glideDuration: CFTimeInterval = 0
        private var cameraRegion: MKCoordinateRegion?
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
        private var lastProgress = -Double.infinity
        private var lastManeuverAlong: Double?
        fileprivate var lastCameraModel: EngineMapView?
        private var browsing = false
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
        private var lastZoomCommand = 0
        private var lastOverviewCommand = 0
        private var lastPanTotal = CGSize.zero
        /// Первое применение модели запоминает счётчики, но не исполняет их:
        /// иначе повторный монтаж карты вписывал бы маршрут сам по старому нажатию.
        private var commandsSeen = false

        // MapLibre invokes this for every native camera gesture, including tap zoom.
        func mapView(_ mapView: MLNMapView, shouldChangeFrom oldCamera: MLNMapCamera,
                     to newCamera: MLNMapCamera) -> Bool {
            if !browsing {
                browsing = true
                current?.onBrowse()
            }
            return true
        }

        /// Каждый кадр движения камеры (ведение, жест, вписывание): стрелка —
        /// вид поверх карты, и её экранную точку пересчитываем сами.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            layoutPositionView(in: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            layoutPositionView(in: mapView)
            if let current, styleReady { updateCameras(current, in: mapView) }
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

        #if DEBUG
        private var encodingSamples: [Double] = []
        private var renderingSamples: [Double] = []

        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool,
                                           frameEncodingTime: Double, frameRenderingTime: Double) {
            guard frameEncodingTime.isFinite, frameRenderingTime.isFinite else { return }
            encodingSamples.append(frameEncodingTime)
            renderingSamples.append(frameRenderingTime)
            if encodingSamples.count >= AppConfig.engineMetricsSampleCount { reportRendering() }
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) { reportRendering() }

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
            let renderer = ImageRenderer(content: MeCursor(scale: 1, style: cursor)
                .frame(width: 30, height: 36).padding(8))
            renderer.scale = 3
            let image = renderer.uiImage
            cursorCache[cursor] = image
            return image
        }

        private func installCameraIcons(in style: MLNStyle) {
            installCursor(current?.cursorStyle ?? .arrow)
            if !Self.iconCache.isEmpty {
                for (name, image) in Self.iconCache { style.setImage(image, forName: name) }
                return
            }
            let kinds: [CameraType] = [.stationaryCamera, .stationaryRadar,
                .intelligentRadar, .mobileRadar, .tripod, .dpsPost, .accident, .other("")]
            for kind in kinds {
                let configuration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                if let image = UIImage(systemName: kind.symbolName, withConfiguration: configuration) {
                    // Маркер (макет 07.10): круг цветом ТИПА с белым кольцом,
                    // значок тёмный на светлом радаре и белый на остальных.
                    // Тревожный — крупнее; ореол рисует слой camera-halo.
                    // Цвет запекается в пиксели: движок не применяет к
                    // картинке стиля template-режим UIKit.
                    for alert in [false, true] {
                        let side: CGFloat = alert ? 38 : 30
                        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                            let disc = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
                            UIColor.white.setFill()
                            UIBezierPath(ovalIn: disc).fill()
                            UIColor(kind.tint).setFill()
                            UIBezierPath(ovalIn: disc.insetBy(dx: alert ? 3 : 2.5, dy: alert ? 3 : 2.5)).fill()
                            image.withTintColor(UIColor(kind.glyphTint), renderingMode: .alwaysOriginal)
                                .draw(at: CGPoint(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2))
                        }
                        style.setImage(bitmap, forName: kind.symbolName + (alert ? "-alert" : ""))
                    }
                }
            }
            // Все линзы нейтральны: тайл знает положение, но не текущую фазу.
            let signal = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 38)).image { _ in
                UIColor(red: 0.36, green: 0.43, blue: 0.39, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 9, y: 29, width: 2, height: 8), cornerRadius: 1).fill()
                UIColor(red: 0.07, green: 0.13, blue: 0.11, alpha: 1).setFill()
                let shell = UIBezierPath(roundedRect: CGRect(x: 3, y: 1, width: 14, height: 30), cornerRadius: 5)
                shell.fill()
                UIColor(red: 0.65, green: 0.73, blue: 0.67, alpha: 1).setStroke()
                shell.lineWidth = 1
                shell.stroke()
                for y in [6, 14, 22] {
                    UIColor.black.withAlphaComponent(0.75).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 5, y: y - 2, width: 10, height: 10)).fill()
                    UIColor(red: 0.54, green: 0.62, blue: 0.56, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 7, y: y, width: 6, height: 6)).fill()
                    UIColor.white.withAlphaComponent(0.22).setFill()
                    UIBezierPath(ovalIn: CGRect(x: 8, y: y, width: 3, height: 2)).fill()
                }
            }
            style.setImage(signal, forName: "radar-signal")
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
            let names = ["radar-signal", "radar-stop", "radar-flag", "radar-pin"] + kinds.flatMap {
                [$0.symbolName, $0.symbolName + "-alert"]
            }
            for name in names { Self.iconCache[name] = style.image(forName: name) }
        }

        /// Уборка по просьбе системы. Освобождается только то, что строится
        /// заново из живых данных: выборка камер видимой области и разобранные
        /// слои темы. Ни стиль, ни подписанный индекс, ни окно слежения за
        /// камерами не трогаются — от них зависит предупреждение.
        func releaseMemory() {
            cachedCameras = []
            cachedLimits = [:]
            cameraRegion = nil          // следующий кадр соберёт выборку заново
            themeLayers = []            // перечитается из EngineMapStyle при смене темы
            routeIndex = nil            // соберётся из маршрута на следующем тике
            // Корзины индекса выпуска поднимутся с диска, не с сети.
            Task { await TileReleaseStore.shared.releaseMemory() }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            Log.network.info("MapLibre: стиль загружен")
            installCameraIcons(in: style)
            lastCameras = nil
            routeInitialized = false
            lineKeys = [:]
            decorationsHidden = nil
            lastPosition = nil
            cameraRegion = nil
            style.layer(withIdentifier: "houses")?.isVisible = current?.houses ?? false
            styleReady = true
            pending.map { apply($0, to: mapView) }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Log.network.error("MapLibre: ошибка загрузки: \(error.localizedDescription, privacy: .public)")
        }

        private var pending: EngineMapView?
        fileprivate var current: EngineMapView?

        @objc func selectCamera(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view, let current else { return }
            let point = gesture.location(in: view)
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = view.visibleFeatures(in: rect, styleLayerIdentifiers: ["camera-dot", "camera-icons"])
            let ids = Set(features.compactMap { ($0.attribute(forKey: "id") as? NSNumber)?.intValue })
            let nearest = cachedCameras.filter { ids.contains($0.id) }.min { a, b in
                let pa = view.convert(a.coordinate, toPointTo: view)
                let pb = view.convert(b.coordinate, toPointTo: view)
                return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
            }
            if let nearest { current.onSelectCamera(nearest) }
        }

        func loadStyle(_ model: EngineMapView, in view: MLNMapView) {
            // Keep pending state ready before the asynchronous style callback.
            // The delegate is already installed when the first style is set.
            current = model
            pending = model
            styleReady = false
            routeTask?.cancel()
            routeGeneration += 1
            lastDaylight = model.daylight
            lastHouses = model.houses
            lastPlaces = model.places
            lastDriving = model.driving
            lastOffline = model.offline
            lastModern = model.modernStyle
            os_signpost(.event, log: performanceLog, name: "Style replacement")
            if model.modernStyle, release == nil { release = TileReleaseStore.restoredFromDisk() }
            if model.modernStyle, !modernBroken, let release {
                if let json = EngineModernStyle.json(daylight: model.daylight, base: AppConfig.syncBaseURL,
                                                     release: release, houses: model.houses,
                                                     places: model.places, driving: model.driving,
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
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return object["layers"] as? [[String: Any]] ?? []
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
            applyDecorations(hidden: model.performance != .full, in: view)
            if lastRecenterToken != model.recenterToken {
                lastRecenterToken = model.recenterToken
                browsing = false
                lastCameraModel = nil
            }

            if modernLoaded, lastPlaces != model.places || lastDriving != model.driving
                || lastOffline != model.offline {
                loadStyle(model, in: view)
                return
            }
            if lastDaylight != model.daylight || lastHouses != model.houses {
                // Новая карта меняет тему перезагрузкой: у основы сотня своих
                // цветов, и перекрашивать её по слою незачем — день и ночь
                // сменяются дважды в сутки.
                if modernLoaded {
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
            // курсу: та же картинка, обычной арифметикой.
            let heading = model.northUp ? 0
                : EngineMapPresentation.heading(model.courseDegrees, near: view.direction)
            let ahead = model.spanMeters * (model.anchorY - 0.5)
            let centre = GeoMath.destination(from: model.coordinate,
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
                || abs(previous.spanMeters - model.spanMeters) >= AppConfig.engineCameraSpanThreshold
                || previous.pitchDegrees != model.pitchDegrees || previous.anchorY != model.anchorY
                || previous.northUp != model.northUp
            } ?? true
            // Частота кадров: полная — только когда водитель сам двигает карту.
            let fps = Self.framesPerSecond(browsing: browsing, performance: model.performance,
                                           lowPower: model.lowPower, covered: model.covered)
            if fps != lastFPS {
                lastFPS = fps
                view.preferredFramesPerSecond = fps > 0
                    ? MLNMapViewPreferredFramesPerSecond(rawValue: fps)
                    : .default
            }
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
                if let bounds = Self.bounds(model.route) {
                    browsing = true
                    view.setCamera(MLNMapCamera(lookingAtCenter: view.centerCoordinate,
                                                altitude: view.camera.altitude, pitch: 0,
                                                heading: 0), animated: false)
                    view.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 150, left: 40,
                                                                                      bottom: 240, right: 90),
                                                    animated: true, completionHandler: nil)
                }
            }
            // «+ / −» на свободной карте приближают сам вид; при слежении масштаб
            // уже учтён в охвате (spanMeters).
            if model.zoomCommand != lastZoomCommand {
                lastZoomCommand = model.zoomCommand
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
                if !browsing {
                    browsing = true
                    model.onBrowse()
                }
                stopPositionGlide()
                let target = CGPoint(x: view.bounds.midX - step.width,
                                     y: view.bounds.midY - step.height)
                view.setCenter(view.convert(target, toCoordinateFrom: view), animated: false)
            }
            if !browsing && changed {
                let now = CACurrentMediaTime()
                let interval = lastFollowTime.map { min(AppConfig.engineCameraDuration, max(0, now - $0)) }
                    ?? AppConfig.engineCameraDuration
                lastFollowTime = now
                lastFollowInterval = cameraPlaced ? interval : 0
                os_signpost(.event, log: performanceLog, name: "Follow camera")
                view.setCamera(camera, withDuration: cameraPlaced && !UIAccessibility.isReduceMotionEnabled ? interval : 0,
                           animationTimingFunction: CAMediaTimingFunction(name: .linear))
                lastCameraModel = model
            }
            if !cameraPlaced {
                Log.network.info("MapLibre: камера установлена, zoom \(view.zoomLevel, privacy: .public)")
            }
            cameraPlaced = true
            let rotation = EngineMapPresentation.heading(model.courseDegrees, near: positionHeading)
            if lastPosition?.latitude != model.coordinate.latitude
                || lastPosition?.longitude != model.coordinate.longitude || rotation != positionHeading {
                positionHeading = rotation
                // Ход — ровно та длительность, с которой в ЭТОМ обновлении
                // поехала камера; камера не двигалась — ставим сразу.
                let glide = lastFollowInterval ?? 0
                if !browsing, glide > 0, let from = displayedPosition ?? lastPosition,
                   !UIAccessibility.isReduceMotionEnabled {
                    startPositionGlide(from: from, to: model.coordinate, duration: glide, in: view)
                } else {
                    stopPositionGlide()
                    setPosition(model.coordinate, in: view)
                }
                lastPosition = model.coordinate
            }
            lastFollowInterval = nil
            updateCameras(model, in: view)
            updateMarks(model, in: view)
            let newRoute = !routeInitialized || lastRouteObject !== model.routeObject
            if newRoute || lastManeuverAlong != model.maneuverAlong
                || abs(model.routeProgress - lastProgress) >= AppConfig.engineRouteProgressStep {
                if newRoute { routeIndex = nil; lineKeys = [:] }
                routeInitialized = true
                lastRouteObject = model.routeObject
                lastProgress = model.routeProgress
                lastManeuverAlong = model.maneuverAlong
                routeTask?.cancel()
                routeGeneration += 1
                let generation = routeGeneration, index = routeIndex
                routeTask = Task { [weak self, weak view] in
                    let frame = await EngineMapPresentation.prepareRoute(model.route, index: index,
                        progress: model.routeProgress, maneuver: model.maneuverAlong)
                    guard !Task.isCancelled, let self, let view,
                          self.routeGeneration == generation, self.styleReady else { return }
                    self.routeIndex = frame.index
                    self.setLine(frame.traveled, source: "traveled", in: view)
                    self.setLine(frame.remaining, source: "route", in: view)
                    self.setLine(frame.maneuver, source: "maneuver", in: view)
                }
            }
        }

        /// Объёмные украшения и размытые тени — первое, что уходит на горячем
        /// телефоне: деревья и ограждения выдавливаются на близком масштабе
        /// ведения (охват манёвра ~z17), тени зданий рисуются line-blur до 22.
        /// Видимость слоя, а не новый стиль: перезагрузка стиля — сама по
        /// себе пик, и она сбросила бы тайлы ровно тогда, когда процессор уже
        /// режут (аудит 11.10).
        static let hotHiddenLayers = ["radar-tree-3d", "radar-barrier-3d", "radar-tree-shadow",
                                      "building-ground-shadow"]
        private var decorationsHidden: Bool?

        private func applyDecorations(hidden: Bool, in view: MLNMapView) {
            guard hidden != decorationsHidden, let style = view.style else { return }
            decorationsHidden = hidden
            for id in Self.hotHiddenLayers { style.layer(withIdentifier: id)?.isVisible = !hidden }
        }

        /// Что последним ушло в каждый источник линии: число точек и концы.
        /// Пустой манёвр поверх пустого и тот же отрезок манёвра на каждом
        /// шаге прогресса переписывались заново — с перетайливанием (аудит 11.10).
        private var lineKeys: [String: [Double]] = [:]

        private func setLine(_ coordinates: [CLLocationCoordinate2D], source name: String, in view: MLNMapView) {
            guard let source = view.style?.source(withIdentifier: name) as? MLNShapeSource else { return }
            let key: [Double] = coordinates.count < 2 ? [0] : [
                Double(coordinates.count),
                coordinates[0].latitude, coordinates[0].longitude,
                coordinates[coordinates.count - 1].latitude, coordinates[coordinates.count - 1].longitude]
            guard lineKeys[name] != key else { return }
            lineKeys[name] = key
            os_signpost(.begin, log: performanceLog, name: "Route source")
            defer { os_signpost(.end, log: performanceLog, name: "Route source") }
            if coordinates.count < 2 { source.shape = nil; return }
            source.shape = coordinates.withUnsafeBufferPointer {
                MLNPolylineFeature(coordinates: $0.baseAddress!, count: UInt($0.count))
            }
        }

        /// Флаг цели, точка долгого тапа, зоны треног — только на изменение:
        /// запись в источник будит перерисовку слоя.
        private var lastMarksKey: [Double] = []
        private var lastHotspotsKey: Int = -1
        private var lastCenterCommand = 0

        private func updateMarks(_ model: EngineMapView, in view: MLNMapView) {
            let key = [model.destination?.latitude ?? .nan, model.destination?.longitude ?? .nan,
                       model.pressedPoint?.latitude ?? .nan, model.pressedPoint?.longitude ?? .nan]
            if key.map({ $0.isNaN ? 0 : $0 }) != lastMarksKey.map({ $0.isNaN ? 0 : $0 }) || lastMarksKey.isEmpty {
                lastMarksKey = key
                var points: [MLNPointFeature] = []
                if let destination = model.destination {
                    let flag = MLNPointFeature(); flag.coordinate = destination
                    flag.attributes = ["icon": "radar-flag"]; points.append(flag)
                }
                if let pressed = model.pressedPoint {
                    let pin = MLNPointFeature(); pin.coordinate = pressed
                    pin.attributes = ["icon": "radar-pin"]; points.append(pin)
                }
                (view.style?.source(withIdentifier: "marks") as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: points)
            }
            var hasher = Hasher()
            for spot in model.hotspots { hasher.combine(spot.latitude); hasher.combine(spot.longitude) }
            let hotspotsKey = hasher.finalize()
            if hotspotsKey != lastHotspotsKey {
                lastHotspotsKey = hotspotsKey
                let zones = model.hotspots.map { centre -> MLNPolygonFeature in
                    let ring = (0..<36).map { step -> CLLocationCoordinate2D in
                        GeoMath.destination(from: centre, bearing: Double(step) * 10,
                                            distanceMeters: AppConfig.hotspotZoneRadiusMeters)
                    }
                    return MLNPolygonFeature(coordinates: ring, count: UInt(ring.count))
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
            let refresh = cameraRegion.map { !EngineMapPresentation.contains($0, region) } ?? true
            if refresh || cameraRevision != model.cameraRevision || limitRevision != model.limitRevision {
                os_signpost(.event, log: performanceLog, name: "Camera viewport query")
                let padded = EngineMapPresentation.padded(region)
                cachedCameras = model.cameraProvider?(padded) ?? model.cameras
                cachedLimits = Dictionary(uniqueKeysWithValues: cachedCameras.compactMap { camera in
                    (model.limitProvider?(camera) ?? model.cameraLimits[camera.id]).map { (camera.id, $0) }
                })
                cameraRegion = padded
                cameraRevision = model.cameraRevision
                limitRevision = model.limitRevision
            }
            guard cachedCameras != lastCameras || model.alertCameraID != lastAlertID || cachedLimits != lastLimits else { return }
            lastCameras = cachedCameras
            lastAlertID = model.alertCameraID
            lastLimits = cachedLimits
            let points = cachedCameras.map { camera in
                let point = MLNPointFeature()
                point.coordinate = camera.coordinate
                point.attributes = ["id": camera.id, "alert": camera.id == model.alertCameraID,
                    "color": EngineMapStyle.typeHex(camera.kind),
                    "icon": camera.kind.symbolName + (camera.id == model.alertCameraID ? "-alert" : ""),
                    "limit": cachedLimits[camera.id].map(String.init) ?? "",
                    "unconfirmed": camera.isUnconfirmedMobile]
                return point
            }
            (view.style?.source(withIdentifier: "cameras") as? MLNShapeSource)?.shape = MLNShapeCollectionFeature(shapes: points)
        }

        /// Рамка маршрута для «Весь маршрут»; nil — линии нет.
        static func bounds(_ route: [CLLocationCoordinate2D]) -> MLNCoordinateBounds? {
            guard route.count >= 2 else { return nil }
            var sw = route[0], ne = route[0]
            for point in route {
                sw.latitude = min(sw.latitude, point.latitude)
                sw.longitude = min(sw.longitude, point.longitude)
                ne.latitude = max(ne.latitude, point.latitude)
                ne.longitude = max(ne.longitude, point.longitude)
            }
            return MLNCoordinateBounds(sw: sw, ne: ne)
        }

        // MARK: - Стрелка

        private var lastFollowInterval: CFTimeInterval?
        /// Где стрелка нарисована сейчас (середина хода), а не куда едет.
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
        private func layoutPositionView(in view: MLNMapView) {
            guard let coordinate = displayedPosition else { return }
            let marker = positionView ?? makePositionView(in: view)
            marker.center = view.convert(coordinate, toPointTo: view)
            marker.transform = CGAffineTransform(
                rotationAngle: (positionHeading - view.direction) * .pi / 180)
        }

        private func makePositionView(in view: MLNMapView) -> UIImageView {
            let marker = UIImageView()
            marker.isUserInteractionEnabled = false
            marker.isAccessibilityElement = false
            view.addSubview(marker)
            positionView = marker
            installCursor(current?.cursorStyle ?? lastCursor ?? .arrow)
            return marker
        }

        private func startPositionGlide(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                                        duration: CFTimeInterval, in view: MLNMapView) {
            glideFrom = from
            glideTo = to
            glideStart = CACurrentMediaTime()
            glideDuration = duration
            if glideLink == nil {
                // Такт — от экрана, на котором карта. В машине это экран
                // магнитолы, а экран телефона спит в кармане: связка с ним
                // не тикала, и стрелка стояла, пока камера уезжала.
                let link = view.window?.screen.displayLink(withTarget: self,
                                                           selector: #selector(stepPositionGlide))
                    ?? CADisplayLink(target: self, selector: #selector(stepPositionGlide))
                // Та же частота, что у карты: ход стрелки не должен будить
                // экран чаще, чем рисует сам движок (нагрев, батарея).
                let fps = max(15, (lastFPS ?? 0) > 0 ? (lastFPS ?? 0) : AppConfig.engineFollowFPS)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: Float(fps),
                                                                preferred: Float(fps))
                link.add(to: .main, forMode: .common)
                glideLink = link
            }
        }

        @objc private func stepPositionGlide() {
            guard let view, let from = glideFrom, let to = glideTo else { return stopPositionGlide() }
            let t = glideDuration > 0 ? min(1, (CACurrentMediaTime() - glideStart) / glideDuration) : 1
            setPosition(CLLocationCoordinate2D(latitude: from.latitude + (to.latitude - from.latitude) * t,
                                               longitude: from.longitude + (to.longitude - from.longitude) * t),
                        in: view)
            if t >= 1 { stopPositionGlide() }
        }

        func stopPositionGlide() {
            glideLink?.invalidate()
            glideLink = nil
            glideFrom = nil
            glideTo = nil
        }

        /// 0 — частота по умолчанию (движок сам выбирает, плавно для жестов).
        static func framesPerSecond(browsing: Bool, performance: PerformanceMode, lowPower: Bool,
                                    covered: Bool = false) -> Int {
            if browsing { return performance == .full && !lowPower ? 0 : AppConfig.engineWarmFPS }
            // Под предупреждением о камере — как у горячего телефона: видна
            // лишь верхняя полоска карты сквозь градиент.
            if covered { return AppConfig.engineHotFPS }
            switch performance {
            case .minimal: return AppConfig.engineHotFPS
            case .reduced: return AppConfig.engineWarmFPS
            case .full:    return lowPower ? AppConfig.engineWarmFPS : AppConfig.engineFollowFPS
            }
        }

        static func zoom(spanMeters: Double, height: Double, latitude: Double) -> Double {
            let circumference = 40_075_016.686 * cos(latitude * .pi / 180)
            return min(19, max(11, log2(circumference * max(1, height)
                                       / (512 * max(1, spanMeters)))))
        }

        static func cameraFeatures(_ cameras: [Camera], alert: Int?, limits: [Int: Int] = [:]) -> [String: Any] {
            [
                "type": "FeatureCollection",
                "features": cameras.map { camera in
                    [
                        "type": "Feature",
                        "properties": ["id": camera.id, "alert": camera.id == alert,
                                       "icon": camera.kind.symbolName + (camera.id == alert ? "-alert" : ""),
                                       "limit": limits[camera.id].map { String($0) } ?? "",
                                       "unconfirmed": camera.isUnconfirmedMobile],
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
