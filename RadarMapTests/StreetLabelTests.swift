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
//  Сторожатся правила отбора, потому что цена ошибки здесь — не «некрасиво», а
//  «схема стала текстом»: подписей на экране размером в ладонь должно быть
//  мало, они не должны повторяться и не должны стоять вверх ногами.
//

import CoreGraphics
import XCTest
@testable import RadarMap

final class StreetLabelTests: XCTestCase {

    private func line(_ name: String, kind: RoadClass = .secondary,
                      from: CGPoint = .zero, to: CGPoint = CGPoint(x: 200, y: 0))
    -> RoadSketch.Line {
        RoadSketch.Line(points: [from, CGPoint(x: (from.x + to.x) / 2,
                                               y: (from.y + to.y) / 2), to],
                        kind: kind, level: 0, isOneWay: false, isDetailed: true,
                        name: name)
    }

    func testNamedStreetGetsALabel() {
        let labels = RoadSketch.labels(for: [line("Навои")])
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.first?.text, "Навои")
    }

    func testUnnamedStreetGetsNothing() {
        // Имя есть примерно у одной дороги из семи — это нормальное состояние,
        // а не повод рисовать пустую подпись.
        XCTAssertTrue(RoadSketch.labels(for: [line("")]).isEmpty)
    }

    func testShortStubIsNotLabelled() {
        // Строка длиннее самой дороги читается как подпись к соседней.
        let stub = line("Огрызок", from: .zero, to: CGPoint(x: 20, y: 0))
        XCTAssertTrue(RoadSketch.labels(for: [stub]).isEmpty)
    }

    func testOneStreetIsLabelledOnce() {
        // Склейка оставляет улицы целыми, но рядом бывает её же дубль.
        let labels = RoadSketch.labels(for: [
            line("Навои", from: .zero, to: CGPoint(x: 200, y: 0)),
            line("Навои", from: CGPoint(x: 0, y: 300), to: CGPoint(x: 200, y: 300)),
        ])
        XCTAssertEqual(labels.count, 1)
    }

    func testCrowdedLabelsAreThinnedOut() {
        // Две разные улицы вплотную — подписываем одну: на схеме размером в
        // ладонь две строки в тридцати метрах сливаются.
        let labels = RoadSketch.labels(for: [
            line("Первая", from: .zero, to: CGPoint(x: 200, y: 0)),
            line("Вторая", from: CGPoint(x: 0, y: 30), to: CGPoint(x: 200, y: 30)),
        ])
        XCTAssertEqual(labels.count, 1)
    }

    func testBiggerRoadWinsTheLabel() {
        // На перекрёстке проспекта с проездом подписать надо проспект.
        let labels = RoadSketch.labels(for: [
            line("Проезд", kind: .service, from: CGPoint(x: 0, y: 10),
                 to: CGPoint(x: 200, y: 10)),
            line("Проспект", kind: .primary, from: .zero,
                 to: CGPoint(x: 200, y: 0)),
        ])
        XCTAssertEqual(labels.first?.text, "Проспект")
        XCTAssertEqual(labels.count, 1)
    }

    func testBudgetIsRespected() {
        let many = (0..<40).map { index in
            line("Улица \(index)", from: CGPoint(x: 0, y: index * 200),
                 to: CGPoint(x: 200, y: index * 200))
        }
        XCTAssertEqual(RoadSketch.labels(for: many).count, RoadSketch.labelBudget)
    }

    func testLabelIsNeverUpsideDown() {
        // Улица, идущая справа налево, даёт угол около 180° — вверх ногами.
        // Он обязан быть приведён к читаемой половине круга.
        for (from, to) in [(CGPoint.zero, CGPoint(x: -200, y: 0)),
                           (CGPoint.zero, CGPoint(x: -200, y: -200)),
                           (CGPoint.zero, CGPoint(x: 0, y: -200))] {
            let labels = RoadSketch.labels(for: [line("Улица", from: from, to: to)])
            let angle = labels.first?.angle ?? 999
            XCTAssertLessThanOrEqual(abs(angle), 90.001,
                                     "подпись легла вверх ногами: \(angle)")
        }
    }

    func testLabelRunsAlongTheStreet() {
        // Подпись поперёк дороги читается как чужая: на перекрёстке непонятно,
        // к какой из двух она относится.
        let north = RoadSketch.labels(for: [
            line("Север", from: .zero, to: CGPoint(x: 0, y: 200))])
        XCTAssertEqual(abs(north.first?.angle ?? 0), 90, accuracy: 0.001)

        let east = RoadSketch.labels(for: [
            line("Восток", from: .zero, to: CGPoint(x: 200, y: 0))])
        XCTAssertEqual(east.first?.angle ?? 99, 0, accuracy: 0.001)
    }

    func testLabelSitsOnTheStreet() {
        let labels = RoadSketch.labels(for: [
            line("Навои", from: .zero, to: CGPoint(x: 200, y: 0))])
        XCTAssertEqual(labels.first?.point.x ?? 0, 100, accuracy: 1)
        XCTAssertEqual(labels.first?.point.y ?? 99, 0, accuracy: 1)
    }
}
