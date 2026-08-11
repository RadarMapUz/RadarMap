//
//  CarPlayMapView.swift
//  RadarMap
//
//  Карта CarPlay: MKMapView (тёмная, без POI) с камерами-аннотациями и линией
//  маршрута. Камеры подгружаются под видимую область из общего репозитория,
//  иконки кэшируются по типу и лимиту — движение карты ничего не аллоцирует
//  заново.
//
//  Дизайн маркеров тот же, что на телефоне: там, где известен лимит дороги,
//  камера рисуется мини-знаком «60» — сколько можно, видно без единого тапа.
//  Камера, к которой приближаемся, крупнее остальных и пульсирует кольцом.
//

import SwiftUI
import MapKit

struct CarPlayMapView: UIViewRepresentable {
    let model: CarPlayMapModel
    let repository: CameraStore
    let route: RouteService
    let location: LocationService
    let speedLimits: SpeedLimitService
    let thermal: ThermalService
    /// Фильтр вида из настроек. Значение, а не сервис: SwiftUI обязан увидеть
    /// его смену и дёрнуть updateUIView, иначе спрятанный тип останется на
    /// карте до следующего разворота региона.
    let filter: CameraFilter

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsTraffic = false
        map.showsBuildings = false
        map.showsCompass = false
        map.isPitchEnabled = false          // плоская карта читается за рулём быстрее
        map.showsUserLocation = true
        map.userTrackingMode = .follow
        // Вернулись из схемы — тот же масштаб, что был. Регион ставим ДО
        // слежения: иначе следование тут же перезапишет его умолчанием.
        if let region = model.lastRegion {
            map.setRegion(region, animated: false)
        }
        // Логотип и «Правовые документы» живут в левом нижнем углу — ровно там,
        // где приборная панель. Поджимаем поля карты на её высоту, иначе панель
        // накрывает обязательную атрибуцию Apple.
        map.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: AppConfig.carPlayDockBottomInset, trailing: 0)
        map.register(CameraMarkerView.self,
                     forAnnotationViewWithReuseIdentifier: CameraMarkerView.reuseID)
        // Кластеры. На телефоне правило прямое: камера НИКОГДА не пропадает
        // молча — если её не видно отдельным маркером, она часть посчитанной
        // группы. На карте машины кластеров не было вовсе: всё, что не влезло
        // в бюджет или наложилось на соседа, просто исчезало с экрана.
        map.register(CameraClusterView.self,
                     forAnnotationViewWithReuseIdentifier: CameraClusterView.reuseID)
        // Своя метка машины: системная синяя точка — чужая в тёмном языке
        // приложения, да и направление движения она на повёрнутой карте не
        // показывает.
        map.register(CarPlayUserMarker.self,
                     forAnnotationViewWithReuseIdentifier: CarPlayUserMarker.reuseID)

        // Старт: вокруг себя, если позиция уже есть; иначе — Ташкент.
        let center = location.currentCoordinate
            ?? CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)
        map.setRegion(MKCoordinateRegion(center: center,
                                         latitudinalMeters: 2600, longitudinalMeters: 2600),
                      animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Кнопки шаблона: «к себе» и зум (счётчики — обрабатываем дельту).
        if model.recenterRequests != coordinator.recenterHandled {
            coordinator.recenterHandled = model.recenterRequests
            map.setUserTrackingMode(coordinator.preferredTracking, animated: true)
        }
        if model.zoomInRequests != coordinator.zoomInHandled {
            coordinator.zoomInHandled = model.zoomInRequests
            coordinator.zoom(map, factor: 0.5)
        }
        if model.zoomOutRequests != coordinator.zoomOutHandled {
            coordinator.zoomOutHandled = model.zoomOutRequests
            coordinator.zoom(map, factor: 2.0)
        }

        // В поездке карта разворачивается по ходу движения — так навигатор
        // читается без мысленного поворота; вне поездки север сверху.
        let tripActive = location.isTripActive
        if tripActive != coordinator.tripActiveSeen {
            coordinator.tripActiveSeen = tripActive
            map.setUserTrackingMode(coordinator.preferredTracking, animated: true)
            // Смена режима меняет и поворот карты (по курсу ↔ на север), а
            // клин направления в картинке маркера нарисован для севера вверху —
            // пересоздаём маркеры под новый режим (≤40 штук, дёшево).
            coordinator.reloadCameras(on: map, force: true)
        }

        coordinator.applyRoute(route, on: map)

        // База камер декодируется асинхронно: первый запрос области мог уйти
        // в пустой репозиторий — перезагружаем маркеры, когда данные пришли.
        let cameraCount = repository.cameras.count
        if cameraCount != coordinator.cameraCountSeen {
            coordinator.cameraCountSeen = cameraCount
            coordinator.reloadCameras(on: map)
        }

        // Смена фильтра вида в настройках — применяем сразу: иначе спрятанный
        // тип остаётся на карте машины до следующего разворота региона.
        if filter != coordinator.filterSeen {
            coordinator.filterSeen = filter
            coordinator.reloadCameras(on: map, force: true)
        }

        // Смена термоступени меняет бюджет маркеров — применяем сразу, а не
        // при следующем сдвиге карты.
        let mode = thermal.mode
        if mode != coordinator.thermalModeSeen {
            coordinator.thermalModeSeen = mode
            coordinator.reloadCameras(on: map, force: true)
        }

        // Цель оповещения подсвечиваем на карте: крупнее и с пульсом.
        coordinator.applyTarget(location.isApproachingCamera ? location.nearestCamera?.id : nil,
                                on: map)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, repository: repository, speedLimits: speedLimits,
                    route: route, location: location, thermal: thermal)
    }

    // MARK: - Координатор

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private let repository: CameraStore
        private let speedLimits: SpeedLimitService
        /// Нужны для важности маркера: где машина и какие камеры на маршруте.
        /// Оба — @Observable-сервисы композиционного корня, живут дольше карты.
        private let route: RouteService
        private let location: LocationService
        var recenterHandled = 0
        var zoomInHandled = 0
        var zoomOutHandled = 0
        var cameraCountSeen = -1
        var tripActiveSeen = false
        var thermalModeSeen = PerformanceMode.full
        /// Показанные камеры по id — обновление области не пересоздаёт аннотации.
        private var shown: [Int: CameraAnnotation] = [:]
        /// Камера, к которой приближаемся (подсвеченный маркер).
        private var targetID: Int?

        // Линия маршрута рисуется в три слоя: тёмная подложка (читается на любом
        // фоне), яркая линия и серая «пройденная» поверх неё.
        /// Фильтр, с которым собран текущий набор маркеров. Без него смена
        /// настройки не доходит до карты: reloadCameras зовётся только по
        /// смене региона, счётчика камер, термоступени и старта поездки.
        var filterSeen: CameraFilter?
        private var routeSource: MKPolyline?
        private var routeCasing: MKPolyline?
        private var routeLine: MKPolyline?
        private var traveledLine: MKPolyline?
        private var traveledProgress: CLLocationDistance = -1

        /// Модель нужна ровно за одним: запомнить регион, чтобы возврат из
        /// схемы не сбрасывал масштаб.
        private let model: CarPlayMapModel

        init(model: CarPlayMapModel, repository: CameraStore, speedLimits: SpeedLimitService,
             route: RouteService, location: LocationService, thermal: ThermalService) {
            self.model = model
            self.repository = repository
            self.speedLimits = speedLimits
            self.route = route
            self.location = location
            self.thermal = thermal
        }

        private let thermal: ThermalService
        /// Область, для которой строился набор маркеров (порог перерисовки).
        private var loadedRegion: MKCoordinateRegion?

        var preferredTracking: MKUserTrackingMode { tripActiveSeen ? .followWithHeading : .follow }

        func zoom(_ map: MKMapView, factor: Double) {
            var region = map.region
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.002), 4)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.002), 4)
            map.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Запоминаем, чтобы возврат из схемы вернул тот же масштаб:
            // MKMapView там выгружается целиком, и без этого он вставал в
            // умолчание, стирая то, что водитель выставил руками.
            model.lastRegion = mapView.region
            // В поездке followWithHeading доворачивает и перецентрует карту
            // НЕПРЕРЫВНО — колбэк прилетал пачками в секунду, и каждый раз
            // синхронно на main шёл запрос камер + пересчёт тиров всех
            // маркеров. Телефонная карта давно живёт с буфером и порогом
            // (MapState.needsRecompute) — теперь и эта.
            guard needsReload(mapView.region) else { return }
            reloadCameras(on: mapView)
        }

        /// Тот же принцип, что у MapState.needsRecompute: заметная смена
        /// масштаба или сдвиг центра дальше трети видимой области; в перегрев
        /// порог растягивается — перерисовка реже, когда iOS уже режет CPU.
        private func needsReload(_ region: MKCoordinateRegion) -> Bool {
            guard let loaded = loadedRegion, loaded.span.latitudeDelta > 0 else { return true }
            let ratio = region.span.latitudeDelta / loaded.span.latitudeDelta
            if ratio < 0.6 || ratio > 1.6 { return true }
            let threshold = min(1, AppConfig.recomputeThreshold
                                * thermal.mode.recomputeFactor)
            let movedLat = abs(region.center.latitude - loaded.center.latitude)
            let movedLon = abs(region.center.longitude - loaded.center.longitude)
            return movedLat > loaded.span.latitudeDelta / 2 * threshold
                || movedLon > loaded.span.longitudeDelta / 2 * threshold
        }

        // MARK: Маршрут

        /// Наблюдаемые чтения route.* — SwiftUI дёрнет update при их смене.
        func applyRoute(_ route: RouteService, on map: MKMapView) {
            let polyline = route.polyline
            if polyline !== routeSource {
                [routeCasing, routeLine, traveledLine].compactMap { $0 }.forEach(map.removeOverlay)
                routeCasing = nil
                routeLine = nil
                traveledLine = nil
                traveledProgress = -1
                routeSource = polyline

                if let polyline {
                    // Подложке нужен собственный объект: один MKOverlay нельзя
                    // добавить на карту дважды.
                    let casing = Self.copy(of: polyline)
                    map.addOverlay(casing, level: .aboveRoads)
                    map.addOverlay(polyline, level: .aboveRoads)
                    routeCasing = casing
                    routeLine = polyline
                }
            }
            guard routeLine != nil else { return }

            // Пройденный кусок обновляем не каждым фиксом, а по накату: снимать
            // и класть оверлей ежесекундно — лишняя работа рендера на ровном месте.
            let progress = route.progressAlong
            guard abs(progress - traveledProgress) >= AppConfig.carPlayTraveledStepMeters,
                  let traveled = route.traveledPolyline else { return }
            traveledProgress = progress
            if let old = traveledLine { map.removeOverlay(old) }
            map.addOverlay(traveled, level: .aboveRoads)
            traveledLine = traveled
        }

        private static func copy(of polyline: MKPolyline) -> MKPolyline {
            MKPolyline(points: polyline.points(), count: polyline.pointCount)
        }

        // MARK: Камеры

        func reloadCameras(on map: MKMapView, force: Bool = false) {
            if force, !shown.isEmpty {
                map.removeAnnotations(Array(shown.values))
                shown.removeAll()
            }
            loadedRegion = map.region
            // На обзорном зуме камеры не показываем — это уровень «вся страна».
            guard map.region.span.latitudeDelta < AppConfig.carPlayCameraZoomThreshold else {
                if !shown.isEmpty {
                    map.removeAnnotations(Array(shown.values))
                    shown.removeAll()
                }
                return
            }
            // Бюджет по перегреву — та же лестница, что у телефонной карты:
            // чип «Жарко — экономлю экран» обязан быть правдой и здесь.
            let all = repository.cameras(in: map.region,
                                         limit: thermal.mode.carPlayAnnotationBudget)
            // Фильтр вида из настроек. Раньше карта машины его не читала
            // вовсе: спрятанный на телефоне тип в машине всё равно рисовался —
            // причём режим «Схема» фильтр применял, а «Карта» нет.
            // Исключение одно и обязательное: камеру, о которой говорит
            // панель, не прячем никогда — иначе голос предупреждает о том,
            // чего на карте нет.
            let alertID = location.nearestCamera?.id
            let active = filterSeen ?? .all
            let fresh = all.filter { active.matches($0) || $0.id == alertID }
            let freshIDs = Set(fresh.map(\.id))
            // Точка отсчёта важности: где машина, а не куда утащили карту.
            let focus = location.currentCoordinate ?? map.centerCoordinate
            let routeIDs = Set(route.camerasOnRoute.map(\.camera.id))

            let outdated = shown.filter { !freshIDs.contains($0.key) }
            if !outdated.isEmpty {
                map.removeAnnotations(Array(outdated.values))
                outdated.keys.forEach { shown.removeValue(forKey: $0) }
            }
            // Лимит дороги считаем один раз при создании аннотации: индекс
            // быстрый, но дёргать его на каждой перерисовке маркера незачем.
            let added = fresh.filter { shown[$0.id] == nil }.map { camera in
                CameraAnnotation(camera: camera,
                                 // На карте машины знак ограничения у КАЖДОЙ
                                 // камеры не рисуем. Лимит текущей дороги уже
                                 // показан в доке крупно и рядом со скоростью,
                                 // а сорок маленьких «60» по экрану не
                                 // добавляют знания и делают карту нечитаемой
                                 // — ровно на это и жаловались из машины.
                                 limit: nil,
                                 tier: CameraMapContent.tier(camera: camera, focus: focus,
                                                             targetID: targetID,
                                                             routeIDs: routeIDs),
                                 // В поездке карта повёрнута по курсу
                                 // (followWithHeading), а клин в картинке
                                 // нарисован для севера вверху — там он врал бы
                                 // на угол поворота. Прячем: спрятать честнее.
                                 showsDirection: !tripActiveSeen)
            }
            if !added.isEmpty {
                map.addAnnotations(added)
                added.forEach { shown[$0.camera.id] = $0 }
            }
            // Машина едет — вчерашняя «ближняя» камера могла стать дальней.
            // Сорок маркеров пересчитать дешевле, чем держать устаревшую картину.
            for annotation in shown.values {
                let tier = CameraMapContent.tier(camera: annotation.camera, focus: focus,
                                                 targetID: targetID, routeIDs: routeIDs)
                guard tier != annotation.tier else { continue }
                annotation.tier = tier
                (map.view(for: annotation) as? CameraMarkerView)?.applyTier(tier)
            }
        }

        /// Подсветка камеры, к которой приближаемся: перерисовываем только два
        /// маркера — прошлую цель и новую.
        func applyTarget(_ id: Int?, on map: MKMapView) {
            guard id != targetID else { return }
            let previous = targetID
            targetID = id
            for cameraID in [previous, id].compactMap({ $0 }) {
                guard let annotation = shown[cameraID],
                      let view = map.view(for: annotation) as? CameraMarkerView else { continue }
                view.setTarget(cameraID == id)
            }
        }

        // MapKit зовёт делегат с главного потока, но требование протокола
        // `nonisolated` — поэтому изоляцию подтверждаем через `assumeIsolated`,
        // а не дублируем работу хопом на main (делегат синхронный, ждать нечего).
        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: CarPlayUserMarker.reuseID, for: annotation)
            }
            guard let camera = annotation as? CameraAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: CameraMarkerView.reuseID,
                for: annotation
            ) as? CameraMarkerView
            view?.applyTier(camera.tier)
            view?.setTarget(camera.camera.id == targetID)
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if polyline === routeCasing {
                renderer.strokeColor = UIColor(Theme.background).withAlphaComponent(0.9)
                renderer.lineWidth = 12
            } else if polyline === traveledLine {
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.22)
                renderer.lineWidth = 7
            } else {
                renderer.strokeColor = UIColor(Theme.accent)
                renderer.lineWidth = 7
            }
            return renderer
        }
    }
}
