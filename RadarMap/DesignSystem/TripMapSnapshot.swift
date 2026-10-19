//
//  TripMapSnapshot.swift
//  RadarMap
//
//  Снимок настоящей карты с треком поездки — для share-карточек: улицы и район
//  видны, картинка информативна. Тёмный стиль, без POI; поверх — неоновый трек,
//  камеры (зелёная — в лимите, красная — превышение) и маркеры старт/финиш.
//

import MapKit
import SwiftUI
import UIKit
import os

enum TripMapSnapshot {
    /// Отрендерить карту с треком. nil — трека нет или карта не загрузилась
    /// (офлайн): вызывающий покажет фолбэк без карты.
    static func render(track: [TrackPoint], passes: [PassedCamera] = [],
                       size: CGSize) async -> UIImage? {
        guard track.count >= 2 else { return nil }

        var minLat = track[0].lat, maxLat = minLat
        var minLon = track[0].lon, maxLon = minLon
        for point in track {
            minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
            minLon = min(minLon, point.lon); maxLon = max(maxLon, point.lon)
        }
        // Паддинг 25% (минимум ~200 м), чтобы трек не упирался в края.
        let latPad = max((maxLat - minLat) * 0.25, 0.002)
        let lonPad = max((maxLon - minLon) * 0.25, 0.002)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: (maxLat - minLat) + latPad * 2,
                                   longitudeDelta: (maxLon - minLon) + lonPad * 2))
        options.size = size
        let config = MKStandardMapConfiguration(elevationStyle: .flat)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            // Без картинки карточка рисуется без карты — это не поломка, но
            // в журнале причина должна быть (правило 3).
            Log.app.notice("снимок карты поездки не снят: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)

            // Трек: тёмная подложка + неон — читается на любом фоне (как на живой карте).
            let path = UIBezierPath()
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            for (i, point) in track.enumerated() {
                let pt = snapshot.point(for: CLLocationCoordinate2D(latitude: point.lat,
                                                                    longitude: point.lon))
                i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            UIColor(Theme.background).withAlphaComponent(0.85).setStroke()
            path.lineWidth = 9
            path.stroke()
            UIColor(Theme.accent).setStroke()
            path.lineWidth = 5
            path.stroke()

            // Камеры по пути: зелёная — прошли в лимите, красная — с превышением.
            for pass in passes {
                guard let coordinate = pass.coordinate else { continue }
                let pt = snapshot.point(for: coordinate)
                let over = (pass.overLimitKmh ?? 0) > 0
                let dot = UIBezierPath(ovalIn: CGRect(x: pt.x - 7, y: pt.y - 7,
                                                      width: 14, height: 14))
                UIColor(over ? Theme.danger : Theme.success).setFill()
                dot.fill()
                UIColor.white.setStroke()
                dot.lineWidth = 2
                dot.stroke()
            }

            // Старт (маленькая белая точка) и финиш (крупная акцентная).
            if let start = track.first, let end = track.last {
                let sp = snapshot.point(for: CLLocationCoordinate2D(latitude: start.lat,
                                                                    longitude: start.lon))
                let startDot = UIBezierPath(ovalIn: CGRect(x: sp.x - 6, y: sp.y - 6,
                                                           width: 12, height: 12))
                UIColor.white.setFill()
                startDot.fill()

                let ep = snapshot.point(for: CLLocationCoordinate2D(latitude: end.lat,
                                                                    longitude: end.lon))
                let endDot = UIBezierPath(ovalIn: CGRect(x: ep.x - 8, y: ep.y - 8,
                                                         width: 16, height: 16))
                UIColor(Theme.accent).setFill()
                endDot.fill()
                UIColor.white.setStroke()
                endDot.lineWidth = 2.5
                endDot.stroke()
            }
        }
    }
}
