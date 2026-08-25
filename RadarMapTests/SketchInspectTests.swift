//
//  SketchInspectTests.swift
//  RadarMapTests
//
//  Осмотр схемы: панорама и зум.
//
//  Тесты здесь про ВОЗВРАТ больше, чем про сам сдвиг. Панорама без возврата —
//  не половина функции, а ловушка: экран, молча оставшийся не там, где машина,
//  это самое опасное, что можно сделать за рулём.
//

import CoreGraphics
import XCTest
@testable import RadarMap

final class SketchInspectTests: XCTestCase {

    /// ОДИН экземпляр на весь прогон, как у CameraStoreTests: освобождение
    /// @MainActor-класса посреди теста роняет рантайм — на этом уже спотыкались,
    /// и запись об этом лежит в CLAUDE.md. Между тестами состояние
    /// возвращается к машине, а не пересоздаётся.
    @MainActor private static let shared = SketchState()

    @MainActor
    private func freshState() -> SketchState {
        let state = Self.shared
        state.returnToMe()
        state.viewHeight = 400
        return state
    }

    // MARK: - Перевод экрана в сцену

    func testDragMovesTheWorldWithTheFinger() {
        // Палец тянет МИР, значит центр вида уезжает в противоположную
        // сторону. Курс ноль: экран и сцена совпадают по осям.
        let delta = RoadSketch.sceneOffset(fromScreen: CGSize(width: 100, height: 0),
                                           courseDegrees: 0, spanMeters: 200,
                                           viewHeight: 400)
        XCTAssertEqual(Double(delta.width), -50, accuracy: 0.01,
                       "тянем вправо — центр вида уходит на запад")
        XCTAssertEqual(Double(delta.height), 0, accuracy: 0.01)
    }

    func testDragRespectsRotation() {
        // Схема повёрнута по курсу, палец тянет по экрану — значит перевод
        // обязан учитывать поворот. На курсе 90° «вверх по экрану» это восток.
        let delta = RoadSketch.sceneOffset(fromScreen: CGSize(width: 0, height: -100),
                                           courseDegrees: 90, spanMeters: 200,
                                           viewHeight: 400)
        XCTAssertEqual(Double(delta.width), -50, accuracy: 0.01)
        XCTAssertEqual(Double(delta.height), 0, accuracy: 0.01)
    }

    func testScreenAndSceneConversionsAreInverse() {
        // screenOffset и sceneOffset — обратные друг другу, и разойтись им
        // нельзя: одной курсор ставится на экран, другой палец переводится в
        // метры, и обе описывают одну и ту же проекцию.
        for course in [0.0, 37, 90, 180, 271] {
            let scene = CGSize(width: 120, height: -75)
            let screen = RoadSketch.screenOffset(fromScene: scene,
                                                 courseDegrees: course,
                                                 spanMeters: 300, viewHeight: 600)
            let back = RoadSketch.sceneOffset(fromScreen: screen,
                                              courseDegrees: course,
                                              spanMeters: 300, viewHeight: 600)
            XCTAssertEqual(Double(back.width), -Double(scene.width), accuracy: 0.01)
            XCTAssertEqual(Double(back.height), -Double(scene.height), accuracy: 0.01)
        }
    }

    // MARK: - Осмотр и возврат

    @MainActor
    func testPanDetachesTheViewFromTheCar() {
        let state = freshState()
        XCTAssertFalse(state.isInspecting)
        state.beginInspect()
        state.pan(by: CGSize(width: 80, height: 0))
        XCTAssertTrue(state.isInspecting)
        XCTAssertNotEqual(state.viewOffset, .zero, "вид обязан отвязаться")
    }

    @MainActor
    func testReturnBringsTheViewBackToTheCar() {
        let state = freshState()
        state.beginInspect()
        state.pan(by: CGSize(width: 120, height: 60))
        state.returnToMe()
        XCTAssertFalse(state.isInspecting)
        XCTAssertEqual(state.cursorOffset, .zero)
        XCTAssertEqual(state.viewOffset, state.meOffset)
    }

    @MainActor
    func testZoomStaysInsideTheSameBoundsAsAutomatic() {
        // Свободный зум до сантиметров дал бы дрожание от шума GPS, до
        // километров — пустой экран. Границы те же, что у автоматики.
        let state = freshState()
        state.beginInspect()
        for _ in 0..<40 { state.zoom(by: 1.6) }
        XCTAssertGreaterThanOrEqual(state.inspectSpanForTests ?? 0,
                                    RoadSketch.minSpanMeters)
        for _ in 0..<80 { state.zoom(by: 0.5) }
        XCTAssertLessThanOrEqual(state.inspectSpanForTests ?? .infinity,
                                 RoadSketch.maxSpanMeters)
    }

    @MainActor
    func testReturnWithoutInspectingIsHarmless() {
        let state = freshState()
        state.returnToMe()
        XCTAssertFalse(state.isInspecting)
    }

    func testReturnDelayIsShortEnoughToBeSafe() {
        // Дольше — и водитель успевает забыть, что смотрит не туда, где едет.
        XCTAssertLessThanOrEqual(RoadSketch.inspectReturnSeconds, 8)
        XCTAssertGreaterThanOrEqual(RoadSketch.inspectReturnSeconds, 3)
    }

    // MARK: - Курс есть не всегда

    @MainActor
    func testSketchShowsNorthUpBeforeTheFirstCourse() {
        // Холодный старт на стоянке: где мы — известно точно, куда смотрим —
        // нет. Поворачивать наугад нельзя, но и прятать схему незачем: пустой
        // экран говорит «сломалось», а север вверху — «стоим».
        let state = freshState()
        XCTAssertFalse(state.hasCourse)
        XCTAssertEqual(state.courseDegrees, 0,
                       "без курса схема не повёрнута, а не повёрнута наугад")
    }

    func testCourseStaysWhenStandingStill() {
        // Встали на светофоре: сырой курс уходит в −1, но прошлый остаётся
        // честным описанием того, как машина стоит.
        XCTAssertEqual(RoadSketch.unwound(137, towards: -1), 137)
        XCTAssertNil(RoadSketch.unwound(nil, towards: -1),
                     "а вот выдумывать первый курс нельзя")
    }
}
