//
//  GeoMath.swift
//  RadarMap
//

import Foundation
import CoreLocation

enum GeoMath {
    /// Азимут (0–360°, 0 = север) из точки `from` в точку `to`.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Минимальная угловая разница между двумя азимутами (0–180°).
    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Быстрая дистанция (метры) без аллокаций CLLocation — equirectangular-приближение.
    /// Погрешность <0.5% на городских/областных масштабах; для сортировок и фильтров идеальна.
    static func fastDistance(_ aLat: Double, _ aLon: Double,
                             _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * 111_320
        let dLon = (bLon - aLon) * 111_320 * cos(aLat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// Точка на расстоянии `distanceMeters` по азимуту `bearing` от исходной
    /// (для 3D-камеры: смотрим вперёд по ходу, а не на крышу машины).
    static func destination(from c: CLLocationCoordinate2D, bearing: Double,
                            distanceMeters d: Double) -> CLLocationCoordinate2D {
        let δ = d / 6_371_000.0
        let θ = bearing * .pi / 180
        let φ1 = c.latitude * .pi / 180
        let λ1 = c.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }
}
