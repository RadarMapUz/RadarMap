//
//  CameraAim.swift
//  RadarMap
//
//  Догадка о том, в какую сторону смотрит камера, — по тому, как у неё ездят.
//
//  Наблюдение простое и принадлежит водителю, а не нам: перед камерой, которая
//  тебя снимает, ты сбрасываешь газ, а сразу после — разгоняешься. Во встречном
//  направлении, если камера туда не смотрит, ничего такого не происходит: едешь
//  и едешь. Значит провал скорости, повторяющийся из проезда в проезд в ОДНУ
//  сторону и отсутствующий в другую, — это и есть след направления.
//
//  Зачем это нужно. Направление проезжей части доказано лишь у 336 камер из
//  3475: у остальных база молчит, и приложение честно отказывается молчать
//  вместе с ней. Собственные проезды — единственный источник, который может
//  что-то добавить к этому молчанию, не спрашивая ни сервер, ни чужие телефоны.
//
//  ЧТО ЭТОТ ВЕРДИКТ НЕ ДЕЛАЕТ — важнее того, что делает.
//
//  Он НЕ ГЛУШИТ НИ ОДНОГО ПРЕДУПРЕЖДЕНИЯ. Правило проекта: заглушить камеру
//  можно только по положительному доказательству, что она не наша, а это
//  догадка по поведению — и поведение объясняется десятком других причин.
//  Вердикт живёт в карточке камеры как наблюдение и больше нигде.
//
//  Он НЕ УХОДИТ НА СЕРВЕР. Профиль скорости у конкретной камеры с датами — это
//  маршрут человека, а весь проект построен на обратном обещании
//  (docs/plan_algorithms.md §7).
//
//  Конфаунды, из-за которых пороги такие строгие:
//
//    • светофор или лежачий полицейский сразу за камерой — тормозят ВСЕ и в
//      обе стороны. Лечится тем, что односторонний вердикт требует встречной
//      выборки, в которой провала НЕТ;
//    • пробка — лечится медианой вместо среднего: один затор не перевесит
//      десять спокойных проездов;
//    • привычка самого водителя — лечится требованием числа проездов в КАЖДОМ
//      направлении: сравниваются две выборки одного и того же человека.
//
//  Чистая логика — покрыта CameraAimTests.
//

import Foundation

nonisolated enum CameraAim {

    /// Что мы вправе сказать о направлении камеры по своим проездам.
    enum Verdict: Equatable {
        /// Данных мало или они противоречивы — молчим.
        case unknown
        /// Тормозят в обе стороны: это объясняется не камерой, а светофором,
        /// неровностью или затором. Направления тут нет.
        case bothWays
        /// Похоже, снимает едущих этим курсом (градусы, 0 — на север).
        case oneWay(Double)
    }

    /// Один проезд в пригодном для разбора виде.
    struct Sample: Equatable {
        /// Курс в точке траверса, градусы.
        let courseDegrees: Double
        /// Провал скорости: насколько быстрее ехали после камеры, чем у неё.
        let brakeKmh: Double
    }

    /// Разбор проездов одной камеры.
    ///
    /// `now` параметром, а не `Date()` внутри: расчёт обязан быть
    /// воспроизводимым в тестах — то же правило, что у PeriodSummary
    /// и CameraFamiliarity.
    static func verdict(passes: [PassedCamera], cameraID: Int, now: Date,
                        windowDays: Int = AppConfig.aimWindowDays,
                        minPerDirection: Int = AppConfig.aimMinPassesPerDirection,
                        minBrakeKmh: Double = AppConfig.aimMinBrakeKmh) -> Verdict {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        let samples = passes.compactMap { pass -> Sample? in
            guard pass.cameraID == cameraID, pass.date >= since,
                  let course = pass.courseDegrees, course >= 0,
                  let brake = pass.brakeDepthKmh else { return nil }
            return Sample(courseDegrees: course, brakeKmh: brake)
        }
        return verdict(samples: samples, minPerDirection: minPerDirection,
                       minBrakeKmh: minBrakeKmh)
    }

    /// То же самое над готовыми пробами — точка входа для тестов.
    static func verdict(samples: [Sample],
                        minPerDirection: Int = AppConfig.aimMinPassesPerDirection,
                        minBrakeKmh: Double = AppConfig.aimMinBrakeKmh) -> Verdict {
        guard samples.count >= minPerDirection * 2 else { return .unknown }

        // Опорное направление — курс самого свежего пригодного проезда. Любой
        // из двух потоков годится опорой: дальше они всё равно сравниваются
        // между собой, и кто из них «прямой», на вердикт не влияет.
        guard let reference = samples.first?.courseDegrees else { return .unknown }
        var forward: [Sample] = []
        var backward: [Sample] = []
        for sample in samples {
            let difference = GeoMath.angleDifference(sample.courseDegrees, reference)
            if difference <= AppConfig.aimBucketHalfAngle {
                forward.append(sample)
            } else if difference >= 180 - AppConfig.aimBucketHalfAngle {
                backward.append(sample)
            }
            // Всё остальное — поперечное движение: развязка, поворот у самой
            // камеры. К вопросу «куда она смотрит» это отношения не имеет.
        }

        // Обе выборки обязаны быть представительными. Без встречной сравнивать
        // не с чем, и «тормозит всегда» с равным правом объясняется привычкой
        // водителя, светофором и рельефом — то есть ничего не доказывает.
        guard forward.count >= minPerDirection, backward.count >= minPerDirection
        else { return .unknown }

        let forwardBrake = median(forward.map(\.brakeKmh))
        let backwardBrake = median(backward.map(\.brakeKmh))

        switch (forwardBrake >= minBrakeKmh, backwardBrake >= minBrakeKmh) {
        case (true, true):   return .bothWays
        case (true, false):  return .oneWay(meanBearing(forward.map(\.courseDegrees)))
        case (false, true):  return .oneWay(meanBearing(backward.map(\.courseDegrees)))
        case (false, false): return .unknown
        }
    }

    /// Медиана, а не среднее: одна пробка не должна решать вердикт.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Средний курс по кратчайшей дуге. Обычное среднее на курсах врёт:
    /// 350° и 10° дают 180°, то есть ровно противоположное направление.
    static func meanBearing(_ degrees: [Double]) -> Double {
        guard !degrees.isEmpty else { return 0 }
        var x = 0.0, y = 0.0
        for value in degrees {
            let radians = value * .pi / 180
            x += cos(radians)
            y += sin(radians)
        }
        let angle = atan2(y, x) * 180 / .pi
        return (angle + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Сторона света для фразы в карточке. Восемь румбов: «на северо-восток»
    /// человек представляет, «на 43°» — нет.
    static func cardinal(_ bearing: Double) -> String {
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 45).rounded()) % 8
        switch index {
        case 0:  return String(localized: "на север")
        case 1:  return String(localized: "на северо-восток")
        case 2:  return String(localized: "на восток")
        case 3:  return String(localized: "на юго-восток")
        case 4:  return String(localized: "на юг")
        case 5:  return String(localized: "на юго-запад")
        case 6:  return String(localized: "на запад")
        default: return String(localized: "на северо-запад")
        }
    }
}
