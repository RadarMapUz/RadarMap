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
        // Логотип и «Правовые документы» живут в левом нижнем углу — ровно там,
        // где приборная панель. Поджимаем поля карты на её высоту, иначе панель
        // накрывает обязательную атрибуцию Apple.
        map.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: AppConfig.carPlayDockBottomInset, trailing: 0)
        map.register(CameraMarkerView.self,
                     forAnnotationViewWithReuseIdentifier: CameraMarkerView.reuseID)

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

        // Цель оповещения подсвечиваем на карте: крупнее и с пульсом.
        coordinator.applyTarget(location.isApproachingCamera ? location.nearestCamera?.id : nil,
                                on: map)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(repository: repository, speedLimits: speedLimits,
                    route: route, location: location)
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
        /// Показанные камеры по id — обновление области не пересоздаёт аннотации.
        private var shown: [Int: CameraAnnotation] = [:]
        /// Камера, к которой приближаемся (подсвеченный маркер).
        private var targetID: Int?

        // Линия маршрута рисуется в три слоя: тёмная подложка (читается на любом
        // фоне), яркая линия и серая «пройденная» поверх неё.
        private var routeSource: MKPolyline?
        private var routeCasing: MKPolyline?
        private var routeLine: MKPolyline?
        private var traveledLine: MKPolyline?
        private var traveledProgress: CLLocationDistance = -1

        init(repository: CameraStore, speedLimits: SpeedLimitService,
             route: RouteService, location: LocationService) {
            self.repository = repository
            self.speedLimits = speedLimits
            self.route = route
            self.location = location
        }

        var preferredTracking: MKUserTrackingMode { tripActiveSeen ? .followWithHeading : .follow }

        func zoom(_ map: MKMapView, factor: Double) {
            var region = map.region
            region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.002), 4)
            region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.002), 4)
            map.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            reloadCameras(on: mapView)
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
            // На обзорном зуме камеры не показываем — это уровень «вся страна».
            guard map.region.span.latitudeDelta < AppConfig.carPlayCameraZoomThreshold else {
                if !shown.isEmpty {
                    map.removeAnnotations(Array(shown.values))
                    shown.removeAll()
                }
                return
            }
            let fresh = repository.cameras(in: map.region, limit: AppConfig.carPlayMaxCameraMarkers)
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
                                 limit: speedLimits.limit(near: camera.coordinate),
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

// MARK: - Аннотация и маркер камеры

final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: Camera
    /// Лимит дороги у камеры (OSM): есть — маркер рисуется знаком «60».
    let limit: Int?
    /// Рисовать ли клин направления: false в поездке — карта повёрнута по
    /// курсу, а клин в кэшированной картинке нарисован для севера вверху.
    let showsDirection: Bool
    /// Важность прямо сейчас — та же шкала, что на телефоне (CameraTier).
    /// Дальние камеры на экране машины гасятся: смотрят на него боковым
    /// зрением и долю секунды, и всё, что не про ближайший километр, — помеха.
    var tier: CameraTier = .near
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: camera.lat, longitude: camera.lon)
    }

    init(camera: Camera, limit: Int? = nil, tier: CameraTier = .near,
         showsDirection: Bool = true) {
        self.camera = camera
        self.limit = limit
        self.tier = tier
        self.showsDirection = showsDirection
    }
}

/// Маркер камеры: знак ограничения там, где лимит известен, иначе цветной круг
/// с глифом типа. Картинки кэшируются по паре «тип + лимит».
final class CameraMarkerView: MKAnnotationView {
    nonisolated static let reuseID = "camera"
    private static var cache: [String: UIImage] = [:]
    private var halo: CAShapeLayer?

