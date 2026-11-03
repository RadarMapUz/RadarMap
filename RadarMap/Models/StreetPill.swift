//
//  StreetPill.swift
//  RadarMap
//
//  Плашка «по какой улице едем» внизу по центру (29.F, как у Amap и Яндекса).
//
//  Имя берётся с самой карты: в наших тайлах у ленты улицы есть `name`
//  (build_mvt), и раз в пару секунд карта спрашивает у движка ленты под
//  значком «я». Ни сети, ни отдельного поиска — то, что нарисовано, то и
//  подписано.
//
//  Решение — здесь, чистой логикой (StreetPillTests). На перекрёстке под
//  значком две-три ленты, и «ближайшая» прыгала бы с улицы на поперечную на
//  каждом светофоре. Поэтому:
//  - лента должна идти ПО курсу (без учёта направления, ± streetPillBearingDegrees);
//  - прежнее имя держится, пока его лента ещё под значком и идёт по курсу;
//  - пропало имя — плашка гаснет не сразу, а после streetPillMissesToHide
//    пустых опросов подряд: короткий кусок без имени посреди перекрёстка
//    не мигает плашкой.
//  Курса нет (стоим) — по курсу не судим: прежнее имя, иначе ближайшее.
//
//  Только картинка: ни голос, ни оповещения отсюда не читают.
//

import CoreLocation
import Foundation

nonisolated enum StreetPill {

    /// Лента под значком: имя, направление её куска у машины (0…360, nil —
    /// не знаем) и расстояние от машины до него, м.
    struct Candidate: Equatable, Sendable {
        var name: String
        var bearing: Double?
        var distance: Double
    }

    /// Какое имя показать. nil — подходящей ленты нет.
    static func choose(_ candidates: [Candidate], course: Double, previous: String?) -> String? {
        let named = candidates.compactMap { item -> Candidate? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Candidate(name: name, bearing: item.bearing, distance: item.distance)
        }
        guard !named.isEmpty else { return nil }
        let pool: [Candidate]
        if course < 0 {
            pool = named
        } else {
            pool = named.filter { item in
                guard let bearing = item.bearing else { return true }
                return GeoMath.axisDifference(course: course,
                                              axis: bearing.truncatingRemainder(dividingBy: 180)) <= AppConfig.streetPillBearingDegrees
            }
        }
        if let previous, pool.contains(where: { $0.name == previous }) { return previous }
        return pool.min { $0.distance < $1.distance }?.name
    }

    /// Тип улицы впереди имени, как его сокращает подпись на карте
    /// (make_style.py STREET_TYPES, «Фуркат улица» → «ул. Фуркат»).
    static let mapTypes: [(word: String, short: String)] = [
        ("улица", "ул."), ("проспект", "просп."), ("проезд", "пр-д"), ("переулок", "пер."),
        ("тупик", "туп."), ("шоссе", "ш."), ("бульвар", "бул."), ("площадь", "пл."),
    ]

    /// Имя для плашки: без уточнения в скобках, на языке приложения
    /// (StreetName). `mapForm` — тип сокращён, как на подписи карты: в машине
    /// плашка и подпись улицы рядом, и «улица Фуркат» под «ул. Фуркат»
    /// читались двумя разными улицами (40J, D10).
    static func label(_ raw: String, language: String, mapForm: Bool = false) -> String {
        let name = StreetName.display(cleanName(raw), language: language)
        guard mapForm, language != "uz" else { return name }
        for type in mapTypes where name.hasPrefix(type.word + " ") {
            return type.short + " " + name.dropFirst(type.word.count + 1)
        }
        return name
    }

    /// Имя для плашки: без уточнения в скобках в конце — «Furqat ko'chasi
    /// (dublyor)» не узнавался StreetName (тип улицы должен стоять в конце),
    /// и плашка писала латиницу рядом с «ул. Фуркат» на карте. Дублёр —
    /// та же улица.
    static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex {
            name = String(name[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
    }

    /// Ближайший кусок ломаной к точке: расстояние, м, и направление куска.
    /// Плоская проекция у точки — на десятках метров ошибка ничтожна.
    static func nearest(_ line: [CLLocationCoordinate2D],
                        to point: CLLocationCoordinate2D) -> (distance: Double, bearing: Double)? {
        guard line.count >= 2 else { return nil }
        let kx = 111_320 * cos(point.latitude * .pi / 180), ky = 110_540.0
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - point.longitude) * kx, (c.latitude - point.latitude) * ky)
        }
        var best: (distance: Double, bearing: Double)?
        for (a, b) in zip(line, line.dropFirst()) {
            let (ax, ay) = xy(a), (bx, by) = xy(b)
            let dx = bx - ax, dy = by - ay
            let length2 = dx * dx + dy * dy
            guard length2 > 0.01 else { continue }
            let t = max(0, min(1, -(ax * dx + ay * dy) / length2))
            let px = ax + t * dx, py = ay + t * dy
            let distance = (px * px + py * py).squareRoot()
            if best == nil || distance < best!.distance {
                var bearing = atan2(dx, dy) * 180 / .pi
                if bearing < 0 { bearing += 360 }
                best = (distance, bearing)
            }
        }
        return best
    }

    /// Память плашки: прежнее имя и сколько опросов подряд имени не было.
    struct Tracker: Equatable, Sendable {
        private(set) var shown: String?
        private var misses = 0

        /// Новый опрос → что показать.
        mutating func update(_ candidates: [Candidate], course: Double) -> String? {
            if let name = StreetPill.choose(candidates, course: course, previous: shown) {
                shown = name
                misses = 0
            } else {
                misses += 1
                if misses >= AppConfig.streetPillMissesToHide { shown = nil }
            }
            return shown
        }

        mutating func reset() {
            shown = nil
            misses = 0
        }
    }
}
