//
//  CarPlayGuidanceTests.swift
//  RadarMapTests
//
//  Перевод маршрута в навигационную сессию CarPlay: полосы, тип манёвра,
//  оценки. Сама сессия живёт только в машине — здесь проверяется то, что
//  ей отдаётся.
//

import CarPlay
import XCTest
@testable import RadarMap

final class CarPlayGuidanceTests: XCTestCase {

    func testLanesHighlightOnlyTheWayWeGo() {
        // «налево на Шарафа Рашидова»: [налево ✓, прямо+налево ✓, прямо ✗, направо ✗]
        let hints = [LaneHint(arrows: [.left], isValid: true),
                     LaneHint(arrows: [.straight, .left], isValid: true),
                     LaneHint(arrows: [.straight], isValid: false),
                     LaneHint(arrows: [.right], isValid: false)]
        let lanes = CarPlayGuidanceMapping.lanes(hints, kind: .left)
        XCTAssertEqual(lanes[0], .init(angles: [], highlighted: -90))
        XCTAssertEqual(lanes[1], .init(angles: [0], highlighted: -90),
                       "на «прямо и налево» подсвечено налево — туда, куда манёвр")
        XCTAssertEqual(lanes[2], .init(angles: [0], highlighted: nil))
        XCTAssertEqual(lanes[3], .init(angles: [90], highlighted: nil))
        XCTAssertTrue(CarPlayGuidanceMapping.isUseful(lanes))
    }

    func testHighlightedAngleIsNeverRepeatedInAngles() {
        let lanes = CarPlayGuidanceMapping.lanes([LaneHint(arrows: [.right, .right, .straight], isValid: true)],
                                                 kind: .right)
        XCTAssertEqual(lanes, [.init(angles: [0], highlighted: 90)], "так требует CPLane")
    }

    func testRowWithNothingToChooseIsNotShown() {
        let allGood = CarPlayGuidanceMapping.lanes([LaneHint(arrows: [.straight], isValid: true),
                                                    LaneHint(arrows: [.straight], isValid: true)], kind: .straight)
        XCTAssertFalse(CarPlayGuidanceMapping.isUseful(allGood))
        XCTAssertFalse(CarPlayGuidanceMapping.isUseful([]))
    }

    func testLeftIsNegativeRightIsPositive() {
        for arrow in [LaneArrow.slightLeft, .left, .sharpLeft, .uturn, .mergeToLeft] {
            XCTAssertLessThan(CarPlayGuidanceMapping.laneAngle(arrow), 0, "\(arrow)")
        }
        for arrow in [LaneArrow.slightRight, .right, .sharpRight, .mergeToRight] {
            XCTAssertGreaterThan(CarPlayGuidanceMapping.laneAngle(arrow), 0, "\(arrow)")
        }
        XCTAssertEqual(CarPlayGuidanceMapping.laneAngle(.straight), 0)
    }

