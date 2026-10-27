//
//  TrafficTap.swift
//  RadarMap
//
//  Касание линии пробок (33H, «понятность»): что под пальцем — уровень,
//  «сейчас» или «обычно», длина участка, скорость и сколько он добавляет ко
//  времени. Карта отдаёт признаки линии (EngineMapView, `len`/`kmh`/`model`),
//  здесь из них — то, что скажет лист. Чистая логика, TrafficTapTests.
//

import Foundation

nonisolated struct TrafficTap: Identifiable, Equatable, Sendable {
    /// 1 свободно, 2 медленно, 3 пробка, 4 стоят (TrafficLines.displayLevel).
    let level: Int
    /// «Обычно в это время» (профиль 33G), а не данные водителей сейчас.
    let usual: Bool
    /// Длина участка одного уровня, м.
    let length: Double
    let kmh: Double
    /// Скорость графа на участке — «свободная» скорость, км/ч.
    let modelKmh: Double

    var id: String { "\(level)-\(usual)-\(Int(length))-\(Int(kmh))-\(Int(modelKmh))" }

    init(level: Int, usual: Bool, length: Double, kmh: Double, modelKmh: Double) {
        self.level = min(4, max(1, level))
        self.usual = usual
        self.length = max(0, length)
        self.kmh = max(0, kmh)
        self.modelKmh = max(0, modelKmh)
    }

    /// Из признаков линии на карте; без уровня или длины — не лист.
    init?(attributes: [String: Any]) {
        func number(_ key: String) -> Double? { (attributes[key] as? NSNumber)?.doubleValue }
        guard let level = number("level"), let length = number("len"), length > 0 else { return nil }
        self.init(level: Int(level), usual: number("src") == 1, length: length,
                  kmh: number("kmh") ?? 0, modelKmh: number("model") ?? 0)
    }

    /// Сколько участок добавляет ко времени против свободной скорости, с.
    /// Свободный — ноль (как у ETA: угадывать, что мы быстрее графа, не наше
    /// дело); скорость ниже 3 км/ч считается как 3 — «стоим», а не бесконечность.
    var delay: TimeInterval {
        guard level >= 2, modelKmh > 0, length > 0 else { return 0 }
        let slow = length / (max(3, kmh) / 3.6)
        let free = length / (modelKmh / 3.6)
        return max(0, slow - free)
    }

    /// Задержка для подписи: меньше минуты — не повод для «+0 мин».
    var shownDelay: TimeInterval? {
        delay >= AppConfig.trafficTapDelayFloorSeconds ? delay : nil
    }
}
