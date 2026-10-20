//
//  TwinCheck.swift
//  RadarMap
//
//  «Парная камера» как доказательство — только если пара и правда есть
//  (план 19.10, 11.2). `twin` из базы разрешает гейту направления глушить
//  камеру, когда едем по обратной стороне: её снимает парная. Но признак —
//  это запись снапа, а не камера: у 2009 и 2010 в v11 он стоит без всякой
//  камеры обратного направления рядом, а скрытие одной камеры пары
//  модератором (overrides) оставляет вторую «доказанной» без доказательства.
//  Молчание о камере требует доказательства, поэтому признак проверяется
//  по тому набору, по которому приложение и предупреждает: камера обратного
//  направления (больше `twinMinAngle`) в `twinMaxMeters`. Нет её — признака
//  нет, камера предупреждает в обе стороны.
//
//  Правило то же, что у снапа (server/snap_cameras.py, mark_direction_twins).
//  Чистая логика — TwinCheckTests.
//

import Foundation

nonisolated enum TwinCheck {

    /// Набор с проверенными парами и число снятых признаков.
    static func verified(_ cameras: [Camera]) -> (cameras: [Camera], dropped: Int) {
        let flagged = cameras.indices.filter { cameras[$0].twin == true }
        guard !flagged.isEmpty else { return (cameras, 0) }
        // Сетка ~110 м по камерам с направлением: соседей ищем в 3×3.
        let cell = 0.001
        var grid: [Int64: [Int]] = [:]
        for (index, camera) in cameras.enumerated() where camera.dir != nil {
            grid[key(Int(floor(camera.lat / cell)), Int(floor(camera.lon / cell))), default: []].append(index)
        }
        var result = cameras
        var dropped = 0
        for index in flagged {
            let camera = cameras[index]
            guard let dir = camera.dir else {
                result[index] = camera.withoutTwin()
                dropped += 1
                continue
            }
            let row = Int(floor(camera.lat / cell)), column = Int(floor(camera.lon / cell))
            var proven = false
            search: for dRow in -1...1 {
                for dColumn in -1...1 {
                    for other in grid[key(row + dRow, column + dColumn)] ?? [] where other != index {
                        let partner = cameras[other]
                        guard let partnerDir = partner.dir,
                              GeoMath.angleDifference(Double(dir), Double(partnerDir)) > AppConfig.twinMinAngle,
                              GeoMath.fastDistance(camera.lat, camera.lon, partner.lat, partner.lon)
                                <= AppConfig.twinMaxMeters else { continue }
                        proven = true
                        break search
                    }
                }
            }
            if !proven {
                result[index] = camera.withoutTwin()
                dropped += 1
            }
        }
        return (result, dropped)
    }

    private static func key(_ row: Int, _ column: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: column)))
    }
}
