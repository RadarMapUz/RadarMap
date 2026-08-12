//
//  CarPlayModeTests.swift
//  RadarMapTests
//
//  Переключение «Схема» ⇄ «Карта» на экране машины.
//
//  Тесты здесь про одну поломку, которую видно только в машине и никогда — на
//  симуляторе: содержимое ушло в один режим, а кнопки шаблона остались в
//  другом. Кнопки CarPlay живут вне цикла обновления SwiftUI, обновляет их
//  только пересборка шаблона, и та обязана случиться при КАЖДОЙ смене режима —
//  от кнопки, от автоматики жары, откуда угодно.
//
//  Отдельно проверяется, что свойство осталось НАБЛЮДАЕМЫМ. Это не паранойя:
//  у @Observable есть тонкость — свойство с наблюдателем (didSet) макрос
//  обрабатывает иначе, чем обычное хранимое, и потеря наблюдаемости здесь
//  означала бы, что экран вообще перестал переключаться.
//

import Observation
import XCTest
@testable import RadarMap

@MainActor
final class CarPlayModeTests: XCTestCase {

    /// ОДНА модель на весь класс, как в CameraStoreTests: освобождение
    /// @MainActor-класса посреди теста роняет рантайм, и создание модели на
    /// каждый метод давало «Executed 0 tests» с перезапуском хоста, а не
    /// осмысленное падение.
    private static let shared = CarPlayMapModel()

    /// Модель в заведомо известном состоянии.
    ///
    /// Поля сбрасываем явно: `init` читает Storage, а тестовый таргет живёт с
    /// общим UserDefaults — «водитель уже выбирал режим», оставшееся от
    /// прошлого прогона, глушило автоматику и роняло тест на ровном месте.
    private func model(chosen: Bool = false) -> CarPlayMapModel {
        let model = Self.shared
        model.onViewModeChanged = nil
        model.showsSketch = false
        model.userChoseView = chosen
        return model
    }

    // MARK: - Наблюдаемость

    func testModeStaysObservable() {
        // Если это упало — содержимое экрана перестало реагировать на кнопку,
        // и никакая пересборка шаблона уже не поможет.
        let model = model()
        var fired = false
        withObservationTracking {
            _ = model.showsSketch
        } onChange: {
            fired = true
        }
        model.showsSketch = true
        XCTAssertTrue(fired, "showsSketch обязан оставаться наблюдаемым")
    }

    // MARK: - Крючок пересборки шаблона

    func testHookFiresOnToggle() {
        let model = model()
        var calls = 0
        model.onViewModeChanged = { calls += 1 }
        model.toggleView()
        XCTAssertEqual(calls, 1, "кнопка обязана дёрнуть пересборку кнопок шаблона")
        XCTAssertTrue(model.showsSketch)
    }

    func testHookFiresOnThermalAutoSwitch() {
        // Жару замечает вью, а кнопки шаблона держит делегат: без крючка
        // содержимое уходило в схему, а кнопки оставались от карты.
        let model = model()
        var calls = 0
        model.onViewModeChanged = { calls += 1 }
        model.autoSwitch(for: .reduced)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.showsSketch)
    }

    func testHookIsSilentWhenNothingChanged() {
        // Пересборка шаблона на каждый тик — лишняя работа на экране, который
        // и так рисуется телефоном.
        let model = model()
        var calls = 0
        model.onViewModeChanged = { calls += 1 }
        model.autoSwitch(for: .full)      // уже карта
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Кто старше

    func testDriverChoiceOutranksHeat() {
        // Нажатая кнопка старше автоматики: иначе жара возвращала бы схему
        // сразу после того, как водитель выбрал карту руками.
        let model = model()
        model.toggleView()                // водитель выбрал схему
        model.toggleView()                // и передумал — карта
        XCTAssertFalse(model.showsSketch)
        model.autoSwitch(for: .minimal)   // телефон раскалился
        XCTAssertFalse(model.showsSketch, "выбор водителя не отменяется жарой")
    }

    func testAutoSwitchWorksUntilTheDriverChooses() {
        let model = model()
        model.autoSwitch(for: .reduced)
        XCTAssertTrue(model.showsSketch, "пока не выбирали — жара решает сама")
        model.autoSwitch(for: .full)
        XCTAssertFalse(model.showsSketch, "остыл — вернулись к карте")
    }
}
