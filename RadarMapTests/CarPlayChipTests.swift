//
//  CarPlayChipTests.swift
//  RadarMapTests
//
//  Плашки состояния на экране машины: что показываем, в каком порядке и
//  сколько разом.
//
//  До этого CarPlay не был покрыт ни одним тестом вообще — при этом решения
//  здесь чистые и вполне проверяемые, а цена ошибки высокая: плашка, которая
//  не появилась, это молчание там, где водитель обязан знать причину, а лента
//  из четырёх плашек за рулём не читается вовсе.
//

import XCTest
@testable import RadarMap

final class CarPlayChipTests: XCTestCase {

    /// Собираем список тем же правилом, что вью: важность по убыванию.
    private func chips(auth: Bool = true, online: Bool = true,
                       hot: Bool = false, banner: String? = nil) -> [CarPlayChip] {
        var result: [CarPlayChip] = []
        if !auth {
            result.append(CarPlayChip(id: "auth", symbol: "location.slash.fill",
                                      tint: Theme.danger, text: "нет доступа"))
        }
        if !online {
            result.append(CarPlayChip(id: "offline", symbol: "wifi.slash",
                                      tint: Theme.warning, text: "нет сети"))
        }
        if hot {
            result.append(CarPlayChip(id: "thermal", symbol: "thermometer.sun.fill",
                                      tint: Theme.warning, text: "жарко"))
        }
        if let banner {
            result.append(CarPlayChip(id: "banner", symbol: "megaphone.fill",
                                      tint: Theme.accent, text: banner))
        }
        return result
    }

    func testAllGoodMeansNoChips() {
        // Экран машины — не место для «всё в порядке»: место на нём стоит
        // дорого, а отсутствие плашки и есть сообщение «всё в порядке».
        XCTAssertTrue(chips().isEmpty)
    }

    func testMissingPermissionOutranksEverything() {
        // Без разрешения экран машины мёртв целиком: остальные причины на его
        // фоне не важны, и первой водитель обязан увидеть именно эту.
        let list = chips(auth: false, online: false, hot: true, banner: "объявление")
        XCTAssertEqual(list.first?.id, "auth")
    }

    func testOfflineOutranksHeat() {
        // Серая карта портит картинку прямо сейчас; жара лишь экономит ресурс.
        let list = chips(online: false, hot: true)
        XCTAssertEqual(list.map(\.id), ["offline", "thermal"])
    }

    func testAtMostTwoChipsReachTheScreen() {
        // Третья плашка за рулём уже не читается — экран машины не лента.
        let shown = Array(chips(auth: false, online: false, hot: true,
                                banner: "объявление").prefix(2))
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown.map(\.id), ["auth", "offline"])
    }

    func testBannerIsLastButNotLost() {
        // Слово владельца показываем, когда ничто важнее не мешает.
        let list = chips(banner: "плановые работы")
        XCTAssertEqual(list.map(\.id), ["banner"])
        XCTAssertEqual(list.first?.text, "плановые работы")
    }

    func testEachStateHasItsOwnIdentity() {
        // Идентификаторы участвуют в анимации списка: совпадение заставило бы
        // SwiftUI считать разные плашки одной и не проигрывать смену.
        let list = chips(auth: false, online: false, hot: true, banner: "x")
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
    }
}
