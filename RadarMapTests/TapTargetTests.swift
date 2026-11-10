//
//  TapTargetTests.swift
//  RadarMapTests
//
//  Крестик закрытия — мишень пальца не меньше `Theme.controlSize`, даже
//  когда сам значок 12–20 pt.
//

import XCTest
@testable import RadarMap

final class TapTargetTests: XCTestCase {

    func testTheTargetIsTheControlSize() {
        XCTAssertGreaterThanOrEqual(Theme.controlSize, 44)
    }

    /// Каждый `xmark` в кнопке экранов телефона несёт `tapTarget()`,
    /// `controlCircle()` или размер `Theme.controlSize`. Тест читает
    /// исходники: правило легко нарушить следующей правкой.
    func testEveryCloseGlyphHasAFullTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RadarMap")
        // CarPlay касаний не получает; в ReportButton крестик — вспышка отказа
        // внутри самой кнопки «Радар!» (56 pt).
        let skipped: Set<String> = ["ReportButton.swift"]
        let files = ["Features", "DesignSystem"].flatMap { folder in
            FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                           includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && !skipped.contains($0.lastPathComponent) } ?? []
        }
        try XCTSkipIf(files.isEmpty, "исходники не найдены — тест запущен вне дерева проекта")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where line.contains("systemName: \"xmark") {
                let before = lines[max(0, index - 3)..<index].joined(separator: "\n")
                guard before.contains("Button") || before.contains("label:") else { continue }
                let after = lines[index..<min(lines.count, index + 9)].joined(separator: "\n")
                let sized = after.contains(".tapTarget(") || after.contains("controlCircle(")
                    || after.contains("Theme.controlSize")
                if !sized { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "крестик без мишени 44 pt: " + offenders.joined(separator: ", "))
    }
}
