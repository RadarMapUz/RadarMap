//
//  MapPicture.swift
//  RadarMap
//
//  Картинка карты вместо живой карты внутри прокрутки.
//
//  В Итогах и в деталке поездки стояли живые карты Apple: превью периода с
//  отдельной SwiftUI-вью на каждую камеру недели и по две линии на трек,
//  деталка — ещё одна карта на полсотни кружков с цифрами. Жесты у обеих были
//  выключены, то есть это были картинки, которые стоили как карты: каждая
//  точка — свой хост UIKit, и прокрутка таскала их все. Здесь снимок
//  (MKMapSnapshotter) рисуется один раз вне прокрутки, поверх — наши линии и
//  точки, готовый кадр кэшируется по содержимому и теме.
//
//  Подложка приглушённая (`emphasisStyle: .muted`): на ней главное — наш трек
//  и камеры, а не дорожные щиты и границы. Без сети снимка нет — рисуем то же
//  содержимое на ровном фоне своей проекцией, картинка не пропадает.
//

import MapKit
import os
import SwiftUI
import UIKit

/// Что нарисовать поверх карты. Порядок важен: линии снизу вверх, точки —
/// в порядке массива (важное кладём последним, чтобы оно было сверху).
struct MapPicture {
    struct Line {
        var coordinates: [CLLocationCoordinate2D]
        var color: Color
        var width: CGFloat
        /// Кайма под линией — линия читается на любой подложке.
        var casing: Color? = nil
        var casingWidth: CGFloat = 0
    }

    struct Dot {
        var coordinate: CLLocationCoordinate2D
        var diameter: CGFloat
        var fill: Color
        var ring: Color = .white
        var ringWidth: CGFloat = 1.5
        /// Короткая подпись внутри точки (скорость проезда).
        var label: String? = nil
        var labelColor: Color = .white
    }

    var lines: [Line] = []
    var dots: [Dot] = []

    var isEmpty: Bool { lines.isEmpty && dots.isEmpty }

    /// Кадр по всему нарисованному с запасом по краям. Минимум ~600 м:
    /// короткая поездка иначе раздувалась до уровня подъезда.
    var frameRect: MKMapRect? {
        var rect = MKMapRect.null
        func add(_ coordinate: CLLocationCoordinate2D) {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        for line in lines { line.coordinates.forEach(add) }
        for dot in dots { add(dot.coordinate) }
        guard !rect.isNull else { return nil }
        let minSide = AppConfig.mapPictureMinSpanMeters * MKMapPointsPerMeterAtLatitude(
            rect.origin.coordinate.latitude)
        let width = max(rect.width, minSide), height = max(rect.height, minSide)
        let grown = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                              width: width, height: height)
        return grown.insetBy(dx: -grown.width * AppConfig.mapPicturePadding,
                             dy: -grown.height * AppConfig.mapPicturePadding)
    }
}

