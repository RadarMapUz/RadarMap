//
//  StreetLabelTests.swift
//  RadarMapTests
//
//  Подписи улиц на схеме.
//
//  Единственное со снимка чужого навигатора, что у нас БЫЛО в данных и не
//  рисовалось: имя приезжает в тайле четвёртым элементом записи и до экрана не
//  доходило.
//
//  А когда дошло — не показалось. Подпись садилась в середину улицы,
//  посчитанной по ВСЕМУ растру (радиус 185–990 метров), а человек смотрит в
//  его сотую часть: середина уезжала за экран вместе с подписью. На четырёх
//  снимках живой поездки не было ни одной подписи при пяти-восьми
//  подписываемых улицах в кадре.
//
//  Поэтому подписи считаются от ТОЧКИ ЗРЕНИЯ, и главный тест здесь — тот, что
//  сажает подпись в видимую часть улицы, а не в её геометрическую середину.
//

import CoreGraphics
import XCTest
@testable import RadarMap

final class StreetLabelTests: XCTestCase {

    /// Точка зрения одна на все проверки: охват 400 м, вид вдвое уже своей
    /// высоты, 800 пунктов. Видно при этом восток −84…+84 м и север −72…+296.
    private let span = 400.0
    private let aspect = 0.5
    private let height = 800.0

    private func line(_ name: String, kind: RoadClass = .secondary,
                      from: CGPoint = CGPoint(x: -80, y: 0),
                      to: CGPoint = CGPoint(x: 80, y: 0)) -> RoadSketch.Line {
        RoadSketch.Line(points: [from, CGPoint(x: (from.x + to.x) / 2,
                                               y: (from.y + to.y) / 2), to],
                        kind: kind, level: 0, isOneWay: false, isDetailed: true,
                        name: name)
    }

    private func labels(_ lines: [RoadSketch.Line],
                        insets: RoadSketch.Insets = .none) -> [RoadSketch.Label] {
        RoadSketch.labels(for: lines, meOffset: .zero, courseDegrees: 0,
                          spanMeters: span, aspect: aspect, insets: insets,
                          viewHeight: height)
    }

    /// Где подпись оказалась на экране: доли ширины и высоты.
    private func seat(_ label: RoadSketch.Label,
                      insets: RoadSketch.Insets = .none) -> CGPoint {
        RoadSketch.screenPoint(label.point, meOffset: .zero, courseDegrees: 0,
                               spanMeters: span, aspect: aspect, insets: insets)
    }

    // MARK: - Что подписывается

