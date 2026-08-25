//
//  RoadGeneralise.swift
//  RadarMap
//
//  Генерализация дорожной сети: превращение сырых OSM-линий в то, что можно
//  показать водителю.
//
//  До этого файла схема чертила ровно то, что лежит в тайлах: каждый way —
//  отдельным штрихом с круглыми концами. На экране это давало не карту, а
//  спагетти — обрубки-«таблетки» там, где один way кончается и начинается
//  следующий, лесенки парковочных проездов, гребёнку дворовых карманов и
//  одинаковую мелочь на любом масштабе. Настоящие навигаторы так не делают
//  никогда: между данными и пером у них стоит генерализация, и именно она,
//  а не подбор цветов, отличает карту от чертежа.
//
//  Четыре шага, все — чистая геометрия:
//    1. ОТБОР ПО МАСШТАБУ. Чем шире охват, тем крупнее минимальный класс.
//       На трёхстах метрах дворовый карман — шум, на ста сорока — местность.
//    2. СКЛЕЙКА. Ways с общим концом и одинаковым характером сшиваются в одну
//       ломаную. Круглые концы исчезают сами: их больше негде ставить.
//    3. ОТСЕВ ОБРУБКОВ. То, что после склейки короче порога, — не дорога, а
//       хвост геометрии.
//    4. УПРОЩЕНИЕ. Дугласа—Пекера по допуску масштаба: меньше точек, чище
//       линия, дешевле растр.
//
//  Ничего не выдумывается: генерализация только УБИРАЕТ и СШИВАЕТ. Линию,
//  класса которой источник не знает, ни один шаг не трогает — скрывать то,
//  чего не знаешь, здесь нельзя так же, как в оповещениях.
//

import CoreGraphics
import Foundation