enum MapPictureRenderer {
    /// Снимок + наш слой. nil — рисовать нечего.
    static func render(_ picture: MapPicture, size: CGSize, dark: Bool,
                       scale: CGFloat) async -> UIImage? {
        guard let rect = picture.frameRect, size.width > 1, size.height > 1 else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        // Подложка — НАША карта (движок, те же тайлы и стиль, что на экране):
        // до 13.10 здесь был снимок карты Apple — единственная чужая
        // подложка в приложении, и карточка поездки в соцсети выглядела не
        // нашей. Движок не ответил (офлайн, выпуска нет) — снимок Apple, как
        // раньше; не ответил и он — пустой фон. Картинка есть всегда.
        var base: UIImage?
        var project: (CLLocationCoordinate2D) -> CGPoint = fitProjection(rect, into: size)
        #if canImport(MapLibre)
        if let own = await EngineMapSnapshot.render(rect: rect, size: size, daylight: !dark, scale: scale) {
            base = own.image
            project = own.project
        }
        #endif
        if base == nil {
            let options = MKMapSnapshotter.Options()
            options.mapRect = rect
            options.size = size
            options.scale = scale
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            config.showsTraffic = false
            options.preferredConfiguration = config
            options.traitCollection = traits
            do {
                let snapshot = try await MKMapSnapshotter(options: options).start()
                base = snapshot.image
                project = { snapshot.point(for: $0) }
            } catch {
                // Обычно это офлайн: картинка всё равно будет — без подложки.
                Log.app.notice("снимок карты не получен: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Task.isCancelled { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            func ui(_ color: Color) -> UIColor { UIColor(color).resolvedColor(with: traits) }
            if let base {
                base.draw(in: CGRect(origin: .zero, size: size))
            } else {
                ui(Theme.background).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }

            for line in picture.lines where line.coordinates.count >= 2 {
                let path = UIBezierPath()
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                path.move(to: project(line.coordinates[0]))
                for coordinate in line.coordinates.dropFirst() { path.addLine(to: project(coordinate)) }
                if let casing = line.casing {
                    ui(casing).setStroke()
                    path.lineWidth = line.casingWidth
                    path.stroke()
                }
                ui(line.color).setStroke()
                path.lineWidth = line.width
                path.stroke()
            }

            for dot in picture.dots {
                let center = project(dot.coordinate)
                let r = dot.diameter / 2
                let circle = UIBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r,
                                                         width: dot.diameter, height: dot.diameter))
                ui(dot.fill).setFill()
                circle.fill()
                if dot.ringWidth > 0 {
                    ui(dot.ring).setStroke()
                    circle.lineWidth = dot.ringWidth
                    circle.stroke()
                }
                if let label = dot.label {
                    let font = UIFont.systemFont(ofSize: dot.diameter * 0.42, weight: .heavy)
                    let rounded = font.fontDescriptor.withDesign(.rounded)
                        .map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
                    let text = NSAttributedString(string: label, attributes: [
                        .font: rounded, .foregroundColor: ui(dot.labelColor)])
                    let box = text.size()
                    text.draw(at: CGPoint(x: center.x - box.width / 2, y: center.y - box.height / 2))
                }
            }
        }
    }

    /// Своя проекция без подложки: кадр вписан в размер с сохранением сторон.
    private static func fitProjection(_ rect: MKMapRect,
                                      into size: CGSize) -> (CLLocationCoordinate2D) -> CGPoint {
        let k = min(size.width / rect.width, size.height / rect.height)
        let dx = (size.width - rect.width * k) / 2
        let dy = (size.height - rect.height * k) / 2
        return { coordinate in
            let point = MKMapPoint(coordinate)
            return CGPoint(x: (point.x - rect.minX) * k + dx, y: (point.y - rect.minY) * k + dy)
        }
    }
}

/// Карта-картинка фиксированной высоты. `key` описывает содержимое: пока он
/// тот же, кадр берётся из кэша, и повторное открытие экрана ничего не рисует.
/// Ключ обязан меняться вместе с данными — иначе в кэш ляжет чужой кадр.
struct MapPictureView: View {
    let key: String
    let picture: MapPicture
    var height: CGFloat

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var width: CGFloat = 0
    @State private var image: UIImage?

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = AppConfig.mapPictureCacheLimit
        return cache
    }()

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: cacheKey) {
            guard width > 1, !picture.isEmpty else { return }
            let name = cacheKey as NSString
            if let cached = Self.cache.object(forKey: name) {
                image = cached
                return
            }
            guard let rendered = await MapPictureRenderer.render(
                picture, size: CGSize(width: width, height: height),
                dark: scheme == .dark, scale: displayScale) else { return }
            Self.cache.setObject(rendered, forKey: name)
            withMotion(Motion.quick) { image = rendered }
        }
        .accessibilityHidden(true)
    }

    private var cacheKey: String {
        "\(key)|\(scheme == .dark ? "d" : "l")|\(Int(width))x\(Int(height))"
    }
}

/// Старт и финиш — одинаково на всех картах и силуэтах приложения: старт —
/// белая точка с кольцом цвета маршрута, финиш — крупная точка маршрута с
/// белым кольцом. Раньше в строке списка старт был зелёным, а финиш белым,
/// на карте — наоборот.
enum TripEndpoints {
    static func dots(start: CLLocationCoordinate2D, finish: CLLocationCoordinate2D) -> [MapPicture.Dot] {
        [MapPicture.Dot(coordinate: start, diameter: 11, fill: .white, ring: Theme.route, ringWidth: 3),
         MapPicture.Dot(coordinate: finish, diameter: 15, fill: Theme.route, ring: .white, ringWidth: 2.5)]
    }
}
