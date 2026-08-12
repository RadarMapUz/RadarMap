//
//  CarPlayAhead.swift
//  RadarMap
//
//  «Что впереди» — лента ближайших камер по ходу движения для экрана машины.
//
//  Зачем она вообще появилась. Экран в машине широкий (обычно 2:1 и шире), а
//  и схема, и карта — виды «вперёд по курсу»: полезное живёт на вертикальной
//  оси, а горизонталь остаётся чёрной. Заполнять её украшением было бы враньём
//  ради красоты; заполнять дублем дока — бессмысленно, дистанцию до ближайшей
//  камеры он и так показывает. Здесь показывается то, чего не показывает
//  никто: что будет ПОСЛЕ ближайшей. «Камера через 200 метров, а за ней ещё
//  две в пределах километра» — это другое решение за рулём, чем одна камера и
//  чистая дорога дальше.
//
//  Решает, «наша ли это дорога», НЕ этот файл. Решает LocationGates — тот
//  самый гейт, которым отбирается ближайшая камера для дока и для голоса; он
//  приходит сюда параметром `isRelevant`.
//
//  Своего коридора здесь стояло две штуки подряд, и обе врали. Сперва широкий
//  трассовый — «лента перечисляет, а не глушит»; на экране это дало камеру в
//  137 метрах при доке «794 м». Потом городской — то же самое на тридцати
//  метрах: гейт оповещений отбрасывает камеру встречной стороны, а лента про
//  направление и дорожный профиль не знала вовсе. Обе цифры правдивы по-своему,
//  а вместе означают приложение, спорящее само с собой, — после такого водитель
//  не верит ни одной. Порядок и состав гейтов живут в одном месте, и лента
//  спрашивает их, а не пересказывает.
//
//  Без курса ленты нет вовсе: «впереди» без направления — это круг вокруг
//  машины, а не дорога.
//

import CoreLocation

