//
//  RoadSketchPixelTests.swift
//  RadarMapTests
//
//  Схема, измеренная по пикселям.
//
//  Всё остальное в проекте проверяет ЧИСЛА, дошедшие до рендера. Эти тесты
//  проверяют, что вышло на экран, и написаны они потому, что посмотреть на
//  схему глазами почти нельзя: она появляется только в движении, а экран
//  машины на симуляторе не открыть. Ширина проезжей части в метрах и разметка
//  между полосами — ровно те вещи, которые «собираются и не падают» при любой
//  ошибке и видны только картинкой.
//
//  Приём: рисуем сцену из одной дороги в ImageRenderer, читаем столбец
//  пикселей поперёк неё и меряем. Ни золотых картинок, ни сравнения байтов —
//  только два утверждения, которые обязаны быть верны при любой перерисовке:
//  ширина полотна равна метрам, помноженным на масштаб, а линий разметки
//  поперёк проезжей части ровно на одну меньше, чем полос.
//

import SwiftUI
import XCTest
@testable import RadarMap

@MainActor
final class RoadSketchPixelTests: XCTestCase {

    private let side: CGFloat = 420

    /// ОДНА на весь класс, как модель в CarPlayModeTests. Освобождение
    /// @MainActor-класса посреди теста роняет рантайм: хост перезапускается, и
    /// прогон отчитывается «Executed 0 tests» вместо осмысленного падения.
    /// Состояние здесь всё равно нулевое — вью читает из него смещение и курс,
    /// а мы меряем геометрию дороги.
    private static let state = SketchState()

