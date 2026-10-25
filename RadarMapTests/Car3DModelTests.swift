//
//  Car3DModelTests.swift
//  RadarMapTests
//
//  «Машина 3D» (29.B): кадр без поворота зеркален, грани от камеры
//  отброшены, на виде сверху видна только крыша и капоты, ни одного
//  красного, кадр выбирается по ближайшему ракурсу с остатком ≤ полшага.
//

import XCTest
@testable import RadarMap

final class Car3DModelTests: XCTestCase {

    func testNoseUpFrameIsMirrorSymmetric() {
        for pitch in Car3DModel.pitches {
            let faces = Car3DModel.project(yaw: 0, pitch: pitch, scale: 10)
            let xs = faces.flatMap { $0.points.map(\.x) }
            XCTAssertEqual(xs.min() ?? 0, -(xs.max() ?? 0), accuracy: 1e-6, "наклон \(pitch)")
            // Каждой грани справа — зеркальная слева (по множеству точек).
            let keys = Set(faces.map { face in
                face.points.map { "\(Int(($0.x * 100).rounded())),\(Int(($0.y * 100).rounded()))" }.sorted()
                    .joined(separator: ";")
            })
            let mirrored = Set(faces.map { face in
                face.points.map { "\(Int((-$0.x * 100).rounded())),\(Int(($0.y * 100).rounded()))" }.sorted()
                    .joined(separator: ";")
            })
            XCTAssertEqual(keys, mirrored, "наклон \(pitch)")
        }
    }

    func testTopDownShowsOnlyCaps() {
        // Сверху (наклон 0) вертикальные борта и колёса не видны вовсе.
        let parts = Set(Car3DModel.project(yaw: 0, pitch: 0, scale: 10).map(\.part))
        XCTAssertFalse(parts.contains(.wheel))
        XCTAssertTrue(parts.contains(.roof))
        XCTAssertTrue(parts.contains(.hood))
    }

    func testObliqueFromBehindHidesHeadlightsAndShowsTail() {
        let behind = Set(Car3DModel.project(yaw: 0, pitch: 58, scale: 10).map(\.part))
        XCTAssertFalse(behind.contains(.headlight))
        XCTAssertTrue(behind.contains(.taillight))
        let front = Set(Car3DModel.project(yaw: 180, pitch: 58, scale: 10).map(\.part))
        XCTAssertTrue(front.contains(.headlight))
        XCTAssertFalse(front.contains(.taillight))
        // Боком под наклоном видны колёса.
        XCTAssertTrue(Car3DModel.project(yaw: 90, pitch: 48, scale: 10).contains { $0.part == .wheel })
    }

    func testCabinIsDrawnOverTheBody() {
        let faces = Car3DModel.project(yaw: 30, pitch: 48, scale: 10)
        let lastBody = faces.lastIndex { $0.part == .hood || $0.part == .body } ?? -1
        let firstCabin = faces.firstIndex { $0.part == .roof || $0.part == .glass } ?? .max
        XCTAssertLessThan(lastBody, firstCabin)
    }

    func testNoPartIsRed() {
        // Красный на карте — камера (правило курсора).
        for part in Car3DModel.Part.allCases {
            let c = part.rgb
            let isRed = c.r > 0.55 && c.r > c.g * 1.8 && c.r > c.b * 1.8
            XCTAssertFalse(isRed, "\(part)")
        }
    }

    func testFramePicksNearestViewWithSmallResidual() {
        var pick = Car3DModel.frame(relativeYaw: 0, pitch: 0)
        XCTAssertEqual(pick.frame, .init(yaw: 0, pitch: 0))
        pick = Car3DModel.frame(relativeYaw: 359, pitch: 57)
        XCTAssertEqual(pick.frame, .init(yaw: 0, pitch: Car3DModel.pitches.count - 1))
        XCTAssertEqual(pick.residual, -1, accuracy: 1e-9)
        pick = Car3DModel.frame(relativeYaw: -100, pitch: 30)
        XCTAssertEqual(pick.frame.yaw, 17)   // 260° → 17 × 15°
        XCTAssertEqual(pick.residual, 5, accuracy: 1e-9)
        XCTAssertEqual(Car3DModel.pitches[pick.frame.pitch], 35)
        for yaw in stride(from: -720.0, through: 720, by: 7.3) {
            let r = Car3DModel.frame(relativeYaw: yaw, pitch: 20).residual
            XCTAssertLessThanOrEqual(abs(r), Car3DModel.yawStep / 2 + 1e-9, "\(yaw)")
        }
    }
}
