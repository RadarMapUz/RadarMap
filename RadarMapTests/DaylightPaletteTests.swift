//
//  DaylightPaletteTests.swift
//  RadarMapTests
//
//  Палитра схемы — числами, а не на глаз.
//
//  Дневная схема год простояла с контрастом 1,11 у квартала, 1,19 у зелени и
//  1,25 у дома. Это невидимо: на четырёх снимках живой поездки 60–82 % кадра
//  занимал ОДИН ровный тон, а всего два тона занимали больше двух процентов
//  площади — при том, что в кадре было девяносто домов, восемь кварталов и
//  тридцать пятен зелени.
//
//  Поэтому тесты здесь не про «красиво», а про пороги: каждый слой обязан
//  отличаться от соседа на число, которое глаз различает на солнце. Если
//  кто-то снова «чуть подправит тон», сломается тест, а не поездка.
//

import SwiftUI
import Testing

@testable import RadarMap

@Suite("Палитра схемы: контраст задан числом")
struct DaylightPaletteTests {

    private func with(daylight: Bool, _ body: () -> Void) {
        let was = SketchPalette.daylight
        SketchPalette.daylight = daylight
        body()
        SketchPalette.daylight = was
    }

    // MARK: - Отношение тонов

    @Test("Ночью полотно светлее земли")
    func nightRoadIsLighter() {
        with(daylight: false) {
            #expect(SketchPalette.asphaltTone(.primary).luminance
                    > SketchPalette.groundTone.luminance)
        }
    }

    @Test("Днём полотно тоже СВЕТЛЕЕ земли — и это разворот прежнего решения")
    func dayRoadIsLighterToo() {
        // Раньше днём асфальт был темнее земли, а земля стояла у самого белого
        // (0,90). Всему остальному оставалась полоса контраста от 1,0 до 1,25,
        // то есть невидимая, — отсюда и пустое поле на снимках. Белая дорога
        // на сером городе оставляет место и кварталам, и домам, и зелени.
        with(daylight: true) {
            #expect(SketchPalette.asphaltTone(.primary).luminance
                    > SketchPalette.groundTone.luminance)
        }
    }

    @Test("Иерархия классов сохраняется в обоих режимах")
    func hierarchyHolds() {
        for daylight in [false, true] {
            with(daylight: daylight) {
                let trunk = SketchPalette.asphaltTone(.trunk).luminance
                let street = SketchPalette.asphaltTone(.residential).luminance
                #expect(trunk > street, "магистраль обязана быть заметнее жилой улицы")
            }
        }
    }

    // MARK: - Таблица контрастов

    @Test("Днём местность отличается от земли на видимое число")
    func dayTerrainIsVisible() {
        with(daylight: true) {
            let ground = SketchPalette.groundTone
            #expect(SketchPalette.blockTone.contrast(to: ground) >= 1.30)
            #expect(SketchPalette.houseTone.contrast(to: ground) >= 1.50)
            #expect(SketchPalette.greenTone.contrast(to: ground) >= 1.22)
            #expect(SketchPalette.waterTone.contrast(to: ground) >= 1.65)
            #expect(SketchPalette.railTone.contrast(to: ground) >= 2.0)
        }
    }

    @Test("Ночью — то же самое от своей земли")
    func nightTerrainIsVisible() {
        with(daylight: false) {
            let ground = SketchPalette.groundTone
            #expect(SketchPalette.blockTone.contrast(to: ground) >= 1.15)
            #expect(SketchPalette.houseTone.contrast(to: ground) >= 1.25)
            #expect(SketchPalette.greenTone.contrast(to: ground) >= 1.30)
            #expect(SketchPalette.waterTone.contrast(to: ground) >= 1.65)
        }
    }

    @Test("Дом читается внутри квартала, а не сливается с ним")
    func houseReadsInsideTheBlock() {
        for daylight in [false, true] {
            with(daylight: daylight) {
                #expect(SketchPalette.houseTone.contrast(to: SketchPalette.blockTone) >= 1.13)
                // Контур делает для застройки больше, чем заливка: без него
                // девяносто домов в кадре — одно серое пятно.
                #expect(SketchPalette.houseEdgeTone.contrast(to: SketchPalette.houseTone) >= 1.30)
            }
        }
    }

    @Test("Ночью дом тусклее самой мелкой дороги")
    func nightHouseNeverOutshinesARoad() {
        // Иначе застройка читается сетью улиц — на тёмной схеме это прямая
        // ложь про то, где можно ехать.
        with(daylight: false) {
            #expect(SketchPalette.houseTone.luminance
                    < SketchPalette.asphaltTone(.service).luminance)
        }
    }

    @Test("Кайма отделяет полотно от земли в обеих темах")
    func casingDoesItsJob() {
        // Без каймы асфальт висит в пустоте на тёмном фоне и сливается с
        // землёй на светлом; днём это единственное, что отделяет белую дорогу
        // от серого города.
        for daylight in [false, true] {
            with(daylight: daylight) {
                #expect(SketchPalette.casingTone
                    .contrast(to: SketchPalette.asphaltTone(.residential)) >= 1.7)
            }
        }
        // Днём требование строже: ночью кайму подпирает тёмная земля, а днём
        // она одна отделяет белую дорогу от светлого города.
        with(daylight: true) {
            #expect(SketchPalette.casingTone
                .contrast(to: SketchPalette.asphaltTone(.residential)) >= 1.95)
        }
    }

    @Test("Разметка остаётся разметкой на дневном асфальте")
    func markingsStayVisible() {
        // Днём краска ТЕМНЕЕ полотна: белая краска на белом асфальте исчезает,
        // и меняется не яркость, а сторона контраста.
        with(daylight: true) {
            let road = SketchPalette.asphaltTone(.motorway)
            #expect(SketchPalette.markingTone.contrast(to: road) >= 2.5)
            #expect(SketchPalette.centerlineTone.contrast(to: road) >= 1.7)
            #expect(SketchPalette.laneDividerTone.contrast(to: road) >= 1.35)
            // Осевая делит ВСТРЕЧНЫЕ потоки, разделительная — попутные: два
            // разных запрета не имеют права выглядеть одним узором.
            #expect(SketchPalette.centerlineTone.contrast(to: road)
                    > SketchPalette.laneDividerTone.contrast(to: road))
        }
    }

    @Test("Подпись улицы читается")
    func labelIsReadable() {
        for daylight in [false, true] {
            with(daylight: daylight) {
                #expect(SketchPalette.labelTone.contrast(to: SketchPalette.groundTone) >= 5)
            }
        }
    }

    // MARK: - Что не меняется

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
        with(daylight: false) { night = SketchPalette.groundTone.luminance }
        with(daylight: true) { #expect(SketchPalette.groundTone.luminance > night + 0.3) }
    }

    @Test("Край растра гаснет в то, чем кончается карта")
    func edgeFadeFollowsTheTheme() {
        // Чёрная виньетка на светлой карте — не мягкий край, а грязная рама:
        // на дневных снимках она съедала десятую часть кадра с каждой стороны.
        with(daylight: true) { #expect(SketchPalette.edgeFade == SketchPalette.ground) }
        with(daylight: false) { #expect(SketchPalette.edgeFade == Color.black) }
    }
}
