//
//  CarPlayCamera.swift
//  RadarMap
//
//  Камера карты в машине — динамическая, как у больших навигаторов.
//
//  Одна неподвижная картинка не годится ни для чего: стоя в городе нужны
//  полосы и разметка рядом с машиной, на трассе на 100 км/ч — дорога на
//  полкилометра вперёд, а перед поворотом — развилка сверху. Владелец
//  попросил вид сверху (12.10), а затем — чтобы он был динамичным: «на
//  высокой скорости по-другому». Отсюда три оси, и все — от скорости:
//
//    * охват (сколько метров по вертикали экрана) растёт со скоростью: стоя
//      и ползком — 220 м (видны полосы, z≈17), город — до 420 м, трасса —
//      до 1100 м;
//    * наклон: до 20 км/ч — строго сверху, дальше плавно до 40–45° — на
//      скорости вперёд нужно видеть дальше, чем вбок;
//    * машина на экране опускается со скоростью (доля свободной полосы от
//      верха): дорога впереди важнее пройденной;
//    * перед манёвром (500 м) всё стягивается к «развилке сверху»: охват
//      200 м, наклон 0 — и возвращается после.
//
//  Значения ступенчатые (охват 30 м, наклон 5°, доля 0,02): каждая новая
//  ступень — анимация камеры, и мелкая дрожь скорости не должна двигать
//  карту каждую секунду. Чистая функция, покрыта CarPlayCameraTests.
//

import Foundation

nonisolated enum CarPlayCamera {

    struct Frame: Equatable, Sendable {
        /// Метров по вертикали экрана.
        let spanMeters: Double
        let pitchDegrees: Double
        /// Где машина по высоте свободной полосы экрана: 0 — верх, 1 — низ.
        let carShare: Double
    }

    /// Опорная точка по скорости.
    private struct Knot {
        let kmh, span, pitch, share: Double
    }

    private static let knots: [Knot] = [
        Knot(kmh: 0, span: 220, pitch: 0, share: 0.58),
        Knot(kmh: 20, span: 220, pitch: 0, share: 0.58),
        Knot(kmh: 60, span: 420, pitch: 20, share: 0.66),
        Knot(kmh: 100, span: 800, pitch: 40, share: 0.72),
        Knot(kmh: 130, span: 1100, pitch: 45, share: 0.74),
    ]

    /// Вид у развилки.
    static let maneuverSpan = 200.0
    static let maneuverShare = 0.62
    static let maneuverApproachMeters = 500.0

    static func frame(speedKmh: Double, maneuverDistance: Double?) -> Frame {
        let v = max(0, speedKmh.isFinite ? speedKmh : 0)
        var span = interpolate(v) { $0.span }
        var pitch = interpolate(v) { $0.pitch }
        var share = interpolate(v) { $0.share }
        if let distance = maneuverDistance, distance.isFinite, distance >= 0,
           distance < maneuverApproachMeters {
            let w = 1 - distance / maneuverApproachMeters
            span += (maneuverSpan - span) * w
            pitch += (0 - pitch) * w
            share += (maneuverShare - share) * w
        }
        return Frame(spanMeters: (span / 30).rounded() * 30,
                     pitchDegrees: (pitch / 5).rounded() * 5,
                     carShare: (share / 0.02).rounded() * 0.02)
    }

    private static func interpolate(_ v: Double, _ value: (Knot) -> Double) -> Double {
        guard let last = knots.last else { return 0 }
        if v >= last.kmh { return value(last) }
        for (a, b) in zip(knots, knots.dropFirst()) where v <= b.kmh {
            let t = b.kmh > a.kmh ? (v - a.kmh) / (b.kmh - a.kmh) : 0
            return value(a) + (value(b) - value(a)) * t
        }
        return value(last)
    }
}
