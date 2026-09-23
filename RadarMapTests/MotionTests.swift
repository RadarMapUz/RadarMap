//
//  MotionTests.swift
//  RadarMapTests
//
//  «Уменьшение движения». В коде было около 120 анимаций и ровно одна проверка
//  этой настройки — то есть настройки не было.
//

import SwiftUI
import XCTest
@testable import RadarMap

final class MotionTests: XCTestCase {

    /// Выключено — анимация проходит как есть, вид приложения не меняется.
    func testWithoutReduceMotionNothingChanges() throws {
        try XCTSkipIf(Motion.isReduced, "на этой машине включено «Уменьшение движения»")
        XCTAssertNotNil(Motion.ok(.snappy(duration: 0.3)))
        XCTAssertNotNil(Motion.ok(.default))
    }

    /// nil на входе остаётся nil при любой настройке: «без анимации» —
    /// это осознанный выбор места вызова, и обёртка его не переигрывает.
    func testNilStaysNil() {
        XCTAssertNil(Motion.ok(nil))
    }

    /// Главное свойство: обёртка НЕ «делает анимацию покороче».
    ///
    /// Сократить длительность вместо отключения — частая уступка и неверная:
    /// быстрое движение укачивает не меньше медленного, а иногда сильнее.
    /// Поэтому результат ровно двузначный — либо исходная анимация, либо nil.
    func testTheAnswerIsBinaryNotShortened() {
        let source = Animation.spring(duration: 1.6, bounce: 0.12)
        let result = Motion.ok(source)
        if Motion.isReduced {
            XCTAssertNil(result)
        } else {
            XCTAssertEqual(result, source)
        }
    }

    /// Прямых вызовов `withAnimation` и `.animation(_:value:)` в коде
    /// приложения быть не должно: каждый такой вызов — это место, где
    /// настройку доступности забыли. Сторожит именно ЭТО, а не поведение.
    ///
    /// Тест читает исходники: другого способа проверить «нигде не вызывается»
    /// у языка нет, а правило слишком легко нарушить следующей правкой.
    func testNoRawAnimationCallsRemainInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // RadarMapTests
            .deletingLastPathComponent()      // корень проекта
            .appendingPathComponent("RadarMap")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            // Сами обёртки обязаны звать оригиналы — это их работа.
            .filter { $0.lastPathComponent != "Motion.swift" } ?? []
        try XCTSkipIf(files.isEmpty, "исходники не найдены — тест запущен вне дерева проекта")

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }   // комментарии не код
                if code.contains("withAnimation(") || code.contains("withAnimation {")
                    || code.contains(".animation(") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "анимация мимо Motion (забыли «Уменьшение движения»): "
                      + offenders.joined(separator: ", "))
    }
}
