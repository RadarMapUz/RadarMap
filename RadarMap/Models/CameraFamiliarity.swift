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
    static var minPasses: Int { AppConfig.familiarMinPasses }
    /// За какое окно смотрим историю.
    static var windowDays: Int { AppConfig.familiarWindowDays }

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
                // Превышение считаем по ЛЮБОМУ лимиту, включая предположенный:
                // здесь речь не о деньгах, а о том, можно ли молчать. Молчать
                // там, где человек превышает, нельзя — камера в зоне 60
                // фиксирует уже на 66, и цена ошибки тут не «лишний совет», а
                // штраф, о котором мы промолчали.
                //
                // Лимит здесь — уже поднятый до пола фиксации (EnforcedLimit),
                // и это ровно та же логика, а не её послабление: вопрос был и
                // остаётся «возможен ли тут штраф». По тегу 50 на городской
                // улице штраф невозможен, и проезд на 55 больше не отнимает у
                // камеры право замолчать. Именно этот случай держал дорогу
                // дом→работа вечно говорящей.
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
