//
//  DaylightPaletteTests.swift
//  RadarMapTests
//

import SwiftUI
import Testing

@testable import RadarMap

@Suite("Дневная схема — другое отношение тонов, а не «то же светлее»")
struct DaylightPaletteTests {

    private func luma(_ color: Color) -> Double {
        let parts = UIColor(color).cgColor.components ?? [0, 0, 0]
        guard parts.count >= 3 else { return 0 }
        return 0.2126 * Double(parts[0]) + 0.7152 * Double(parts[1])
             + 0.0722 * Double(parts[2])
    }

    private func with(daylight: Bool, _ body: () -> Void) {
        let was = SketchPalette.daylight
        SketchPalette.daylight = daylight
        body()
        SketchPalette.daylight = was
    }

    @Test("Ночью полотно светлее земли")
    func nightRoadIsLighter() {
        with(daylight: false) {
            #expect(luma(SketchPalette.asphalt(.primary)) > luma(SketchPalette.ground))
        }
    }

    @Test("Днём полотно ТЕМНЕЕ земли")
    func dayRoadIsDarker() {
        // Ради этого дневной режим и делается: глаз читает дорогу по контрасту
        // с окружением, а не по абсолютному тону. Простое осветление всех
        // цветов даёт белёсую кашу, где асфальт неотличим от газона.
        with(daylight: true) {
            #expect(luma(SketchPalette.asphalt(.primary)) < luma(SketchPalette.ground))
        }
    }

    @Test("Иерархия классов сохраняется в обоих режимах")
    func hierarchyHolds() {
        for daylight in [false, true] {
            with(daylight: daylight) {
                let trunk = luma(SketchPalette.asphalt(.trunk))
                let street = luma(SketchPalette.asphalt(.residential))
                if daylight {
                    #expect(trunk < street, "днём магистраль обязана быть темнее")
                } else {
                    #expect(trunk > street, "ночью магистраль обязана быть светлее")
                }
            }
        }
    }

    @Test("Камера не меняется от времени суток")
    func cameraStaysPut() {
        // Единственный объект, ради которого приложение существует. Его
        // заметность не должна зависеть ни от чего.
        var night = Color.clear
        with(daylight: false) { night = SketchPalette.cameraDotFill }
        with(daylight: true) { #expect(SketchPalette.cameraDotFill == night) }
    }

    @Test("Днём земля светлее, чем ночью")
    func dayGroundIsLight() {
        var night = 0.0
        with(daylight: false) { night = luma(SketchPalette.ground) }
        with(daylight: true) { #expect(luma(SketchPalette.ground) > night + 0.3) }
    }

    @Test("Разметка остаётся заметной на дневном асфальте")
    func markingsStayVisible() {
        with(daylight: true) {
            let paint = luma(SketchPalette.marking)
            let road = luma(SketchPalette.asphalt(.primary))
            #expect(paint - road > 0.2, "разметка слилась с полотном")
        }
    }
}
