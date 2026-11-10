//
//  TypicalTraffic.swift
//  RadarMap
//
//  «Обычно ~35 мин (по водителям)» — холодный старт дороги на работу (план
//  19.10, 8.8.16). Своё «обычно» (Commute) появляется с третьей поездки, а
//  до неё подсказка «На работу» молчала о времени. Но дорога уже известна —
//  первая же поездка легла в профиль линией варианта (CommuteProfile), — и
//  сервер знает, как по этим улицам обычно едут люди в этот час:
//  traffic/typical/<wd|off>-<час>.json (server/traffic_build.py), скорость
//  ребра OSM по сотням кусков чужих поездок.
//
//  Всё сложение — на телефоне. Линия дом→работа наружу не уходит, маршрут
//  ради оценки не строится (это отправило бы дом и работу на сервер); файл
//  часа скачивается целиком и говорит серверу только час.
//
//  Ребро ловится по месту (≤ 18 м), по направлению (≤ 35°) и проекцией
//  внутрь ребра — то же правило, что у пробок на своём пути (CommuteEstimate):
//  встречная полоса проспекта — не наша дорога. Не покрытый данными хвост
//  едет в темпе покрытого, но только если покрыто не меньше
//  `crowdCommuteMinCoverage` линии: по трети пути «обычно» — выдумка, и
//  тогда оценки нет вовсе (nil), а не «примерно что-то».
//
//  Своё «обычно» всегда старше: это только мостик к первым трём поездкам.
//
//  Чистая логика, время и календарь — параметрами; покрыто TypicalTrafficTests.
//

import CoreLocation
import Foundation