    func testNamedStreetGetsALabel() {
        let out = labels([line("Навои")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "Навои")
    }

    func testUnnamedStreetGetsNothing() {
        // Имя есть примерно у одной дороги из семи — это нормальное состояние,
        // а не повод рисовать пустую подпись.
        XCTAssertTrue(labels([line("")]).isEmpty)
    }

    func testStreetOutOfViewIsNotLabelled() {
        // Улица за краем кадра подписи не получает: подпись, которой не видно,
        // стоит ровно столько же, сколько её отсутствие, но занимает бюджет.
        let far = line("Далёкая", from: CGPoint(x: 400, y: 400),
                       to: CGPoint(x: 600, y: 400))
        XCTAssertTrue(labels([far]).isEmpty)
    }

    func testNameMustFitTheVisiblePiece() {
        // Порог не в метрах, а в пунктах: длинное имя на коротком видимом
        // куске торчит за концы улицы и читается как подпись к соседней.
        let stub = line("Проспект имени Алишера Навои",
                        from: CGPoint(x: 78, y: 0), to: CGPoint(x: 96, y: 0))
        XCTAssertTrue(labels([stub]).isEmpty)
        // То же имя на видимой улице во весь кадр подписывается.
        XCTAssertEqual(labels([line("Проспект имени Алишера Навои")]).count, 1)
    }

    // MARK: - Главное: подпись садится в ВИДИМУЮ часть

    func testLabelSitsInsideTheView() {
        // Улица уходит далеко за правый край. Её геометрическая середина — за
        // экраном; подпись обязана сесть в тот кусок, который видно.
        let long = RoadSketch.Line(points: [CGPoint(x: -60, y: 0), CGPoint(x: 900, y: 0)],
                                   kind: .secondary, level: 0, isOneWay: false,
                                   isDetailed: true, name: "Длинная")
        guard let label = labels([long]).first else {
            return XCTFail("подписи нет вовсе")
        }
        XCTAssertLessThan(label.point.x, 200,
                          "подпись села в середину улицы, а не в видимый кусок")
        let seat = seat(label)
        XCTAssertTrue((0.05...0.95).contains(seat.x),
                      "подпись за краем кадра по горизонтали: \(seat.x)")
        XCTAssertTrue((0.02...0.98).contains(seat.y),
                      "подпись за краем кадра по вертикали: \(seat.y)")
    }

    func testLabelKeepsClearOfThePanels() {
        // Улица идёт поперёк там, где сверху стоит карточка скорости. Подпись
        // не вправе сесть под неё: закрытая панелью подпись — это та же
        // отсутствующая подпись, только оплаченная бюджетом.
        let insets = RoadSketch.Insets(top: 0.25, bottom: 0.1)
        func across(_ name: String, at north: Double) -> RoadSketch.Line {
            RoadSketch.Line(points: [CGPoint(x: -80, y: north), CGPoint(x: 80, y: north)],
                            kind: .secondary, level: 0, isOneWay: false,
                            isDetailed: true, name: name)
        }
        XCTAssertTrue(labels([across("Верхняя", at: 240)], insets: insets).isEmpty,
                      "подпись села под карточку скорости")
        // Та же улица под собой, в видимой части, подписывается как обычно.
        let seen = labels([across("Своя", at: 0)], insets: insets)
        XCTAssertEqual(seen.count, 1)
        XCTAssertGreaterThan(Double(seat(seen[0], insets: insets).y), insets.safeTop)
    }

    // MARK: - Отбор

    func testOneStreetIsLabelledOnce() {
        // Склейка оставляет улицы целыми, но рядом бывает её же дубль.
        let out = labels([
            line("Навои", from: CGPoint(x: -80, y: 0), to: CGPoint(x: 80, y: 0)),
            line("Навои", from: CGPoint(x: -80, y: 120), to: CGPoint(x: 80, y: 120)),
        ])
        XCTAssertEqual(out.count, 1)
    }

    func testCrowdedLabelsAreThinnedOut() {
        // Две разные улицы вплотную НА ЭКРАНЕ — подписываем одну. Мера здесь
        // экранная, а не земная: на охвате вблизи девяносто метров это весь
        // кадр, а на охвате района — палец.
        let out = labels([
            line("Первая", from: CGPoint(x: -80, y: 0), to: CGPoint(x: 80, y: 0)),
            line("Вторая", from: CGPoint(x: -80, y: 12), to: CGPoint(x: 80, y: 12)),
        ])
        XCTAssertEqual(out.count, 1)
    }

    func testBiggerRoadWinsTheLabel() {
        // На перекрёстке проспекта с проездом подписать надо проспект.
        let out = labels([
            line("Проезд", kind: .service, from: CGPoint(x: -80, y: 8),
                 to: CGPoint(x: 80, y: 8)),
            line("Проспект", kind: .primary),
        ])
        XCTAssertEqual(out.first?.text, "Проспект")
        XCTAssertEqual(out.count, 1)
    }

    func testBudgetIsRespected() {
        // Сетка коротких улиц: по экрану они разнесены дальше, чем порог
        // прореживания, поэтому в бюджет упирается именно счёт, а не он.
        var many: [RoadSketch.Line] = []
        for column in 0..<4 {
            for row in 0..<8 {
                let x = -70 + Double(column) * 44
                let y = -60 + Double(row) * 44
                many.append(line("У\(column)\(row)",
                                 from: CGPoint(x: x - 15, y: y),
                                 to: CGPoint(x: x + 15, y: y)))
            }
        }
        XCTAssertEqual(labels(many).count, RoadSketch.labelBudget)
    }

    // MARK: - Как она лежит

    func testLabelIsNeverUpsideDown() {
        // Улица, идущая справа налево, даёт угол около 180° — вверх ногами.
        // Он обязан быть приведён к читаемой половине круга.
        for (from, to) in [(CGPoint(x: 80, y: 0), CGPoint(x: -80, y: 0)),
                           (CGPoint(x: 60, y: 60), CGPoint(x: -60, y: -60)),
                           (CGPoint(x: 0, y: 80), CGPoint(x: 0, y: -80))] {
            let out = labels([line("Улица", from: from, to: to)])
            let angle = out.first?.angle ?? 999
            XCTAssertLessThanOrEqual(abs(angle), 90.001,
                                     "подпись легла вверх ногами: \(angle)")
        }
    }

    func testLabelRunsAlongTheStreet() {
        // Подпись поперёк дороги читается как чужая: на перекрёстке непонятно,
        // к какой из двух она относится.
        let north = labels([line("Север", from: CGPoint(x: 0, y: -60),
                                 to: CGPoint(x: 0, y: 60))])
        XCTAssertEqual(abs(north.first?.angle ?? 0), 90, accuracy: 0.001)

        let east = labels([line("Восток")])
        XCTAssertEqual(east.first?.angle ?? 99, 0, accuracy: 0.001)
    }

    func testLabelSitsAtTheMiddleByLengthNotByIndex() {
        // Вершины после Дугласа — Пекера лежат неравномерно: прямой участок —
        // одно звено, поворот — несколько подряд. Середина ИНДЕКСА уезжает в
        // поворот, а у прямой улицы, от которой осталось две точки, попадает
        // на конец — то есть подпись садится в перекрёсток.
        let uneven = RoadSketch.Line(
            points: [CGPoint(x: -80, y: 0), CGPoint(x: 60, y: 0),
                     CGPoint(x: 70, y: 0), CGPoint(x: 80, y: 0)],
            kind: .secondary, level: 0, isOneWay: false, isDetailed: true,
            name: "Неровная")
        XCTAssertEqual(labels([uneven]).first?.point.x ?? 99, 0, accuracy: 2,
                       "подпись села по номеру точки, а не по пути")
    }

    func testATwoPointStreetIsLabelledInTheMiddle() {
        // Самый частый случай на прямой улице: осталось ровно две вершины, и
        // середина индекса — это её КОНЕЦ.
        let straight = RoadSketch.Line(
            points: [CGPoint(x: -80, y: 0), CGPoint(x: 80, y: 0)],
            kind: .secondary, level: 0, isOneWay: false, isDetailed: true,
            name: "Прямая")
        XCTAssertEqual(labels([straight]).first?.point.x ?? 99, 0, accuracy: 2,
                       "подпись села на конец улицы")
    }

    // MARK: - Пересадка

    func testSeatedLabelStaysUntilItLeavesTheView() {
        // Подпись, пересчитываемая на каждом фиксе, ползала бы по улице.
        // Пока она на экране — стоит где стояла.
        XCTAssertTrue(RoadSketch.isSeated(CGPoint(x: 0, y: 0), meOffset: .zero,
                                          courseDegrees: 0, spanMeters: span,
                                          aspect: aspect))
        XCTAssertFalse(RoadSketch.isSeated(CGPoint(x: 0, y: 900), meOffset: .zero,
                                           courseDegrees: 0, spanMeters: span,
                                           aspect: aspect),
                       "подпись за краем считается сидящей — её никогда не пересадят")
    }

    func testSeatedRespectsThePanels() {
        // Та же кромка, что у посадки: подпись, уехавшая под карточку
        // скорости, обязана считаться слетевшей.
        let insets = RoadSketch.Insets(top: 0.3, bottom: 0.1)
        let underPanel = CGPoint(x: 0, y: 260)
        XCTAssertTrue(RoadSketch.isSeated(underPanel, meOffset: .zero, courseDegrees: 0,
                                          spanMeters: span, aspect: aspect))
        XCTAssertFalse(RoadSketch.isSeated(underPanel, meOffset: .zero, courseDegrees: 0,
                                           spanMeters: span, aspect: aspect,
                                           insets: insets))
    }
}