nonisolated enum RoadGeneralise {

    // MARK: - 1. Отбор по масштабу

    /// Место класса в иерархии: 0 — магистраль, 8 — то, чего мы не знаем.
    static func rank(_ kind: RoadClass) -> Int {
        switch kind {
        case .motorway:    return 0
        case .trunk:       return 1
        case .primary:     return 2
        case .secondary:   return 3
        case .tertiary:    return 4
        case .residential: return 5
        case .service:     return 6
        case .pedestrian:  return 7
        case .unknown:     return 8
        }
    }

    /// Самый мелкий класс, который ещё имеет смысл на этом охвате.
    ///
    /// Пороги — не круглые числа ради красоты. Схема показывает от 140 до 700
    /// метров по высоте; на 140 водитель разбирает свой двор, на 700 он видит
    /// район, и двор там — пятимиллиметровая закорючка, которая ничего не
    /// сообщает, но забивает всё между проспектами.
    ///
    /// `onMinorRoad` — мы сами едем по мелкой улице. Тогда планка опускается
    /// на две ступени: своя дорога обязана быть на схеме на любом охвате,
    /// иначе машина едет по пустоте.
    static func minimumRank(forSpan span: Double, onMinorRoad: Bool) -> Int {
        let base: Int
        switch span {
        case ..<200:  base = 8   // всё, включая проезды
        case ..<340:  base = 5   // до жилых улиц
        case ..<560:  base = 4   // до третьестепенных
        default:      base = 3   // район: только костяк
        }
        return onMinorRoad ? min(8, base + 2) : base
    }

    /// Порог длины обрубка: доля охвата, но не меньше двадцати метров. На
    /// экране это примерно одна сотая высоты — короче неразличимо в принципе.
    static func stubMeters(forSpan span: Double) -> Double { max(20, span / 10) }

    /// Допуск упрощения: доля охвата. Смещение меньше него на экране не видно
    /// ни при каком повороте.
    static func simplifyMeters(forSpan span: Double) -> Double { max(0.5, span / 400) }

    // MARK: - 2. Склейка

    /// Сшить ways с общим концом в непрерывные ломаные.
    ///
    /// Сшиваются только линии ОДНОГО характера: класс, уровень (земля / мост /
    /// тоннель) и односторонность. Магистраль, переходящую в улицу, склеивать
    /// нельзя — они и рисуются по-разному.
    ///
    /// Односторонние сшиваются строго конец-в-начало: у них есть направление,
    /// и перевёрнутый кусок развернул бы шевроны против движения. Двусторонние
    /// можно и разворачивать.
    ///
    /// Жадно и за один проход: в узле, где сходятся три и больше линий,
    /// продолжение неоднозначно — там линия честно обрывается, как и в жизни
    /// обрывается название улицы на перекрёстке.
    static func merge(_ lines: [RoadSketch.Line], snapMeters: Double = 1.0) -> [RoadSketch.Line] {
        guard lines.count > 1 else { return lines }

        struct Key: Hashable {
            let kind: Int, level: Int, oneWay: Bool
        }
        func key(_ line: RoadSketch.Line) -> Key {
            Key(kind: rank(line.kind), level: line.level, oneWay: line.isOneWay)
        }
        func node(_ point: CGPoint) -> Int64 {
            let x = Int64((Double(point.x) / snapMeters).rounded())
            let y = Int64((Double(point.y) / snapMeters).rounded())
            return x &* 1_000_003 &+ y
        }

        // Индекс: узел + характер → линии, которые в нём начинаются/кончаются.
        var byStart: [Int64: [Int]] = [:]
        var byEnd: [Int64: [Int]] = [:]
        // Степень узла — сколько концов в нём сходится ВСЕГО, независимо от
        // того, что уже склеено. Без неё правило «на перекрёстке не гадаем»
        // зависело от порядка входных линий: стоило магистрали уйти первой,
        // и две ветки развилки за ней сшивались в одну улицу через узел.
        var degree: [Int64: Int] = [:]
        var keys: [Key] = []
        keys.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            keys.append(key(line))
            guard let first = line.points.first, let last = line.points.last else { continue }
            byStart[node(first), default: []].append(index)
            byEnd[node(last), default: []].append(index)
            degree[node(first), default: 0] += 1
            degree[node(last), default: 0] += 1
        }

        var used = [Bool](repeating: false, count: lines.count)
        var result: [RoadSketch.Line] = []
        result.reserveCapacity(lines.count)

        /// Единственное неиспользованное продолжение того же характера.
        ///
        /// Узел степени ровно два — это стык двух кусков одной улицы. Всё
        /// остальное перекрёсток, и сшивать через него нельзя: полученная
        /// «улица» шла бы из одной ветки развилки в другую мимо главной.
        func continuation(at point: CGPoint, key: Key, allowReversed: Bool,
                          incomingBefore: (CGPoint) -> CGPoint?)
            -> (index: Int, reversed: Bool)? {
            let key0 = node(point)
            guard degree[key0] == 2 else { return nil }
            var found: (index: Int, reversed: Bool)?
            var count = 0
            for index in byStart[key0] ?? [] where !used[index] && keys[index] == key {
                count += 1
                found = (index, false)
            }
            if allowReversed {
                for index in byEnd[key0] ?? [] where !used[index] && keys[index] == key {
                    count += 1
                    found = (index, true)
                }
            }
            guard count == 1, let found else { return nil }

            // Шпильку не сшиваем. Улица не разворачивается на себя в узле:
            // если продолжение уходит почти туда же, откуда мы пришли, это не
            // одна улица с поворотом, а две, встретившиеся в тупике.
            // Склеенная шпилька рисуется штрихом, идущим туда и обратно, — на
            // экране это шип, торчащий из дороги.
            let tail = found.reversed ? lines[found.index].points.reversed()
                                      : lines[found.index].points
            guard tail.count >= 2, let outgoing = tail.dropFirst().first,
                  let incoming = incomingBefore(point)
            else { return found }
            guard turnDegrees(incoming, point, outgoing) <= maxMergeTurn
            else { return nil }
            return found
        }

        for (index, line) in lines.enumerated() where !used[index] {
            used[index] = true
            var points = line.points
            var lanes = line.lanes
            let currentKey = keys[index]
            let allowReversed = !line.isOneWay

            // Вперёд.
            while let last = points.last,
                  let next = continuation(at: last, key: currentKey,
                                          allowReversed: allowReversed,
                                          incomingBefore: { _ in
                                              points.count >= 2
                                                  ? points[points.count - 2] : nil
                                          }) {
                used[next.index] = true
                lanes = max(lanes, lines[next.index].lanes)
                let tail = next.reversed ? lines[next.index].points.reversed()
                                         : lines[next.index].points
                points.append(contentsOf: tail.dropFirst())
            }
            // Назад — только у двусторонних: у односторонней начало есть начало.
            if allowReversed {
                while let first = points.first,
                      let previous = continuation(at: first, key: currentKey,
                                                  allowReversed: true,
                                                  incomingBefore: { _ in
                                                      points.count >= 2
                                                          ? points[1] : nil
                                                  }) {
                    used[previous.index] = true
                    lanes = max(lanes, lines[previous.index].lanes)
                    let head = previous.reversed ? lines[previous.index].points
                                                 : lines[previous.index].points.reversed()
                    points.insert(contentsOf: head.dropFirst().reversed(), at: 0)
                }
            }

            var merged = line
            merged.points = points
            // Полос у склеенной улицы — максимум по кускам, как и на сервере:
            // ширина рисуется одна на всю линию, и занизить её значит провести
            // асфальт уже перекрёстка, к которому улица расширялась.
            merged.lanes = lanes
            result.append(merged)
        }
        return result
    }

    // MARK: - 3. Отсев обрубков

    static func length(_ points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += Double(hypot(points[index].x - points[index - 1].x,
                                  points[index].y - points[index - 1].y))
        }
        return total
    }

    /// Убрать то, что после склейки осталось короче порога.
    ///
    /// Именно ПОСЛЕ склейки: цепочка из пяти двадцатиметровых ways — это
    /// стометровая улица, и отсеивать её по длине куска было бы ошибкой.
    static func dropStubs(_ lines: [RoadSketch.Line],
                          shorterThan meters: Double) -> [RoadSketch.Line] {
        lines.filter { length($0.points) >= meters }
    }

    // MARK: - 4. Упрощение

    /// Дуглас—Пекер, итеративно: маршрут бывает в десять тысяч точек, и
    /// рекурсия на нём — это стек в тысячи кадров.
    static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]

        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let normal = (dx * dx + dy * dy).squareRoot()
            var worst = 0.0
            var worstIndex = first
            for index in (first + 1)..<last {
                let point = points[index]
                let distance: Double
                if normal > 0 {
                    distance = abs(dy * Double(point.x - a.x) - dx * Double(point.y - a.y)) / normal
                } else {
                    distance = Double(hypot(point.x - a.x, point.y - a.y))
                }
                if distance > worst { worst = distance; worstIndex = index }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((first, worstIndex))
                stack.append((worstIndex, last))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    // MARK: - 5. Сглаживание

    /// Чайкин: срезать каждый угол на четверть с обеих сторон.
    ///
    /// После Дугласа—Пекера дорога — из палок, и повороты у неё угловатые:
    /// упрощение убирает лишние точки, но оставшиеся соединяет прямыми. В
    /// жизни дорога так не поворачивает — у неё есть радиус, и глаз это знает.
    ///
    /// Концы держим на месте: они лежат в узлах, общих с соседними улицами, и
    /// сдвинуть их значило бы расцепить перекрёсток.
    ///
    /// Один проход, не два: он удваивает число точек, а это цена растра.
    /// Второй добавляет уже неразличимое.
    static func smooth(_ points: [CGPoint], passes: Int = 1) -> [CGPoint] {
        guard points.count > 2, passes > 0 else { return points }
        var current = points
        for _ in 0..<passes {
            var next: [CGPoint] = [current[0]]
            next.reserveCapacity(current.count * 2)
            for index in 0..<(current.count - 1) {
                let a = current[index], b = current[index + 1]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25,
                                    y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75,
                                    y: a.y * 0.25 + b.y * 0.75))
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    // MARK: - Всё вместе

    /// Полный проход генерализации для одного охвата.
    ///
    /// Линии, чей класс источнику НЕИЗВЕСТЕН (`isDetailed == false`), проходят
    /// отбор по масштабу насквозь: спрятать дорогу потому, что мы не знаем её
    /// класса, — это выдать незнание за решение.
    /// `precomputed` — сеть пришла уже генерализованной с сервера (формат
    /// тайлов v2). Тогда склейка, схлопывание, отсев обрубков и упрощение
    /// здесь не нужны: они уже сделаны один раз на всю страну, а не заново у
    /// каждого водителя на каждом квартале.
    ///
    /// Сглаживание остаётся на клиенте намеренно, и это не недоделка. Оно
    /// удваивает число точек, то есть в тайле стоило бы вдвое больше трафика
    /// и разбора, — а считается одним проходом по уже коротким ломаным, без
    /// поиска и хеширования. Переносится то, что требует ВСЕЙ сети; остаётся
    /// то, что локально и дёшево.
    static func apply(_ lines: [RoadSketch.Line], span: Double,
                      onMinorRoad: Bool,
                      precomputed: Bool = false) -> [RoadSketch.Line] {
        let limit = minimumRank(forSpan: span, onMinorRoad: onMinorRoad)
        let visible = lines.filter { line in
            // Тротуары, переходы и платформы не рисуются НИКОГДА, ни на одном
            // охвате. Это не проезжая часть, а схема отвечает на вопрос «где
            // камера относительно меня и МОЕЙ ДОРОГИ». На ближнем плане они
            // давали больше линий, чем все улицы вместе: дорожки вокруг домов
            // замкнуты, и картинка превращалась в проволочные контуры.
            guard !line.isDetailed || line.kind != .pedestrian else { return false }
            return !line.isDetailed || rank(line.kind) <= limit
        }
        guard !precomputed else {
            return visible.map { line in
                var result = line
                result.points = smooth(line.points)
                return result
            }
        }
        let merged = merge(visible)
        // Схлопывание — сразу после склейки: пары ищутся между ЦЕЛЫМИ улицами,
        // а не между кусками геометрии, у которых ни курса, ни длины толком нет.
        let single = collapseDual(merged,
                                  maxSeparation: collapseSeparation(forSpan: span))
        let solid = dropStubs(single, shorterThan: stubMeters(forSpan: span))
        let tolerance = simplifyMeters(forSpan: span)
        return solid.map { line in
            var result = line
            // Упрощение и сглаживание идут парой и именно в этом порядке:
            // сперва выбрасываем лишние точки, потом скругляем то, что
            // осталось. Наоборот было бы вдвое дороже и дало бы то же самое.
            result.points = smooth(simplify(line.points, tolerance: tolerance))
            return result
        }
    }
}

// MARK: - Схлопывание раздельных проезжих

extension RoadGeneralise {

    /// Максимальное расстояние между осями, при котором две односторонние
    /// считаются одной раздельной дорогой. Ноль — не схлопываем вовсе.
    ///
    /// На ближнем плане НЕ схлопываем принципиально: там разделительная полоса
    /// — это реальное препятствие, через которое не перестроиться, и рисовать
    /// две проезжие части одной линией значит соврать про дорогу. Дальше
    /// сорока метров разнос всё равно уже неразличим, поэтому потолок низкий.
    static func collapseSeparation(forSpan span: Double) -> Double {
        span < 220 ? 0 : min(45, span / 8)
    }

    /// Острее этого угла склейка не идёт: улица не разворачивается на себя.
    static let maxMergeTurn: Double = 150

    /// Угол поворота в вершине, градусы. 0 — прямо, 180 — разворот.
    static func turnDegrees(_ before: CGPoint, _ at: CGPoint,
                            _ after: CGPoint) -> Double {
        let ax = Double(at.x - before.x), ay = Double(at.y - before.y)
        let bx = Double(after.x - at.x), by = Double(after.y - at.y)
        let na = (ax * ax + ay * ay).squareRoot()
        let nb = (bx * bx + by * by).squareRoot()
        guard na > 0, nb > 0 else { return 0 }
        let cosine = max(-1, min(1, (ax * bx + ay * by) / (na * nb)))
        return acos(cosine) * 180 / .pi
    }

    /// Ведущая ось обязана быть настоящей улицей, а не куском.
    static let minAxisMeters: Double = 45

    /// Встречный кусок засчитывается с двадцати двух метров.
    ///
    /// Сорок было слишком много, и это видно на городском перекрёстке: между
    /// двумя пересечениями кусок проезжей части бывает и тридцать метров, а
    /// на одной стороне проспекта перекрёстков всегда больше, чем на другой.
    /// Из-за порога проспект схлопывался справа от перекрёстка и оставался
    /// раздвоенным слева — на одной и той же улице. Ниже двадцати двух метров
    /// опускать нельзя: у такого обрубка направление определяется шумом
    /// координат, и «встречность» становится монеткой.
    static let minPartnerMeters: Double = 22

    /// Расстояние от точки до ломаной.
    static func distance(from point: CGPoint, to line: [CGPoint]) -> Double {
        guard let first = line.first else { return .greatestFiniteMagnitude }
        guard line.count >= 2 else { return Double(hypot(point.x - first.x, point.y - first.y)) }
        var best = Double.greatestFiniteMagnitude
        for index in 1..<line.count {
            let a = line[index - 1], b = line[index]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let squared = dx * dx + dy * dy
            let t: Double = squared > 0
                ? max(0, min(1, (Double(point.x - a.x) * dx + Double(point.y - a.y) * dy) / squared))
                : 0
            let cx = Double(a.x) + t * dx, cy = Double(a.y) + t * dy
            best = min(best, ((Double(point.x) - cx) * (Double(point.x) - cx)
                              + (Double(point.y) - cy) * (Double(point.y) - cy)).squareRoot())
        }
        return best
    }

    /// Курс ломаной от первой точки к последней, градусы 0…360.
    static func bearing(_ points: [CGPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let angle = atan2(Double(last.x - first.x), Double(last.y - first.y)) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    /// Свести две односторонние встречных направлений в одну ось.
    ///
    /// Зачем это вообще. В данных проспект — ЧЕСТНО две проезжие части, и
    /// схема рисовала их двумя параллельными полосами со встречными шевронами.
    /// В данных это правда, а на экране на трёхстах метрах — ошибка рендера:
    /// водитель видит две дороги там, где едет по одной. Так же читает это и
    /// любая настоящая карта, поэтому все они схлопывают раздельные проезжие
    /// при отдалении. Мы делаем ровно то же и по тем же признакам.
    ///
    /// Условий четыре, и каждое отсекает свой вид ложного совпадения:
    ///   • один класс и один уровень — иначе съезд слипнется с эстакадой;
    ///   • курсы противоположны в пределах допуска — иначе схлопнется дублёр,
    ///     идущий В ТУ ЖЕ сторону, а это две разные дороги;
    ///   • оси рядом с ОБЕИХ сторон — иначе длинный проспект «поймает»
    ///     случайный отрезок, коснувшийся его одним концом;
    ///   • длины сопоставимы — иначе улица схлопнется с карманом у обочины.
    static func collapseDual(_ lines: [RoadSketch.Line],
                             maxSeparation: Double) -> [RoadSketch.Line] {
        guard maxSeparation > 0, lines.count > 1 else { return lines }

        let bearings = lines.map { bearing($0.points) }
        let lengths = lines.map { length($0.points) }
        var used = [Bool](repeating: false, count: lines.count)
        var result: [RoadSketch.Line] = []
        result.reserveCapacity(lines.count)

        func opposite(_ a: Double, _ b: Double) -> Bool {
            let delta = abs((a - b).truncatingRemainder(dividingBy: 360))
            let folded = delta > 180 ? 360 - delta : delta
            return abs(folded - 180) <= 25
        }
        func sample(_ points: [CGPoint]) -> [CGPoint] {
            guard points.count > 5 else { return points }
            let step = max(1, points.count / 5)
            return stride(from: 0, to: points.count, by: step).map { points[$0] }
        }

        // От длинных к коротким: ведущей осью обязана стать сама улица, а не
        // её кусок. Иначе первый попавшийся отрезок забирал бы себе роль
        // проспекта, и ось уезжала бы туда, где короткий кусок кончился.
        let order = lines.indices.sorted { lengths[$0] > lengths[$1] }

        for index in order where !used[index] {
            let line = lines[index]
            used[index] = true
            guard line.isOneWay, line.isDetailed, lengths[index] >= minAxisMeters else {
                result.append(line)
                continue
            }

            // ВСЕ встречные куски вдоль этой оси, а не первый попавшийся.
            //
            // Иначе выходило хуже, чем ничего: у двух проезжих частей число
            // ways почти никогда не совпадает (на одной стороне перекрёстков
            // больше), и проспект схлопывался кусками — сверху одна дорога,
            // ниже снова две. Непоследовательность на одной и той же улице
            // читается поломкой рендера сильнее, чем сама раздвоенность.
            var partners: [Int] = []
            for other in lines.indices
            where other != index && !used[other] && lines[other].isOneWay
                && lines[other].isDetailed && lengths[other] >= minPartnerMeters
                && lines[other].kind == line.kind && lines[other].level == line.level
                && opposite(bearings[index], bearings[other]) {
                // Встречный кусок обязан идти ВДОЛЬ оси целиком: достаточно
                // одной его точки в стороне, чтобы это был уже съезд, а не
                // вторая проезжая часть.
                let alongside = sample(lines[other].points).allSatisfy {
                    distance(from: $0, to: line.points) <= maxSeparation
                }
                if alongside {
                    partners.append(other)
                    used[other] = true
                }
            }
            guard !partners.isEmpty else {
                result.append(line)
                continue
            }

            let axis = collapsedAxis(line.points, partners: partners.map { lines[$0].points },
                                     maxSeparation: maxSeparation)
            var collapsed = line
            collapsed.points = axis
            // Схлопнутая дорога двусторонняя по определению: шевроны на ней
            // означали бы, что по ней можно ехать только в одну сторону.
            collapsed.isOneWay = false
            collapsed.isDual = true
            // Полосы СКЛАДЫВАЮТСЯ: ось — это две проезжие части, и ширина
            // одной половины нарисовала бы проспект вдвое уже, чем он есть.
            // Ровно то же делает collapse_dual в server/build_roads.py.
            collapsed.lanes = min(15, partners.reduce(line.lanes) { $0 + lines[$1].lanes })
            result.append(collapsed)
        }
        return result
    }

    /// Насколько плавно сдвиг оси сходит на нет там, где встречная проезжая
    /// часть кончилась. Ниже двадцати метров переход виден изломом.
    static let axisTaperMeters: Double = 28

    /// Ось между проезжими частями, сходящая на нет за их пределами.
    ///
    /// Прямолинейное «есть пара — середина, нет пары — своё место» даёт на
    /// экране ШАГ ВБОК ровно там, где встречная часть кончилась: дорога
    /// прыгает на половину разноса и обратно. В жизни так не бывает, и глаз
    /// читает это изломом асфальта, а не концом данных.
    ///
    /// Поэтому сдвиг считается отдельно от точек и затухает вдоль дороги: на
    /// участке с парой он полный, дальше линейно сходит к нулю за
    /// `axisTaperMeters`. Плюс сглаживание по трём соседям — оно снимает
    /// дрожь там, где пара то находится, то теряется на соседних вершинах.
    static func collapsedAxis(_ points: [CGPoint], partners: [[CGPoint]],
                              maxSeparation: Double) -> [CGPoint] {
        guard points.count >= 2, !partners.isEmpty else { return points }

        // 1. Сдвиг там, где пара есть.
        var shift: [CGPoint?] = points.map { point in
            var best: CGPoint?
            var bestDistance = maxSeparation * 1.5
            for partner in partners {
                guard let near = nearestPoint(from: point, on: partner) else { continue }
                let d = Double(hypot(point.x - near.x, point.y - near.y))
                if d < bestDistance { bestDistance = d; best = near }
            }
            guard let near = best else { return nil }
            return CGPoint(x: (near.x - point.x) / 2, y: (near.y - point.y) / 2)
        }

        // 2. Расстояние вдоль дороги — по нему и затухаем.
        var along = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            along[index] = along[index - 1]
                + Double(hypot(points[index].x - points[index - 1].x,
                               points[index].y - points[index - 1].y))
        }

        // 3. Пропуски: берём ближайший известный сдвиг и гасим его по
        // расстоянию до него.
        let known = shift.indices.filter { shift[$0] != nil }
        guard !known.isEmpty else { return points }
        for index in shift.indices where shift[index] == nil {
            var nearestKnown = known[0]
            for candidate in known
            where abs(along[candidate] - along[index]) < abs(along[nearestKnown] - along[index]) {
                nearestKnown = candidate
            }
            let gap = abs(along[nearestKnown] - along[index])
            guard gap < axisTaperMeters, let source = shift[nearestKnown] else {
                shift[index] = .zero
                continue
            }
            let fade = CGFloat(1 - gap / axisTaperMeters)
            shift[index] = CGPoint(x: source.x * fade, y: source.y * fade)
        }

        // 4. Сглаживание по трём соседям.
        let raw = shift.map { $0 ?? .zero }
        return points.indices.map { index in
            let previous = raw[max(0, index - 1)]
            let current = raw[index]
            let next = raw[min(raw.count - 1, index + 1)]
            let x = (previous.x + current.x * 2 + next.x) / 4
            let y = (previous.y + current.y * 2 + next.y) / 4
            return CGPoint(x: points[index].x + x, y: points[index].y + y)
        }
    }

    /// Ближайшая точка ломаной к заданной.
    static func nearestPoint(from point: CGPoint, on line: [CGPoint]) -> CGPoint? {
        guard let first = line.first else { return nil }
        guard line.count >= 2 else { return first }
        var best = first
        var bestDistance = Double.greatestFiniteMagnitude
        for index in 1..<line.count {
            let a = line[index - 1], b = line[index]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let squared = dx * dx + dy * dy
            let t: Double = squared > 0
                ? max(0, min(1, (Double(point.x - a.x) * dx + Double(point.y - a.y) * dy) / squared))
                : 0
            let candidate = CGPoint(x: Double(a.x) + t * dx, y: Double(a.y) + t * dy)
            let d = Double(hypot(point.x - candidate.x, point.y - candidate.y))
            if d < bestDistance { bestDistance = d; best = candidate }
        }
        return best
    }
}