    override var annotation: (any MKAnnotation)? {
        didSet {
            guard let annotation = annotation as? CameraAnnotation else { return }
            image = Self.marker(for: annotation.camera.kind, limit: annotation.limit,
                                direction: annotation.showsDirection
                                    ? annotation.camera.markerDirection : nil)
            centerOffset = .zero
            collisionMode = .circle
            displayPriority = .defaultHigh
            applyTier(annotation.tier)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setTarget(false)
        applyTier(.near)
    }

    /// Важность маркера: дальние гасим, но не убираем — пропавшая камера хуже
    /// лишней. Плотность, а не удаление.
    func applyTier(_ tier: CameraTier) {
        alpha = tier == .background ? AppConfig.mapBackgroundCameraOpacity : 1
    }

    /// Цель оповещения: крупнее, поверх соседей и с пульсирующим кольцом —
    /// на карте сразу видно, о какой именно точке говорит панель.
    func setTarget(_ isTarget: Bool) {
        transform = isTarget ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
        displayPriority = isTarget ? .required : .defaultHigh
        zPriority = isTarget ? .max : .defaultUnselected

        guard isTarget else {
            halo?.removeFromSuperlayer()
            halo = nil
            return
        }
        guard halo == nil else { return }
        let tint = (annotation as? CameraAnnotation)?.camera.kind.tint ?? Theme.danger
        let ring = CAShapeLayer()
        let side = max(bounds.width, bounds.height) + 14
        ring.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side)
        ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero,
                                                size: CGSize(width: side, height: side))).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(tint).cgColor
        ring.lineWidth = 3

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.7
        scale.toValue = 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 1.5
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(pulse, forKey: "pulse")

        layer.addSublayer(ring)
        halo = ring
    }

    /// Направление квантуем шагом 15°: глазом разницы не видно, а кэш вместо
    /// 360 вариантов на каждый тип держит 24.
    private static func marker(for kind: CameraType, limit: Int?, direction: Int?) -> UIImage {
        let step = direction.map { (Int((Double($0) / 15).rounded()) * 15) % 360 }
        let key = "\(kind.sourceString)|\(limit ?? -1)|\(step ?? -1)"
        if let cached = cache[key] { return cached }
        let rendered = limit.map { limitMarker(kind: kind, limit: $0, direction: step) }
            ?? glyphMarker(kind: kind, direction: step)
        cache[key] = rendered
        return rendered
    }

    /// Клин «камера смотрит туда» — та же деталь, что на телефоне. Рисуется
    /// только там, где направление доказано (см. Camera.markerDirection):
    /// половина базы доказать его не может, и клин у такой камеры был бы ложью.
    private static func drawCone(direction: Int?, kind: CameraType,
                                 center: CGPoint, radius: CGFloat) {
        guard let direction else { return }
        let spread = AppConfig.mapDirectionConeDegrees * .pi / 180
        // Ноль градусов — на север, то есть вверх по экрану карты.
        let heading = Double(direction) * .pi / 180 - .pi / 2
        let path = UIBezierPath()
        path.move(to: center)
        path.addArc(withCenter: center, radius: radius,
                    startAngle: CGFloat(heading - spread / 2),
                    endAngle: CGFloat(heading + spread / 2), clockwise: true)
        path.close()
        UIColor(kind.tint).withAlphaComponent(0.45).setFill()
        path.fill()
    }

    /// Знак «ограничение скорости» с цветной точкой типа внизу — тот же язык,
    /// что на карте телефона.
    private static func limitMarker(kind: CameraType, limit: Int, direction: Int?) -> UIImage {
        let size = CGSize(width: 46, height: 52)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let sign = CGRect(x: 7, y: 6, width: 32, height: 32)
            drawCone(direction: direction, kind: kind,
                     center: CGPoint(x: sign.midX, y: sign.midY), radius: 22)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: sign).fill()
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setStroke()
            let rim = UIBezierPath(ovalIn: sign.insetBy(dx: 2.4, dy: 2.4))
            rim.lineWidth = 4.8
            rim.stroke()

            let text = "\(limit)"
            let font = UIFont.systemFont(ofSize: limit >= 100 ? 13 : 15, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: UIColor.black]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: sign.midX - bounds.width / 2,
                                  y: sign.midY - bounds.height / 2),
                      withAttributes: attributes)

            let dot = CGRect(x: size.width / 2 - 6, y: 33, width: 12, height: 12)
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: dot).fill()
            UIColor.white.setStroke()
            let dotRing = UIBezierPath(ovalIn: dot.insetBy(dx: 0.8, dy: 0.8))
            dotRing.lineWidth = 1.6
            dotRing.stroke()
        }
    }

    /// Лимит неизвестен — цветной круг с глифом типа: тёмная кайма держит
    /// маркер читаемым и на светлых участках карты.
    private static func glyphMarker(kind: CameraType, direction: Int?) -> UIImage {
        let size = CGSize(width: 44, height: 44)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 6, y: 6, width: 32, height: 32)
            drawCone(direction: direction, kind: kind,
                     center: CGPoint(x: rect.midX, y: rect.midY), radius: 21)
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor(kind.tint).setFill()
            UIBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            UIColor.white.withAlphaComponent(0.92).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 3.2, dy: 3.2))
            ring.lineWidth = 1.6
            ring.stroke()

            let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            if let glyph = UIImage(systemName: kind.symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2,
                                      y: (size.height - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
        }
    }
}
