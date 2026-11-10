//
//  TripMapSnapshot.swift
//  RadarMap
//
//  Снимок карты с треком поездки для карточек «Поделиться»: наша карта того же
//  стиля, что в приложении; карта Apple — только запасной путь. Камеры в лимите
//  мелкие, чтобы взгляд шёл к треку и к превышениям.
//

import MapKit
import SwiftUI
import UIKit
import os

/// Рамка снимка: трек целиком, снизу запас под затемнение карточки.
nonisolated enum TripMapFrame {
    /// Доля высоты кадра снизу, куда трек не заходит.
    static let bottomReserve = 0.30
    private static let topReserve = 0.16
    private static let sidePadding = 0.14
    /// Короткий трек не превращается в один перекрёсток во весь кадр.
    private static let minimumSideMeters = 600.0

    static func rect(points: [MKMapPoint], aspect: Double) -> MKMapRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let reference = MKMapPoint(x: minX, y: minY).coordinate.latitude
        let minimum = minimumSideMeters * MKMapPointsPerMeterAtLatitude(reference)
        let trackWidth = max(maxX - minX, minimum), trackHeight = max(maxY - minY, minimum)
        var height = trackHeight / (1 - bottomReserve - topReserve)
        var width = trackWidth * (1 + sidePadding * 2)
        if width / height > aspect { height = width / aspect } else { width = height * aspect }
        let centerX = (minX + maxX) / 2
        // Трек — посередине полосы между запасами.
        let free = height * (1 - bottomReserve - topReserve) - (maxY - minY)
        let top = minY - free / 2 - height * topReserve
        return MKMapRect(x: centerX - width / 2, y: top, width: width, height: height)
    }
}

enum TripMapSnapshot {
    /// Снимок размера `size` в пикселях; логический размер вдвое меньше, иначе
    /// подписи улиц на карточке получаются вдвое мельче. nil — трека нет или
    /// карта не загрузилась: вызывающий покажет трек без карты.
    static func render(track: [TrackPoint], passes: [PassedCamera] = [],
                       size: CGSize) async -> UIImage? {
        guard track.count >= 2 else { return nil }
        let logical = CGSize(width: size.width / 2, height: size.height / 2)
        let points = track.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
        let rect = TripMapFrame.rect(points: points, aspect: logical.width / logical.height)

        #if canImport(MapLibre)
        if let own = await EngineMapSnapshot.render(rect: rect, size: logical, daylight: false, scale: 2) {
            return compose(base: own.image, size: logical, track: track, passes: passes, project: own.project)
        }
        #endif

        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = logical
        let config = MKStandardMapConfiguration(elevationStyle: .flat)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        options.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark),
                                                                 UITraitCollection(displayScale: 2)])
        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            // Без картинки карточка рисуется без карты — это не поломка, но
            // в журнале причина должна быть (правило 3).
            Log.app.notice("снимок карты поездки не снят: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return compose(base: snapshot.image, size: logical, track: track, passes: passes) { snapshot.point(for: $0) }
    }

    private static func compose(base: UIImage, size: CGSize, track: [TrackPoint], passes: [PassedCamera],
                                project: (CLLocationCoordinate2D) -> CGPoint) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))

            let path = UIBezierPath()
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            for (index, point) in track.enumerated() {
                let screen = project(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon))
                index == 0 ? path.move(to: screen) : path.addLine(to: screen)
            }
            func stroke(_ color: UIColor, _ width: CGFloat) {
                color.setStroke()
                path.lineWidth = width
                path.stroke()
            }
            stroke(Theme.rgb(RouteColors.body.night, 0.28), 14)
            stroke(Theme.rgb(WidgetPalette.alertSurface, 0.75), 8)
            stroke(Theme.rgb(RouteColors.body.night), 5)
            stroke(UIColor.white.withAlphaComponent(0.55), 1.4)

            func dot(_ at: CGPoint, radius: CGFloat, fill: UIColor, rim: UIColor, width: CGFloat) {
                let oval = UIBezierPath(ovalIn: CGRect(x: at.x - radius, y: at.y - radius,
                                                       width: radius * 2, height: radius * 2))
                fill.setFill()
                oval.fill()
                rim.setStroke()
                oval.lineWidth = width
                oval.stroke()
            }
            // Сначала спокойные камеры: превышение ляжет поверх соседних.
            let ordered = passes.sorted { ($0.overLimitKmh ?? 0) < ($1.overLimitKmh ?? 0) }
            for pass in ordered {
                guard let coordinate = pass.coordinate else { continue }
                let over = (pass.overLimitKmh ?? 0) > 0
                dot(project(coordinate), radius: over ? 7 : 3.5,
                    fill: over ? UIColor(Theme.danger) : Theme.rgb(WidgetPalette.success.dark),
                    rim: over ? .white : Theme.rgb(WidgetPalette.alertSurface), width: over ? 2 : 1)
            }
            if let start = track.first, let end = track.last {
                dot(project(CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon)), radius: 5,
                    fill: Theme.rgb(WidgetPalette.alertSurface), rim: .white, width: 2.5)
                dot(project(CLLocationCoordinate2D(latitude: end.lat, longitude: end.lon)), radius: 7.5,
                    fill: Theme.rgb(RouteColors.body.night), rim: .white, width: 2.5)
            }
        }
    }
}