nonisolated enum CarPlayAhead {

    /// Одна камера на ленте.
    struct Item: Equatable, Identifiable {
        let id: Int
        let kind: CameraType
        /// Расстояние ДО КАМЕРЫ — то же самое, что показывает док. Не проекция
        /// на курс: по ней лента считает порядок и место на шкале, но показать
        /// водителю два разных числа про одну камеру нельзя. Расхождение
        /// маленькое (метры), а «приложение спорит само с собой» — большое.
        let distance: CLLocationDistance
        /// Доля ленты: 0 — под нами, 1 — на дальнем её конце. Считается по
        /// проекции на курс: это и есть «сколько ещё ехать».
        var fraction: Double
        /// Та самая, о которой сейчас предупреждаем.
        let isTarget: Bool
    }

    /// Длина ленты. Два километра — потому что дальше водителю уже всё равно:
    /// на городских 60 это две минуты, на трассовых 100 — чуть больше минуты,
    /// а решение о торможении принимается на порядок раньше.
    static let rangeMeters: CLLocationDistance = 2000

    /// Сколько строк помещается и читается за рулём. Четвёртая уже не
    /// прочитывается боковым зрением, а лента из десяти — это список, который
    /// за рулём не читают вовсе.
    static let maxItems = 4

    /// Отобрать и разложить камеры по ленте.
    ///
    /// - Parameters:
    ///   - cameras: кандидаты (обычно окрестность из грид-индекса стора).
    ///   - coordinate: где мы.
    ///   - course: курс в градусах; отрицательный — курса нет, ленты нет.
    ///   - targetID: камера, о которой сейчас предупреждает голос.
    ///   - isRelevant: гейт «наша ли дорога» — тот же, что у оповещений.
    static func items(cameras: [Camera],
                      from coordinate: CLLocationCoordinate2D,
                      course: CLLocationDegrees,
                      targetID: Int?,
                      range: CLLocationDistance = rangeMeters,
                      limit: Int = maxItems,
                      isRelevant: (Camera) -> Bool) -> [Item] {
        guard course >= 0, range > 0 else { return [] }

        // Сначала дешёвое: направление и дальность — чистая арифметика.
        // Гейт спрашивается ПОТОМ и только про то, что уцелело, — он считает
        // геометрию дороги камеры, и в плотном центре разница между «спросить
        // про всех впереди» и «спросить про ближайших» — это 77 вызовов на тик
        // против пяти. Лента пересчитывается каждую секунду, так что порядок
        // здесь не стилистика (бюджет закреплён PerformanceBudgetTests).
        var candidates: [(camera: Camera, along: Double, distance: Double)] = []
        candidates.reserveCapacity(16)
        for camera in cameras {
            let fix = RoadCorridor.fix(from: coordinate, course: course,
                                       to: camera.coordinate)
            // Строго впереди: камера, которую мы уже проехали, на ленте
            // «что впереди» — ложь, даже если она в метре позади.
            guard fix.along > 0, fix.along <= range else { continue }
            candidates.append((camera, fix.along, hypot(fix.along, fix.across)))
        }
        candidates.sort { $0.distance < $1.distance }

        func item(_ candidate: (camera: Camera, along: Double, distance: Double)) -> Item {
            Item(id: candidate.camera.id, kind: candidate.camera.kind,
                 distance: candidate.distance,
                 fraction: min(1, candidate.along / range),
                 isTarget: candidate.camera.id == targetID)
        }

        // От ближней к дальней, пока не набрали строку. Дальше не спрашиваем
        // вовсе: то, что не поместится, гейту неинтересно.
        var found: [Item] = []
        found.reserveCapacity(limit)
        var targetSeen = false
        for candidate in candidates where found.count < limit {
            // Тревожную камеру гейт уже пропустил — её выбрал сам конвейер
            // оповещений. Спрашивать про неё второй раз незачем.
            let isTarget = candidate.camera.id == targetID
            guard isTarget || isRelevant(candidate.camera) else { continue }
            if isTarget { targetSeen = true }
            found.append(item(candidate))
        }

        // Тревожная камера обязана быть на ленте, даже если по расстоянию она
        // не попала в первые строки: лента, где её нет, спорит с голосом.
        if let targetID, !targetSeen,
           let target = candidates.first(where: { $0.camera.id == targetID }) {
            if found.count >= limit { found.removeLast() }
            found.append(item(target))
        }
        return found
    }

    /// Развести метки, которые встали друг на друга.
    ///
    /// Камеры на перекрёстке отстоят на десятки метров, а лента — на две
    /// тысячи: две точки садятся в один пиксель, и подписи накладываются
    /// буквально буква на букву. Читать такое нельзя, а прятать вторую камеру
    /// нельзя тем более — правило проекта прямое: камера никогда не пропадает
    /// молча.
    ///
    /// Поэтому раздвигаем: идём от ближней к дальней и, если зазор меньше
    /// `minGap`, отодвигаем следующую. Двигаем ТОЛЬКО дальние: ближняя камера
    /// важнее всех, и её место на шкале должно оставаться честным. Если у
    /// верхнего края место кончилось, дожимаем сверху вниз — тогда правду
    /// теряет самая дальняя строка, а не самая нужная.
    static func spread(_ items: [Item], minGap: Double) -> [Item] {
        guard items.count > 1, minGap > 0 else { return items }
        var result = items

        for index in 1..<result.count {
            let previous = result[index - 1].fraction
            if result[index].fraction - previous < minGap {
                result[index].fraction = previous + minGap
            }
        }
        // Уехали за верх — поджимаем сверху вниз.
        if let last = result.last?.fraction, last > 1 {
            result[result.count - 1].fraction = 1
            for index in stride(from: result.count - 2, through: 0, by: -1) {
                let next = result[index + 1].fraction
                if next - result[index].fraction < minGap {
                    result[index].fraction = max(0, next - minGap)
                }
            }
        }
        return result
    }

    /// Подпись под лентой: сколько камер впереди и в каком пределе.
    /// Считается по тем же строкам, что показаны, — цифра под лентой и точки
    /// на ней не должны расходиться.
    static func summary(_ items: [Item]) -> String? {
        guard let last = items.last, items.count > 1 else { return nil }
        return String(format: String(localized: "%1$lld · до %2$@"),
                      items.count, Formatting.distance(last.distance))
    }
}