nonisolated struct TypicalTraffic: Sendable {

    /// Файл: класс дня и час по Ташкенту. Будни и выходные, а не 168 часов
    /// недели: в холодный старт данных мало, и пять будних восьми утра в
    /// одном файле набирают порог сервера впятеро быстрее.
    struct Bucket: Hashable, Sendable {
        let dayOff: Bool
        let hour: Int

        /// «wd-08» — будни в 8:00, «off-08» — выходные (как bucket_name на сервере).
        var name: String { String(format: "%@-%02d", dayOff ? "off" : "wd", hour) }
        var path: String { "traffic/typical/\(name).json" }
    }

    /// Что посчитать для одного направления: линия своего пути и час выезда.
    struct Request: Equatable, Sendable {
        let line: [CLLocationCoordinate2D]
        let bucket: Bucket

        static func == (a: Request, b: Request) -> Bool {
            a.bucket == b.bucket && a.line.count == b.line.count
                && zip(a.line, b.line).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    struct Estimate: Equatable, Sendable {
        /// Время в пути, с, в целых минутах.
        let seconds: Double
        /// Доля линии, легшая на рёбра файла.
        let coverage: Double
    }

    let bucket: Bucket
    /// Рёбра файла: `kmh` — обычная скорость в этот час, `modelKmh` —
    /// скорость графа (шестой столбец, 27.E), а уровень посчитан по их
    /// отношению теми же порогами, что у сервера: так «обычно» складывается
    /// с любым маршрутом той же меркой, что живые пробки (TrafficForecast).
    /// Старый файл без шестого столбца — `modelKmh` = `kmh`, уровень 1:
    /// сравнивать не с чем, и задержки маршруту он не добавляет.
    let snapshot: TrafficSnapshot

    // MARK: - Час

    /// Часы сервера — ташкентские (hour_of_week в traffic_build.py): телефон,
    /// переведённый в другой пояс, просил бы не тот файл.
    static var tashkent: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent") ?? TimeZone(secondsFromGMT: 5 * 3600) ?? .current
        return calendar
    }

    /// Файл для выезда в `date`. Праздник — выходной класс (UzHolidays): в
    /// Навруз дороги как в воскресенье, а не как во вторник.
    static func bucket(for date: Date, calendar: Calendar = tashkent) -> Bucket {
        Bucket(dayOff: UzHolidays.isDayOff(date, calendar: calendar),
               hour: calendar.component(.hour, from: date))
    }

    // MARK: - Разбор

    /// Формат версии 1: `{"v":1,"bucket":"wd-08","generated":t,"edges":[[ulat,ulon,vlat,vlon,kmh,model_kmh]]}`
    /// (model_kmh — с 27.E, 0 или нет — неизвестна).
    /// Другая версия, чужой час или не JSON — nil: догадка о формате хуже,
    /// чем честное «нет данных». Возраст не проверяется: файл переписывается
    /// только при смене рёбер, и тихий час (выходные, 3 ночи) законно стоит
    /// неделями — «обычно» от этого не стареет.
    static func decode(_ data: Data, expected: Bucket) -> TypicalTraffic? {
        // Не JSON — «нет данных»; журнал ведёт сервис по nil.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == 1,
              object["bucket"] as? String == expected.name,
              let generated = object["generated"] as? Double ?? (object["generated"] as? Int).map(Double.init),
              let raw = object["edges"] as? [[Double]] else { return nil }
        let edges = raw.compactMap { row -> TrafficEdge? in
            guard row.count >= 5, row[4] > 0, row[4] <= 200 else { return nil }
            let model = row.count >= 6 && row[5] > 0 && row[5] <= 200 ? row[5] : row[4]
            return TrafficEdge(a: CLLocationCoordinate2D(latitude: row[0], longitude: row[1]),
                               b: CLLocationCoordinate2D(latitude: row[2], longitude: row[3]),
                               level: TrafficSnapshot.level(kmh: row[4], modelKmh: model),
                               kmh: row[4], modelKmh: model)
        }
        return TypicalTraffic(bucket: expected,
                              snapshot: TrafficSnapshot(generated: Date(timeIntervalSince1970: generated),
                                                        edges: edges, linked: false))
    }

    // MARK: - Линия

    /// Свой путь направления: вариант, по которому ездили чаще (при равенстве —
    /// недавний), и последний выезд по нему. nil — пути нет (ни одной
    /// поездки или обучение дороги выключено).
    static func line(of variants: [CommuteProfile.Variant])
        -> (coordinates: [CLLocationCoordinate2D], lastDeparture: Date?)? {
        let best = variants.max {
            ($0.rows.count, $0.lastUsed) < ($1.rows.count, $1.lastUsed)
        }
        guard let best, best.coordinates.count >= 2 else { return nil }
        return (best.coordinates, best.rows.map(\.departure).max())
    }

    // MARK: - Время по линии

    /// Обычное время по линии в этот час; nil — данных меньше
    /// `crowdCommuteMinCoverage` линии.
    static func travelTime(along line: [CLLocationCoordinate2D], typical: TypicalTraffic) -> Estimate? {
        let snapshot = typical.snapshot
        guard line.count >= 2, !snapshot.edges.isEmpty else { return nil }
        var length = 0.0, covered = 0.0, time = 0.0
        for (p, q) in zip(line, line.dropFirst()) {
            let segment = GeoMath.fastDistance(p.latitude, p.longitude, q.latitude, q.longitude)
            guard segment > 0.5 else { continue }
            length += segment
            let course = GeoMath.bearing(from: p, to: q)
            let steps = max(1, Int((segment / AppConfig.commuteJamStepMeters).rounded(.up)))
            let step = segment / Double(steps)
            for s in 0..<steps {
                let t = (Double(s) + 0.5) / Double(steps)
                let point = CLLocationCoordinate2D(latitude: p.latitude + (q.latitude - p.latitude) * t,
                                                   longitude: p.longitude + (q.longitude - p.longitude) * t)
                guard let edge = snapshot.matchingEdge(at: point, course: course),
                      CommuteEstimate.liesAlong(point, edge) else { continue }
                covered += step
                time += step / (max(3, edge.kmh) / 3.6)
            }
        }
        guard length >= AppConfig.crowdCommuteMinMeters, covered > 0 else { return nil }
        let coverage = covered / length
        guard coverage >= AppConfig.crowdCommuteMinCoverage else { return nil }
        // Непокрытое — в темпе покрытого: тот же путь, те же люди в тот же час.
        let total = time * length / covered
        return Estimate(seconds: max(60, (total / 60).rounded() * 60), coverage: coverage)
    }
}
