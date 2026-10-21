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

    /// «08:29 ETA 1 min 780 meter» под карточкой «120 m» (поездка 21.10):
    /// панель прибытия печатает единицу коротким стилем `string(from: unit)`,
    /// и метры там — слово. Остаток поездки — всегда километры, с десятой.
    func testTripDistanceIsAlwaysKilometres() {
        let near = CarPlayGuidanceMapping.tripDistance(meters: 780)
        XCTAssertEqual(near.unit, UnitLength.kilometers)
        XCTAssertEqual(near.value, 0.8, accuracy: 0.0001, "780 м — «0,8 км»")
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: 1_740).value, 1.7, accuracy: 0.0001)
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: 12_834).value, 12.8, accuracy: 0.0001)
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: 154_300).value, 154, accuracy: 0.0001,
                       "дальше сотни — целые, как печатает сама система")
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: 30).value, 0.1, accuracy: 0.0001,
                       "30 м до цели — не «0 км»: ещё не приехали")
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: 0).value, 0, accuracy: 0.0001)
        XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: -5).value, 0, accuracy: 0.0001)
        for meters in [1.0, 40, 780, 999, 1_000, 12_834, 154_300] {
            XCTAssertEqual(CarPlayGuidanceMapping.tripDistance(meters: meters).unit, UnitLength.kilometers,
                           "\(meters) м")
        }
    }

    /// Карточка манёвра и панель прибытия от километра показывают одно и то же
    /// число: «1,2 km» на повороте и «1,2 km» до цели, если поворот — последний.
    func testManeuverAndTripAgreeFromOneKilometre() {
        for meters in [1_000.0, 1_249, 8_460, 99_960, 154_300] {
            let maneuver = CarPlayGuidanceMapping.distance(meters: meters)
            let trip = CarPlayGuidanceMapping.tripDistance(meters: meters)
            XCTAssertEqual(maneuver.unit, trip.unit, "\(meters) м")
            XCTAssertEqual(maneuver.value, trip.value, accuracy: 0.0001, "\(meters) м")
        }
        XCTAssertEqual(CarPlayGuidanceMapping.distance(meters: 120).unit, UnitLength.meters,
                       "карточка манёвра ближе километра — метры: средний стиль печатает «120 m»")
    }

    /// Как CarPlay печатает каждую из двух строк (CarPlaySupport, iOS 26.2):
    /// панель прибытия — единица `string(from: unit)` коротким стилем, карточка
    /// манёвра — `string(from: measurement)` средним. В языках, на которых
    /// стоят телефоны наших водителей, обе единицы обязаны быть короткими —
    /// длинное слово («meter», «metr») и есть тот дефект.
    func testUnitsPrintShortInTheLanguagesOfOurPhones() {
        let locales = ["en_US", "en_GB", "ru_RU", "ru_UZ", "uz_Latn_UZ", "uz_Cyrl_UZ", "kk_KZ"]
        let tripUnit = MeasurementFormatter()
        tripUnit.unitStyle = .short
        tripUnit.unitOptions = .providedUnit
        let maneuverText = MeasurementFormatter()
        maneuverText.unitStyle = .medium
        maneuverText.unitOptions = .providedUnit
        for identifier in locales {
            tripUnit.locale = Locale(identifier: identifier)
            maneuverText.locale = Locale(identifier: identifier)
            for meters in [30.0, 780, 12_834] {
                let unit = tripUnit.string(from: CarPlayGuidanceMapping.tripDistance(meters: meters).unit)
                XCTAssertLessThanOrEqual(unit.count, 3, "\(identifier): панель прибытия «\(unit)»")
            }
            for meters in [120.0, 780, 12_834] {
                let text = maneuverText.string(from: CarPlayGuidanceMapping.distance(meters: meters))
                let unit = text.filter { $0.isLetter }
                XCTAssertLessThanOrEqual(unit.count, 2, "\(identifier): карточка манёвра «\(text)»")
            }
        }
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

    // MARK: - Ряд полос на экране машины

    func testLaneRowImageFitsTheCardLimit() throws {
        // Руководство CarPlay, стр. 48: ряд полос — картинка не больше 120×18 pt.
        let lanes = [LaneHint(arrows: [.left], isValid: false),
                     LaneHint(arrows: [.straight], isValid: false),
                     LaneHint(arrows: [.straight, .right], isValid: true),
                     LaneHint(arrows: [.right], isValid: true)]
        let image = try XCTUnwrap(CarPlayGuidance.laneImage(lanes, kind: .right))
        XCTAssertNotNil(image.cgImage)
        XCTAssertLessThanOrEqual(image.size.width, 120)
        XCTAssertLessThanOrEqual(image.size.height, 18)
    }

    func testLaneRowIsATextlessSecondManeuver() throws {
        // До 18.10 полосы уходили только в метаданные приборки (выключены) —
        // на экране машины их не было нигде.
        let lanes = [LaneHint(arrows: [.straight], isValid: false), LaneHint(arrows: [.right], isValid: true)]
        let row = try XCTUnwrap(CarPlayGuidance.laneRow(lanes, kind: .right))
        XCTAssertTrue(CarPlayGuidance.isLaneRow(row))
        // Текст не показывается (.symbolOnly), но вариант обязан быть: «You
        // must provide at least one variant» — с пустым машина вправе
        // выбросить манёвр (до 21.10 владелец полос в машине не видел).
        XCTAssertEqual(row.instructionVariants, [String(localized: "Из правого ряда")])
        XCTAssertNotNil(row.symbolImage)
        XCTAssertFalse(CarPlayGuidance.isLaneRow(CPManeuver()), "обычный манёвр — не ряд полос")
    }

    func testNoLanesNoRow() {
        XCTAssertNil(CarPlayGuidance.laneImage([], kind: .right))
        XCTAssertNil(CarPlayGuidance.laneRow([], kind: .right))
    }

    // MARK: - Карточка манёвра (20.3: вместо мини-карты — с какого края)

    private func leftTurn(lanes: [LaneHint] = [], approach: Int? = nil) -> RouteStep {
        RouteStep(distanceAlong: 800, text: "поверните налево на улицу Лабзак", icon: "arrow.turn.up.left",
                  kind: .left, lanes: lanes, shortText: "поверните налево", edge: .left,
                  approachLanes: approach)
    }

    /// Мини-карты развязки нет: владелец, 21.10 — «мини-карту убери».
    func testCardHasNoJunctionImage() {
        for step in [leftTurn(), leftTurn(approach: 3),
                     leftTurn(lanes: [LaneHint(arrows: [.left], isValid: true),
                                      LaneHint(arrows: [.straight], isValid: false)])] {
            let card = CarPlayGuidance.card(for: step, carDark: true, metadata: false)
            XCTAssertNil(card.maneuver.junctionImage)
            XCTAssertNil(card.maneuver.dashboardJunctionImage)
            XCTAssertNotNil(card.maneuver.symbolImage, "стрелка манёвра на месте")
        }
    }

    func testLaneRowGoesSecondWhenOSRMKnowsTheLanes() throws {
        let lanes = [LaneHint(arrows: [.left], isValid: true), LaneHint(arrows: [.straight], isValid: false),
                     LaneHint(arrows: [.straight], isValid: false)]
        let card = CarPlayGuidance.card(for: leftTurn(lanes: lanes, approach: 3), carDark: true, metadata: false)
        let row = try XCTUnwrap(card.laneRow)
        XCTAssertTrue(CarPlayGuidance.isLaneRow(row))
        XCTAssertEqual(card.maneuver.instructionVariants.first, "Поверните налево на улицу Лабзак",
                       "ряд показывают стрелки — в тексте края нет")
        XCTAssertNil(CarPlayGuidance.card(for: leftTurn(lanes: lanes), carDark: true, metadata: true).laneRow,
                     "с метаданными ряд не шлём: приборка прочла бы его вторым поворотом")
    }

    func testEdgeGoesIntoTheTextWithoutLaneData() {
        let card = CarPlayGuidance.card(for: leftTurn(approach: 2), carDark: false, metadata: false)
        XCTAssertNil(card.laneRow, "полосы по догадке не рисуем")
        let edge = String(localized: "левый ряд")
        XCTAssertEqual(card.maneuver.instructionVariants,
                       ["Поверните налево на улицу Лабзак, " + edge, "Поверните налево, " + edge, "Поверните налево"])
        XCTAssertEqual(card.maneuver.dashboardInstructionVariants, card.maneuver.instructionVariants)
        // Однополосный подъезд — края нет, фраза прежняя.
        XCTAssertEqual(CarPlayGuidance.card(for: leftTurn(approach: 1), carDark: false, metadata: false)
            .maneuver.instructionVariants, ["Поверните налево на улицу Лабзак", "Поверните налево"])
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