    func testManeuverTypes() {
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.left), .leftTurn)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.slightRight), .slightRightTurn)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.roundabout), .enterRoundabout)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(.arrive), .arriveAtDestination)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverType(nil), .noTurn,
                       "MKDirections типа не сообщает — не выдумываем")
    }

    func testTimeToManeuverIsShareOfRemainingTime() {
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 500, remainingDistance: 2000,
                                                             remainingTime: 400), 100)
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 5000, remainingDistance: 2000,
                                                             remainingTime: 400), 400, "не дольше всего пути")
        XCTAssertEqual(CarPlayGuidanceMapping.timeToManeuver(stepDistance: 500, remainingDistance: 0,
                                                             remainingTime: 400), 0)
    }

    func testEstimatesAreSentOnlyWhenTheNumberChanges() {
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: nil, current: 300, elapsed: 0))
        XCTAssertFalse(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 295, elapsed: 1))
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 284, elapsed: 1))
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 80, current: 69, elapsed: 1), "вблизи — шаг 10 м")
        XCTAssertFalse(CarPlayGuidanceMapping.shouldUpdate(previous: 20_000, current: 19_500, elapsed: 1),
                       "вдали — шаг 5 %")
        XCTAssertTrue(CarPlayGuidanceMapping.shouldUpdate(previous: 300, current: 300,
                                                          elapsed: AppConfig.carPlayEstimateMaxInterval),
                      "на стоянке цифра всё равно освежается")
    }

    /// «12,834 meter» на панели прибытия: система печатает в той единице, в
    /// какой дали. От километра — километры с десятой, ближе — метры по 10.
    func testDistanceGoesToTheCarInReadableUnits() {
        let far = CarPlayGuidanceMapping.distance(meters: 12_834)
        XCTAssertEqual(far.unit, UnitLength.kilometers)
        XCTAssertEqual(far.value, 12.8, accuracy: 0.001)
        let near = CarPlayGuidanceMapping.distance(meters: 347)
        XCTAssertEqual(near.unit, UnitLength.meters)
        XCTAssertEqual(near.value, 350, accuracy: 0.001)
        XCTAssertEqual(CarPlayGuidanceMapping.distance(meters: 154_300).value, 154, accuracy: 0.001)
        XCTAssertEqual(CarPlayGuidanceMapping.distance(meters: -5).value, 0, accuracy: 0.001)
    }

    /// Варианты фразы — от полной к короткой, с заглавной, без повторов.
    func testInstructionVariantsGoFromLongToShort() {
        let variants = CarPlayGuidanceMapping.instructionVariants(
            text: "поверните налево на улицу Амира Темура", shortText: "поверните налево")
        XCTAssertEqual(variants, ["Поверните налево на улицу Амира Темура", "Поверните налево"])
        XCTAssertEqual(CarPlayGuidanceMapping.instructionVariants(text: "вы прибыли", shortText: nil),
                       ["Вы прибыли"])
        XCTAssertEqual(CarPlayGuidanceMapping.instructionVariants(text: "разворот", shortText: "разворот"),
                       ["Разворот"])
    }

    // MARK: - Метаданные для приборки

    func testJunctionTypeAndExitAngle() {
        XCTAssertEqual(CarPlayGuidanceMapping.junctionType(.roundabout), .roundabout)
        XCTAssertEqual(CarPlayGuidanceMapping.junctionType(.left), .intersection)
        XCTAssertEqual(CarPlayGuidanceMapping.exitAngle(.left), -90)
        XCTAssertEqual(CarPlayGuidanceMapping.exitAngle(.slightRight), 45)
        XCTAssertNil(CarPlayGuidanceMapping.exitAngle(.arrive), "прибытие — не поворот")
        // Угол съезда — то же соглашение, что у полос: 0 прямо, минус влево.
        XCTAssertEqual(CarPlayGuidanceMapping.exitAngle(.sharpLeft), CarPlayGuidanceMapping.laneAngle(.sharpLeft))
    }

    func testManeuverStateFollowsTheApproach() {
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverState(distance: 1_200, sinceShown: 1), .initial)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverState(distance: 1_200, sinceShown: 30), .continue)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverState(distance: 300, sinceShown: 30), .prepare)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverState(distance: 30, sinceShown: 30), .execute)
        XCTAssertEqual(CarPlayGuidanceMapping.maneuverState(distance: 30, sinceShown: 1), .execute,
                       "у самого поворота — «выполняй», даже если манёвр новый")
    }

    // MARK: - Значок манёвра

    func testManeuverSymbolIsARealImageTheManeuverKeeps() {
        // До 2.2.15 здесь был nil: пустой UIImageAsset возвращал nil, и в
        // машине карточка манёвра шла без стрелки («стрелка false», carplay11).
        for onDark in [false, true] {
            let image = CarPlayGuidance.symbol("arrow.turn.up.right", pointSize: 34, onDark: onDark)
            XCTAssertNotNil(image?.cgImage, "значок обязан быть растром, onDark=\(onDark)")
            let maneuver = CPManeuver()
            maneuver.symbolImage = image
            maneuver.notificationSymbolImage = image
            maneuver.dashboardSymbolImage = image
            XCTAssertNotNil(maneuver.symbolImage)
            XCTAssertNotNil(maneuver.notificationSymbolImage)
            XCTAssertNotNil(maneuver.dashboardSymbolImage)
        }
    }

    func testUnknownSymbolFallsBackToAnArrow() {
        XCTAssertNotNil(CarPlayGuidance.symbol("нет.такого.символа", pointSize: 34, onDark: false)?.cgImage)
    }

    func testSymbolColourMatchesTheCardBackground() throws {
        // Белая стрелка на белой карточке днём уже была (11.10) — цвет обязан
        // идти от фона.
        let light = try XCTUnwrap(Self.inkBrightness(CarPlayGuidance.symbol("arrow.up", pointSize: 34, onDark: false)))
        let dark = try XCTUnwrap(Self.inkBrightness(CarPlayGuidance.symbol("arrow.up", pointSize: 34, onDark: true)))
        XCTAssertLessThan(light, 0.2, "на светлой карточке — тёмная стрелка")
        XCTAssertGreaterThan(dark, 0.8, "на тёмной карточке — светлая стрелка")
    }

    /// Средняя яркость непрозрачных пикселей картинки (0 — чёрный, 1 — белый).
    private static func inkBrightness(_ image: UIImage?) -> Double? {
        guard let cg = image?.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0, count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let alpha = Double(pixels[i + 3])
            sum += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 3 / alpha
            count += 1
        }
        return count > 0 ? sum / count : nil
    }
}