    /// Яркость столбца пикселей поперёк дороги.
    private func column(lanes: Int, kind: RoadClass, span: Double) throws -> [Double] {
        var scene = RoadSketch.Scene()
        scene.spanBucket = span
        scene.spanAtBuild = span
        // Дорога поперёк вида, во всю ширину: столбец пересекает её один раз.
        scene.network = [
            RoadSketch.Line(points: [CGPoint(x: -400, y: 0), CGPoint(x: 400, y: 0)],
                            kind: kind, level: 0, isOneWay: false,
                            isDetailed: true, lanes: lanes),
        ]

        let view = RoadSketchView(scene: scene, state: Self.state)
            .frame(width: side, height: side)
            .background(SketchPalette.ground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)

        let width = cgImage.width, height = cgImage.height
        // Буфер выделяется ЯВНО и живёт дольше контекста. Массив Swift сюда
        // отдавать нельзя: CGContext держит указатель после выхода из inout,
        // и разбор картинки роняет процесс в куче.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        buffer.initialize(repeating: 0, count: width * height * 4)
        defer { buffer.deallocate() }
        let context = try XCTUnwrap(CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Не один столбец, а МАКСИМУМ по полосе столбцов, и это не сглаживание.
        // Разделительные пунктирные, фаза у всех линий дороги общая, и
        // единственный столбец с одинаковой вероятностью попадает в штрих или
        // в разрыв — тест мерил бы не разметку, а везение. Полоса шире периода
        // пунктира гарантированно накрывает штрих каждой линии.
        //
        // Полоса — у левого края: там нет ни компаса (правый верх), ни линейки
        // (левый низ), ни курсора «я» (центр).
        let from = width / 8, through = width / 8 + 16
        return (0..<height).map { y in
            (from...through).map { x -> Double in
                let i = (y * width + x) * 4
                return (Double(buffer[i]) + Double(buffer[i + 1])
                        + Double(buffer[i + 2])) / 765.0
            }.max() ?? 0
        }
    }

    /// Самый длинный непрерывный отрезок, на котором предикат верен.
    private func longestRun(_ values: [Double], where matches: (Double) -> Bool)
        -> (start: Int, length: Int) {
        var best = (start: 0, length: 0)
        var current = 0
        for (index, value) in values.enumerated() {
            if matches(value) {
                current += 1
                if current > best.length { best = (index - current + 1, current) }
            } else {
                current = 0
            }
        }
        return best
    }

    /// Сколько линий разметки пересекает полотно.
    ///
    /// Уровень чистого асфальта берётся МЕДИАНОЙ полосы, а не минимумом.
    /// Минимум лежит на сглаженном крае полотна и заметно темнее асфальта —
    /// порог от него оказывается НИЖЕ самой дороги, и вся она засчитывается
    /// одной сплошной линией. Разметка при этом может отсутствовать вовсе, а
    /// тест — молчать.
    private func markings(across band: [Double]) -> Int {
        guard band.count > 4 else { return 0 }
        let asphalt = band.sorted()[band.count / 2]
        return peaks(band, above: asphalt + 0.03)
    }

    /// Сколько раз яркость поднимается выше порога — то есть сколько светлых
    /// линий пересёк столбец.
    private func peaks(_ values: [Double], above threshold: Double) -> Int {
        var count = 0
        var inside = false
        for value in values {
            if value > threshold {
                if !inside { count += 1 }
                inside = true
            } else {
                inside = false
            }
        }
        return count
    }

    // MARK: - Ширина

    func testAsphaltIsAsWideAsItsMetres() throws {
        // Шестиполосный проспект: 6 x 3.75 = 22.5 м. При охвате 140 м на 420
        // точках это 3 пункта на метр, то есть 67 пунктов полотна.
        //
        // Меряем с допуском СНИЗУ, и это не слабость теста. Схема наклонена
        // (rotation3DEffect), и поперечник дороги на экране короче своей
        // истинной длины ровно на косинус наклона — примерно на десятую. Точное
        // число здесь было бы числом наклона, а не ширины; проверяем то, ради
        // чего работа делалась: полотно живёт в метрах, а не в пунктах класса.
        let span = RoadSketch.minSpanMeters
        let values = try column(lanes: 6, kind: .primary, span: span)
        let band = longestRun(values) { $0 > 0.1 }
        let expected = 6 * 3.75 * Double(side / CGFloat(span))

        XCTAssertGreaterThan(Double(band.length), expected * 0.8,
                             "полотно уже своих метров")
        XCTAssertLessThanOrEqual(Double(band.length), expected * 1.05,
                                 "полотно шире своих метров")
        // Прежняя ширина проспекта — 12 пунктов по классу. Если бы метры не
        // доехали, тут было бы около неё.
        XCTAssertGreaterThan(Double(band.length), 36, "нарисовано по классу, а не в метрах")
    }

    func testWidthScalesWithLanes() throws {
        // Отношение ширин НЕ зависит ни от наклона, ни от масштаба: обе дороги
        // одного класса, и вся разница между ними — число полос.
        let span = RoadSketch.minSpanMeters
        let wide = longestRun(try column(lanes: 6, kind: .primary, span: span)) { $0 > 0.1 }
        let narrow = longestRun(try column(lanes: 2, kind: .primary, span: span)) { $0 > 0.1 }
        XCTAssertEqual(Double(wide.length) / Double(narrow.length), 3, accuracy: 0.3,
                       "шесть полос обязаны быть втрое шире двух")
    }

    func testNarrowStreetIsNarrowOnScreen() throws {
        // Двор — одна полоса 4.5 м. Разница с проспектом впятеро, и она обязана
        // быть видна: ради неё метрическая ширина и вводилась.
        let span = RoadSketch.minSpanMeters
        let avenue = longestRun(try column(lanes: 6, kind: .primary, span: span)) { $0 > 0.1 }
        let yard = longestRun(try column(lanes: 1, kind: .service, span: span)) { $0 > 0.1 }
        XCTAssertGreaterThan(avenue.length, yard.length * 3,
                             "проспект обязан быть кратно шире двора")
    }

    func testOldFormulaStaysTheFloorWhenFarAway() throws {
        // На максимальном охвате метры дают волос, и дорога обязана остаться
        // видимой за счёт прежней формулы в пунктах.
        let values = try column(lanes: 1, kind: .service, span: RoadSketch.maxSpanMeters)
        let band = longestRun(values) { $0 > 0.1 }
        XCTAssertGreaterThanOrEqual(band.length, 2, "двор пропал с экрана вовсе")
    }

    // MARK: - Краска на асфальте

    /// Сколько светлых пятен в самой «полосатой» строке картинки.
    ///
    /// Строку зебры ищем перебором, а не считаем: сцена проходит через наклон
    /// и поворот, и вычислять, куда именно легла черта, значило бы повторять
    /// в тесте всю математику вью. Самая полосатая строка — это и есть зебра.
    private func stripiestRow(crossingAzimuth azimuth: Double) throws -> Int {
        var scene = RoadSketch.Scene()
        scene.spanBucket = RoadSketch.minSpanMeters
        scene.spanAtBuild = RoadSketch.minSpanMeters
        scene.network = [
            RoadSketch.Line(points: [CGPoint(x: 0, y: -200), CGPoint(x: 0, y: 200)],
                            kind: .primary, level: 0, isOneWay: false,
                            isDetailed: true, lanes: 6),
        ]
        // Переход ВПЕРЕДИ, а не под курсором: на месте «я» его перекрыл бы
        // сам курсор, и мерили бы мы его, а не зебру.
        scene.markings = [
            RoadSketch.Marking(point: CGPoint(x: 0, y: 60), kind: .crossing,
                               azimuthDegrees: azimuth, widthMeters: 22.5),
        ]

        let view = RoadSketchView(scene: scene, state: Self.state)
            .frame(width: side, height: side)
            .background(SketchPalette.ground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)

        let width = cgImage.width, height = cgImage.height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        buffer.initialize(repeating: 0, count: width * height * 4)
        defer { buffer.deallocate() }
        let context = try XCTUnwrap(CGContext(
            data: buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Ищем только там, где дорога, и только в верхней части кадра.
        // Иначе в «самую полосатую строку» попадает интерфейс: компас в правом
        // верхнем углу, линейка с подписью «50 м» в левом нижнем и курсор «я» —
        // всё это белое, и пятен в их строках больше, чем в любой зебре.
        var best = 0
        let from = width / 2 - 60, through = width / 2 + 60
        for y in 0..<(height * 2 / 5) {
            let row = (from...through).map { x -> Double in
                let i = (y * width + x) * 4
                return (Double(buffer[i]) + Double(buffer[i + 1])
                        + Double(buffer[i + 2])) / 765.0
            }
            // Краска ярче и асфальта, и любой линии вдоль дороги.
            best = max(best, peaks(row, above: 0.5))
        }
        return best
    }

    func testZebraReachesTheRaster() throws {
        // Полос зебры поперёк 22.5-метровой проезжей части — около двадцати.
        // Точное число зависит от сглаживания, поэтому сторожим порядок: ни
        // осевая, ни разделительные столько пятен в одной строке дать не могут.
        XCTAssertGreaterThan(try stripiestRow(crossingAzimuth: 0), 8,
                             "зебра не доехала до растра")
    }

    func testZebraLiesAcrossTheRoadNotAlongIt() throws {
        // Тот же переход, повёрнутый на 90°, ложится ВДОЛЬ дороги — и строка
        // пересекает его один раз, а не двадцать. Ошибка в азимуте не роняет
        // ничего и видна только так.
        let across = try stripiestRow(crossingAzimuth: 0)
        let along = try stripiestRow(crossingAzimuth: 90)
        XCTAssertGreaterThan(across, along * 3,
                             "черта легла вдоль дороги вместо поперёк")
    }

    func testMarkingWithoutWidthIsNotDrawn() throws {
        // Сервер не нашёл дороги под точкой — чертить нечем. Черта в ноль
        // метров была бы невидимой строкой в бюджете растра.
        var scene = RoadSketch.Scene()
        scene.spanBucket = RoadSketch.minSpanMeters
        let point = SketchPoint(coordinate: .init(latitude: 41.31, longitude: 69.25),
                                kind: .crossing, azimuthDegrees: 0, widthMeters: 0)
        XCTAssertTrue(point.kind.isPaint)
        XCTAssertFalse(point.kind.hasGlyph)
        XCTAssertTrue(scene.markings.isEmpty)
    }

    // MARK: - Разметка вдоль дороги

    func testMarkingsCountOneLessThanLanes() throws {
        // Главное утверждение о разметке, и оно же самое простое: шесть полос
        // разделены пятью линиями — осевой посередине и двумя парами
        // разделительных. Ошибка в раскладке видна здесь сразу, а на схеме —
        // только глазами и только в движении.
        let values = try column(lanes: 6, kind: .primary, span: RoadSketch.minSpanMeters)
        let band = longestRun(values) { $0 > 0.1 }
        let inside = Array(values[band.start..<(band.start + band.length)])
        XCTAssertEqual(markings(across: inside), 5,
                       "поперёк шестиполосной обязано быть пять линий разметки")
    }

    func testTwoLaneStreetHasOnlyTheCentreline() throws {
        let values = try column(lanes: 2, kind: .secondary, span: RoadSketch.minSpanMeters)
        let band = longestRun(values) { $0 > 0.1 }
        let inside = Array(values[band.start..<(band.start + band.length)])
        XCTAssertEqual(markings(across: inside), 1,
                       "у двухполосной разметка одна — осевая")
    }

    func testMarkingsVanishWhenThePaintWouldBeMoire() throws {
        // Порог у разделительных не по охвату, а по ширине полосы НА ЭКРАНЕ:
        // полоса в три пункта даёт рябь, а не пунктир.
        let values = try column(lanes: 6, kind: .primary, span: RoadSketch.maxSpanMeters)
        let band = longestRun(values) { $0 > 0.1 }
        guard band.length > 4 else { return }
        let inside = Array(values[band.start..<(band.start + band.length)])
        XCTAssertLessThanOrEqual(markings(across: inside), 1,
                                 "на дальнем охвате разделительных быть не должно")
    }
}
