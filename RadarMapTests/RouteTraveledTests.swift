//
//  RouteTraveledTests.swift
//  RadarMapTests
//
//  Пройденная часть маршрута гаснет (28.D). Срез под значком «я» и его
//  краска — RouteCutTests (27.A); здесь — цвет пройденного: бледнее и другим
//  цветом, чем линия впереди, но НЕ исчезает на полотне. Ночной 0x4A5568
//  на графите улиц давал ΔE 4–6: позади машины линия не гасла, а пропадала,
//  и «пройдено» читалось как «маршрута нет».
//

import XCTest
@testable import RadarMap

final class RouteTraveledTests: XCTestCase {

    private func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func lab(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = linear(c.0), g = linear(c.1), b = linear(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// Слой «route-traveled» — с непрозрачностью 0,85 (EngineMapStyle.routeLayers).
    private func traveled(over road: UInt32, daylight: Bool) -> (Double, Double, Double) {
        let line = rgb(daylight ? RouteColors.traveled.day : RouteColors.traveled.night), r = rgb(road)
        let alpha = 0.85
        return (r.0 + (line.0 - r.0) * alpha, r.1 + (line.1 - r.1) * alpha, r.2 + (line.2 - r.2) * alpha)
    }

    /// Полотно: палитра 27.C (как PaletteTests.asphalt) и «Чистый» 28.A.
    private let asphaltDay: [UInt32] = [0xFFE7A3, 0xFFCF9A, 0xFFFFFF, 0xEFECE5, 0xF2F3F5, 0xFFD27A]
    private let asphaltNight: [UInt32] = [0x5F6B86, 0x647090, 0x46526B, 0x36435F, 0x0F1420,
                                          0x30343C, 0x5A606C, 0x16181C]

    func testTraveledFadesButStaysOnTheAsphalt() {
        for (roads, daylight) in [(asphaltDay, true), (asphaltNight, false)] {
            for road in roads {
                XCTAssertGreaterThanOrEqual(deltaE(traveled(over: road, daylight: daylight), rgb(road)), 8.5,
                                            "пройденное на #\(String(road, radix: 16)) \(daylight ? "днём" : "ночью")")
            }
        }
    }

    func testTraveledIsGreyBlueNotTheRoute() {
        for daylight in [true, false] {
            let line = rgb(daylight ? RouteColors.traveled.day : RouteColors.traveled.night)
            let route = rgb(daylight ? RouteColors.body.day : RouteColors.body.night)
            XCTAssertGreaterThanOrEqual(deltaE(line, route), 25, "пройденное ≠ впереди")
            // Серо-синее: синий канал выше красного, но без насыщенности линии.
            XCTAssertGreaterThan(line.2, line.0)
            XCTAssertLessThan(line.2 - line.0, route.2 - route.0)
        }
    }
}
