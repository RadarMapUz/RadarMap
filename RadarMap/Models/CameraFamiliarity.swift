//
//  CameraFamiliarity.swift
//  RadarMap
//
//  «Свои» камеры: те, что вы проезжаете регулярно и спокойно.
//
//  Дорога дом→работа проходит одни и те же восемь камер дважды в день. Через
//  две недели голос на них перестаёт быть помощью и становится шумом, и
//  дальше сценарий известен: человек выключает звук, приложение теряет весь
//  смысл, приложение удаляют. Это главный риск удержания у любого антирадара,
//  и лечится он не «сделать голос тише», а «замолчать там, где сказать нечего».
//
//  Условие намеренно строгое в одну сторону: камера становится своей, только
//  если её проезжали много раз И НИ РАЗУ с превышением за окно наблюдения.
//  Одно нарушение — и она снова говорит. Тишина здесь покупается доказанной
//  привычкой ездить у неё спокойно, а не просто частотой.
//

import Foundation

nonisolated enum CameraFamiliarity {
    /// Сколько спокойных проездов делают камеру своей.
    static let minPasses = 6
    /// За какое окно смотрим историю.
    static let windowDays = 30

    /// Идентификаторы «своих» камер по истории поездок.
    ///
    /// `now` параметром, а не `Date()` внутри: расчёт обязан быть
    /// воспроизводимым в тестах (то же правило, что у PeriodSummary).
    static func familiarIDs(history: [TripRecord], now: Date,
                            minPasses: Int = minPasses,
                            windowDays: Int = windowDays) -> Set<Int> {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        var calm: [Int: Int] = [:]
        var violated: Set<Int> = []

        for record in history where record.endedAt >= since {
            for pass in record.passed {
                guard pass.date >= since else { continue }
                // Превышение считаем по любому лимиту, включая предположенный:
                // здесь речь не о деньгах, а о том, можно ли молчать. Молчать
                // там, где человек регулярно превышает, нельзя.
                if let over = pass.overLimitKmh, over > FineSchedule.toleranceKmh {
                    violated.insert(pass.cameraID)
                } else {
                    calm[pass.cameraID, default: 0] += 1
                }
            }
        }

        return Set(calm.compactMap { id, count in
            count >= minPasses && !violated.contains(id) ? id : nil
        })
    }
}
